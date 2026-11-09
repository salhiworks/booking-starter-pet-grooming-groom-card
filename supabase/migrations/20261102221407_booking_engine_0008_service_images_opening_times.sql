-- ============================================================================
-- Profit Studio Booking Engine — migration 0008_service_images_opening_times
-- Engine schema version: 2.0.0-alpha.10
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Additive only:
--   1. Optional service images. booking.services.image is null or
--      { path, alt?, width?, height? }: a file under `services/` in the public
--      media bucket `booking-site-media` (0007: anyone may read a file by its
--      URL; only admins list, upload or delete; images only, 5 MB at most).
--      Public service data includes it. No service needs an image, and
--      bookings, prices and availability do not depend on it.
--   2. Public opening times: each business-local date's opening hours after
--      closures (whole-day and partial-day), for "Open now" / "Opens at"
--      lines on websites. Times only — closure reasons stay admin-only.
--
-- Existing services, bookings and settings are unchanged.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.7' then
    raise exception 'Booking Engine 0008_service_images_opening_times expects schema 2.0.0-alpha.7, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Service images
-- ----------------------------------------------------------------------------

-- A service image value: { path, alt?, width?, height? }. The path is a file
-- name under services/ (never site/: the website editor tidies site/ files
-- that its content no longer uses). CASE keeps every cast behind its type test.
create function booking.service_image_ok(p_image jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_image is null or jsonb_typeof(p_image) <> 'object' then false
    when exists (select 1 from jsonb_object_keys(p_image) k where k not in ('path', 'alt', 'width', 'height')) then false
    when coalesce(jsonb_typeof(p_image -> 'path'), '') <> 'string' then false
    when (p_image ->> 'path') !~ '^services/[a-z0-9][a-z0-9._-]{0,120}$' or position('..' in (p_image ->> 'path')) > 0 then false
    when coalesce(jsonb_typeof(p_image -> 'alt'), 'string') <> 'string' then false
    when char_length(coalesce(p_image ->> 'alt', '')) > 300 or coalesce(p_image ->> 'alt', '') ~ '[\x01-\x1f\x7f]' then false
    when coalesce(jsonb_typeof(p_image -> 'width'), 'number') <> 'number' then false
    when coalesce(jsonb_typeof(p_image -> 'height'), 'number') <> 'number' then false
    when p_image ? 'width' and ((p_image ->> 'width')::numeric not between 1 and 20000
                                or (p_image ->> 'width')::numeric <> trunc((p_image ->> 'width')::numeric)) then false
    when p_image ? 'height' and ((p_image ->> 'height')::numeric not between 1 and 20000
                                 or (p_image ->> 'height')::numeric <> trunc((p_image ->> 'height')::numeric)) then false
    else true
  end;
$$;

-- The full rules are checked by booking_admin_save_service; the table keeps a
-- shape guarantee that needs no function privileges.
alter table booking.services
  add column image jsonb
  constraint services_image_shape check (
    image is null
    or (jsonb_typeof(image) = 'object'
        and jsonb_typeof(image -> 'path') = 'string'
        and (image ->> 'path') ~ '^services/[a-z0-9][a-z0-9._-]{0,120}$'
        and octet_length(image::text) <= 2000)
  );
comment on column booking.services.image is
  'Optional photo: { path, alt?, width?, height? }; path is under services/ in the public bucket booking-site-media. Display only — never required to create or book a service.';

-- Admin shape: everything, now with the image.
create or replace function booking.service_json(sv booking.services)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', sv.id,
    'name', sv.name,
    'description', sv.description,
    'durationMinutes', sv.duration_minutes,
    'bufferAfterMinutes', sv.buffer_after_minutes,
    'priceCents', sv.price_cents,
    'priceFrom', sv.price_from,
    'isActive', sv.is_active,
    'sortOrder', sv.sort_order,
    'image', sv.image,
    'createdAt', booking.iso(sv.created_at),
    'updatedAt', booking.iso(sv.updated_at)
  );
$$;

-- Public shape: unchanged fields plus the image (a public file path and its
-- description; nothing private).
create or replace function public.booking_list_services()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', sv.id,
             'name', sv.name,
             'description', sv.description,
             'durationMinutes', sv.duration_minutes,
             'priceCents', sv.price_cents,
             'priceFrom', sv.price_from,
             'currency', (select s.currency from booking.settings s where s.id),
             'image', sv.image
           ) order by sv.sort_order, sv.name), '[]'::jsonb)
  from booking.services sv
  where sv.is_active;
$$;
comment on function public.booking_list_services() is
  'Public. Active services in display order, each with its optional image ({ path, alt?, width?, height? } or null).';

-- Saving a service accepts `image`: an image value sets it, null removes it,
-- leaving it out keeps the current one.
create or replace function public.booking_admin_save_service(p_service jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_allowed text[] := array['id', 'name', 'description', 'durationMinutes', 'bufferAfterMinutes',
                            'priceCents', 'priceFrom', 'isActive', 'sortOrder', 'image'];
  v_key text;
  v_id uuid;
  v_image jsonb;
  sv booking.services%rowtype;
begin
  perform booking.require_admin();
  if p_service is null or jsonb_typeof(p_service) <> 'object' then
    perform booking.raise_error('INVALID_INPUT', 'service');
  end if;
  for v_key in select jsonb_object_keys(p_service) loop
    if not (v_key = any (v_allowed)) then
      perform booking.raise_error('INVALID_INPUT', v_key);
    end if;
  end loop;

  if jsonb_typeof(p_service -> 'id') = 'string' then
    begin
      v_id := (p_service ->> 'id')::uuid;
    exception when others then
      perform booking.raise_error('INVALID_INPUT', 'id');
    end;
  elsif p_service ? 'id' and jsonb_typeof(p_service -> 'id') <> 'null' then
    perform booking.raise_error('INVALID_INPUT', 'id');
  end if;

  if p_service ? 'durationMinutes' or v_id is null then
    if booking.j_int(p_service, 'durationMinutes', 5, 720) is null then
      perform booking.raise_error('INVALID_INPUT', 'durationMinutes');
    end if;
  end if;

  if p_service ? 'image' and jsonb_typeof(p_service -> 'image') <> 'null' then
    if not booking.service_image_ok(p_service -> 'image') then
      perform booking.raise_error('INVALID_INPUT', 'image');
    end if;
    v_image := p_service -> 'image';
  end if;

  if v_id is null then
    insert into booking.services (
      name, description, duration_minutes, buffer_after_minutes, price_cents, price_from, is_active, sort_order, image
    ) values (
      booking.j_required_text(p_service, 'name', 120),
      booking.j_text(p_service, 'description', 2000),
      booking.j_int(p_service, 'durationMinutes', 5, 720),
      coalesce(booking.j_int(p_service, 'bufferAfterMinutes', 0, 240), 0),
      booking.j_int(p_service, 'priceCents', 0, 100000000),
      coalesce(booking.j_bool(p_service, 'priceFrom'), false),
      coalesce(booking.j_bool(p_service, 'isActive'), true),
      coalesce(booking.j_int(p_service, 'sortOrder', -100000, 100000), 0),
      v_image
    )
    returning * into sv;
  else
    update booking.services set
      name = case when p_service ? 'name' then booking.j_required_text(p_service, 'name', 120) else name end,
      description = case when p_service ? 'description' then booking.j_text(p_service, 'description', 2000) else description end,
      duration_minutes = case when p_service ? 'durationMinutes'
                              then booking.j_int(p_service, 'durationMinutes', 5, 720) else duration_minutes end,
      buffer_after_minutes = case when p_service ? 'bufferAfterMinutes'
                                  then coalesce(booking.j_int(p_service, 'bufferAfterMinutes', 0, 240), 0) else buffer_after_minutes end,
      price_cents = case when p_service ? 'priceCents' then booking.j_int(p_service, 'priceCents', 0, 100000000) else price_cents end,
      price_from = case when p_service ? 'priceFrom' then coalesce(booking.j_bool(p_service, 'priceFrom'), false) else price_from end,
      is_active = case when p_service ? 'isActive' then coalesce(booking.j_bool(p_service, 'isActive'), true) else is_active end,
      sort_order = case when p_service ? 'sortOrder'
                        then coalesce(booking.j_int(p_service, 'sortOrder', -100000, 100000), 0) else sort_order end,
      image = case when p_service ? 'image' then v_image else image end
    where id = v_id
    returning * into sv;
    if not found then
      perform booking.raise_error('NOT_FOUND', 'service');
    end if;
  end if;
  return booking.service_json(sv);
exception
  when check_violation then
    perform booking.raise_error('INVALID_INPUT', 'service');
    return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. Public opening times
-- ----------------------------------------------------------------------------

-- Each date's opening hours (weekly hours minus that date's closures), as
-- business-local "HH:MM" ranges. A partial closure closes the same time window
-- on every date of its range, exactly as availability treats it.
create function booking.get_opening_times(p_from date, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_max_days constant int := 42;
  v_to date := coalesce(p_to, p_from);
  v_timezone text;
  v_result jsonb;
begin
  if p_from is null or not isfinite(p_from) then
    perform booking.raise_error('INVALID_INPUT', 'from');
  end if;
  if not isfinite(v_to) or v_to < p_from or v_to - p_from >= c_max_days then
    perform booking.raise_error('INVALID_INPUT', 'to');
  end if;
  select s.timezone into v_timezone from booking.settings s where s.id;

  with days as (
    select p_from + g.n as day
    from generate_series(0, v_to - p_from) as g(n)
  ),
  open_minutes as (
    select dd.day,
           range_agg(int4range(
             (extract(hour from wh.start_time) * 60 + extract(minute from wh.start_time))::int,
             (extract(hour from wh.end_time) * 60 + extract(minute from wh.end_time))::int)) as m
    from days dd
    join booking.working_hours wh on wh.weekday = extract(isodow from dd.day)::int
    group by dd.day
  ),
  closed_minutes as (
    select dd.day,
           range_agg(int4range(
             coalesce((extract(hour from e.start_time) * 60 + extract(minute from e.start_time))::int, 0),
             coalesce((extract(hour from e.end_time) * 60 + extract(minute from e.end_time))::int, 1440))) as m
    from days dd
    join booking.availability_exceptions e on dd.day between e.starts_on and e.ends_on
    group by dd.day
  )
  select jsonb_build_object(
    'timezone', v_timezone,
    'from', to_char(p_from, 'YYYY-MM-DD'),
    'to', to_char(v_to, 'YYYY-MM-DD'),
    'days', coalesce(jsonb_agg(
      jsonb_build_object(
        'date', to_char(dd.day, 'YYYY-MM-DD'),
        'hours', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'start', to_char(make_interval(mins => lower(r)), 'HH24:MI'),
                     'end', to_char(make_interval(mins => upper(r)), 'HH24:MI')
                   ) order by lower(r))
          from unnest(coalesce(o.m, '{}'::int4multirange) - coalesce(c.m, '{}'::int4multirange)) as r
        ), '[]'::jsonb)
      ) order by dd.day), '[]'::jsonb)
  )
  into v_result
  from days dd
  left join open_minutes o on o.day = dd.day
  left join closed_minutes c on c.day = dd.day;

  return v_result;
end;
$$;
comment on function booking.get_opening_times(date, date) is
  'PRIVILEGED (SECURITY DEFINER), private schema: reads closures to compute each date''s opening hours and returns times only — never closure reasons. Reached through public.booking_get_opening_times.';

create function public.booking_get_opening_times(p_from date, p_to date default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select booking.get_opening_times(p_from, p_to);
$$;
comment on function public.booking_get_opening_times(date, date) is
  'Public. Opening hours of each business-local date after closures (at most 42 days): { timezone, from, to, days: [{ date, hours: [{ start, end }] }] }. Times only.';

-- ----------------------------------------------------------------------------
-- Privileges
-- ----------------------------------------------------------------------------

revoke all on function
  booking.service_image_ok(jsonb),
  booking.get_opening_times(date, date),
  public.booking_get_opening_times(date, date)
from public, anon, authenticated, service_role;

-- Admins save services through the invoker function, which checks the image.
grant execute on function booking.service_image_ok(jsonb) to authenticated;

-- Visitors: opening times. The private function is executable but not
-- reachable by URL (schema `booking` is not exposed); the wrapper is the entry.
grant execute on function
  booking.get_opening_times(date, date),
  public.booking_get_opening_times(date, date)
to anon, authenticated, service_role;

update booking.engine_info set schema_version = '2.0.0-alpha.10', updated_at = now() where id;
