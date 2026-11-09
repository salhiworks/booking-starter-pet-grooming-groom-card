-- ============================================================================
-- Profit Studio Booking Engine — migration 0002_security_hardening
-- Engine schema version: 2.0.0-alpha.2
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Fixes from the Phase 1 independent security review:
--   1. booking_create rejects non-finite or out-of-window start times before
--      any slot computation ('infinity' made slot generation run until the
--      statement timeout); compute_slots is bounded for every input.
--   2. Rate limits hold under concurrency (transaction advisory locks per
--      email and per client); IPv6 clients are grouped by /64; a missing,
--      blank or invalid client IP is one shared, limited bucket instead of
--      "no limit"; a site-wide hourly cap on website bookings (owner setting).
--   3. Limits are checked after the slot check and never say which limit was
--      hit, so the endpoint no longer reveals whether an email has bookings.
--   4. service_role can use the public read functions (server-side callers).
--   5. add_admin requires a confirmed email; remove_admin reports no match.
--   6. Client identifiers are hashed with a per-installation secret salt.
-- Existing data is preserved. Function signatures are unchanged.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.1' then
    raise exception 'Booking Engine 0002_security_hardening expects schema 2.0.0-alpha.1, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Schema additions (additive only)
-- ----------------------------------------------------------------------------

alter table booking.settings
  add column max_website_bookings_per_hour int not null default 30
    check (max_website_bookings_per_hour between 1 and 1000);
comment on column booking.settings.max_website_bookings_per_hour is
  'Site-wide cap on new website bookings per rolling hour: a circuit breaker against calendar-filling spam.';

create table booking.engine_secrets (
  id boolean primary key default true check (id),
  hash_salt text not null default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
);
comment on table booking.engine_secrets is 'Per-installation secrets (never exposed). hash_salt salts client identifiers in request_log.';
alter table booking.engine_secrets enable row level security;
revoke all on booking.engine_secrets from public, anon, authenticated, service_role;
insert into booking.engine_secrets default values;

-- Rows hashed without a salt are discarded; they only ever covered 24 hours.
delete from booking.request_log r where r.id is not null;

create index bookings_created_at on booking.bookings (created_at);

-- ----------------------------------------------------------------------------
-- Client identity for rate limiting
-- ----------------------------------------------------------------------------

-- Best-effort client IP from PostgREST request headers. Blank values are
-- ignored. Which header is trustworthy on hosted Supabase is still unverified
-- (docs/SECURITY.md).
create or replace function booking.client_ip()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  h jsonb;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    return null;
  end;
  if h is null or jsonb_typeof(h) <> 'object' then
    return null;
  end if;
  return left(coalesce(
    nullif(btrim(h ->> 'cf-connecting-ip'), ''),
    nullif(btrim(h ->> 'x-real-ip'), ''),
    nullif(btrim(split_part(h ->> 'x-forwarded-for', ',', 1)), '')
  ), 64);
end;
$$;

-- Normalised client key: 'ip4:<address>', 'ip6:<network>/64' or 'unknown'.
create function booking.client_key()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := booking.client_ip();
  v_inet inet;
begin
  if v is null then
    return 'unknown';
  end if;
  begin
    v_inet := v::inet;
  exception when others then
    return 'unknown';
  end;
  if family(v_inet) = 6 and v_inet << '::ffff:0:0/96'::inet then
    v_inet := '0.0.0.0'::inet + (v_inet - '::ffff:0:0'::inet);
  end if;
  if family(v_inet) = 6 then
    return 'ip6:' || host(network(set_masklen(v_inet, 64))) || '/64';
  end if;
  return 'ip4:' || host(v_inet);
end;
$$;

-- ----------------------------------------------------------------------------
-- Bounded slot computation (same signature, same results for valid input)
-- ----------------------------------------------------------------------------

create or replace function booking.compute_slots(
  p_service_id uuid,
  p_from date,
  p_to date,
  p_now timestamptz,
  p_resource_id uuid default null
)
returns table (starts_at timestamptz, ends_at timestamptz, local_date date)
language sql
stable
set search_path = ''
as $$
  with s as (
    select st.timezone, st.slot_interval_minutes, st.min_notice_minutes, st.max_advance_days
    from booking.settings st
    where st.id
  ),
  svc as (
    select sv.duration_minutes, sv.buffer_after_minutes
    from booking.services sv
    where sv.id = p_service_id and sv.is_active
  ),
  res as (
    select r.id
    from booking.resources r
    where r.is_active
      and (r.id = p_resource_id or (p_resource_id is null and r.is_default))
  ),
  -- At most 400 days; non-finite input yields no days at all.
  days as (
    select p_from + g.n as day
    from generate_series(
      0,
      case
        when p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to) or not isfinite(p_now) then -1
        else least(p_to - p_from, 400)
      end
    ) as g(n)
  ),
  windows as (
    select dd.day,
           (dd.day + wh.start_time) at time zone s.timezone as open_at,
           (dd.day + wh.end_time) at time zone s.timezone as close_at
    from days dd
    cross join s
    join booking.working_hours wh on wh.weekday = extract(isodow from dd.day)::int
  ),
  candidates as (
    select w.day,
           g.slot_start,
           g.slot_start + make_interval(mins => svc.duration_minutes) as slot_end,
           g.slot_start + make_interval(mins => svc.duration_minutes + svc.buffer_after_minutes) as blocked_until
    from windows w
    cross join svc
    cross join s
    cross join lateral generate_series(
      w.open_at,
      w.close_at - make_interval(mins => svc.duration_minutes),
      make_interval(mins => s.slot_interval_minutes)
    ) as g(slot_start)
  )
  select c.slot_start, c.slot_end, c.day
  from candidates c
  cross join s
  cross join res
  where c.slot_start >= p_now + make_interval(mins => s.min_notice_minutes)
    and c.day <= (p_now at time zone s.timezone)::date + s.max_advance_days
    and not exists (
      select 1
      from booking.bookings b
      where b.resource_id = res.id
        and b.status in ('pending', 'confirmed')
        and tstzrange(b.starts_at, b.blocked_until, '[)') && tstzrange(c.slot_start, c.blocked_until, '[)')
    )
    and not exists (
      select 1
      from booking.availability_exceptions e
      where c.day between e.starts_on and e.ends_on
        and (
          e.start_time is null
          or tstzrange((c.day + e.start_time) at time zone s.timezone,
                       (c.day + e.end_time) at time zone s.timezone, '[)')
             && tstzrange(c.slot_start, c.slot_end, '[)')
        )
    )
  order by c.slot_start;
$$;

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

create or replace function public.booking_get_availability(p_service_id uuid, p_from date, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_max_days constant int := 42;
  v_to date := coalesce(p_to, p_from);
  v_settings booking.settings%rowtype;
  v_today date;
  v_last date;
  v_result jsonb;
begin
  if p_service_id is null then
    perform booking.raise_error('INVALID_INPUT', 'serviceId');
  end if;
  if p_from is null or not isfinite(p_from) then
    perform booking.raise_error('INVALID_INPUT', 'from');
  end if;
  if not isfinite(v_to) or v_to < p_from or v_to - p_from >= c_max_days then
    perform booking.raise_error('INVALID_INPUT', 'to');
  end if;
  if not exists (select 1 from booking.services sv where sv.id = p_service_id and sv.is_active) then
    perform booking.raise_error('SERVICE_UNAVAILABLE');
  end if;

  select * into v_settings from booking.settings where id;
  v_today := (now() at time zone v_settings.timezone)::date;
  v_last := v_today + v_settings.max_advance_days;

  with days as (
    select p_from + g.n as day
    from generate_series(0, v_to - p_from) as g(n)
  ),
  slots as (
    select cs.starts_at, cs.ends_at, cs.local_date
    from booking.compute_slots(p_service_id, greatest(p_from, v_today), least(v_to, v_last), now()) as cs
  )
  select jsonb_build_object(
    'serviceId', p_service_id,
    'timezone', v_settings.timezone,
    'from', to_char(p_from, 'YYYY-MM-DD'),
    'to', to_char(v_to, 'YYYY-MM-DD'),
    'days', coalesce(jsonb_agg(
      jsonb_build_object(
        'date', to_char(dd.day, 'YYYY-MM-DD'),
        'status', case
          when dd.day < v_today or dd.day > v_last then 'unavailable'
          when not exists (select 1 from booking.working_hours wh where wh.weekday = extract(isodow from dd.day)::int)
            or exists (select 1 from booking.availability_exceptions e
                       where dd.day between e.starts_on and e.ends_on and e.start_time is null) then 'closed'
          when exists (select 1 from slots sl where sl.local_date = dd.day) then 'available'
          else 'full'
        end,
        'slots', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'startsAt', booking.iso(sl.starts_at),
                     'endsAt', booking.iso(sl.ends_at),
                     'time', to_char(sl.starts_at at time zone v_settings.timezone, 'HH24:MI')
                   ) order by sl.starts_at)
          from slots sl
          where sl.local_date = dd.day
        ), '[]'::jsonb)
      ) order by dd.day), '[]'::jsonb)
  )
  into v_result
  from days dd;

  return v_result;
end;
$$;

create or replace function public.booking_create(
  p_service_id uuid,
  p_starts_at timestamptz,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_client_limit_per_hour constant int := 10;
  v_settings booking.settings%rowtype;
  v_service booking.services%rowtype;
  v_resource_id uuid;
  v_name text := btrim(coalesce(p_customer_name, ''));
  v_email text := lower(btrim(coalesce(p_customer_email, '')));
  v_phone text := nullif(btrim(coalesce(p_customer_phone, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_local_day date;
  v_client text;
  v_bucket text;
  v_limit int;
  v_count int;
  v_status text;
  v_booking booking.bookings%rowtype;
  v_attempt int := 0;
begin
  -- 1. Validate the request itself (cheap, no table access).
  if p_service_id is null then
    perform booking.raise_error('INVALID_INPUT', 'serviceId');
  end if;
  if p_starts_at is null or not isfinite(p_starts_at) then
    perform booking.raise_error('INVALID_INPUT', 'startsAt');
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 120 or v_name ~ '[[:cntrl:]]' then
    perform booking.raise_error('INVALID_INPUT', 'customer.name');
  end if;
  if char_length(v_email) > 254
     or v_email !~ '^[^@[:space:]<>()]+@[^@[:space:]<>()]+\.[^@[:space:]<>()]{2,}$' then
    perform booking.raise_error('INVALID_INPUT', 'customer.email');
  end if;
  if v_phone is not null and (
       char_length(v_phone) > 40
       or v_phone !~ '^[0-9+()./[:space:]-]+$'
       or char_length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 5) then
    perform booking.raise_error('INVALID_INPUT', 'customer.phone');
  end if;
  if v_notes is not null and (char_length(v_notes) > 1000 or v_notes ~ '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]') then
    perform booking.raise_error('INVALID_INPUT', 'notes');
  end if;

  select * into v_settings from booking.settings where id;
  if v_settings.require_phone and v_phone is null then
    perform booking.raise_error('INVALID_INPUT', 'customer.phone');
  end if;

  -- 2. Only times inside the booking window are worth computing.
  if p_starts_at < now() or p_starts_at > now() + make_interval(days => v_settings.max_advance_days + 1) then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  select * into v_service from booking.services where id = p_service_id and is_active;
  if not found then
    perform booking.raise_error('SERVICE_UNAVAILABLE');
  end if;

  select r.id into v_resource_id from booking.resources r where r.is_default and r.is_active;
  if v_resource_id is null then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  -- 3. The start must be a slot the engine offers right now.
  v_local_day := (p_starts_at at time zone v_settings.timezone)::date;
  if not exists (
    select 1
    from booking.compute_slots(p_service_id, v_local_day, v_local_day, now(), v_resource_id) as cs
    where cs.starts_at = p_starts_at
  ) then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  -- 4. Abuse limits — after the slot check, without saying which limit was
  --    hit, and serialised per email and per client so concurrent requests
  --    cannot all slip under a limit. Lock order: email, then client.
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:email:' || v_email, 0));
  select count(*) into v_count
  from booking.bookings b
  where lower(b.customer_email) = v_email
    and b.status in ('pending', 'confirmed')
    and b.starts_at > now();
  if v_count >= v_settings.max_active_bookings_per_email then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  v_client := booking.client_key();
  v_bucket := 'client:' || encode(sha256(convert_to(
    (select es.hash_salt from booking.engine_secrets es where es.id) || ':' || v_client, 'UTF8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:' || v_bucket, 0));
  v_limit := case when v_client = 'unknown' then v_settings.max_website_bookings_per_hour else c_client_limit_per_hour end;
  select count(*) into v_count
  from booking.request_log r
  where r.bucket = v_bucket and r.created_at > now() - interval '1 hour';
  if v_count >= v_limit then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  select count(*) into v_count
  from booking.bookings b
  where b.source = 'website' and b.created_at > now() - interval '1 hour';
  if v_count >= v_settings.max_website_bookings_per_hour then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  v_status := case when v_settings.auto_confirm then 'confirmed' else 'pending' end;

  -- 5. Insert. Under concurrency the exclusion constraint decides.
  loop
    v_attempt := v_attempt + 1;
    begin
      insert into booking.bookings (
        reference, service_id, resource_id, starts_at, ends_at, blocked_until, status,
        customer_name, customer_email, customer_phone, customer_notes,
        service_name, price_cents, currency, source
      ) values (
        booking.new_reference(), v_service.id, v_resource_id, p_starts_at,
        p_starts_at + make_interval(mins => v_service.duration_minutes),
        p_starts_at + make_interval(mins => v_service.duration_minutes + v_service.buffer_after_minutes),
        v_status, v_name, v_email, v_phone, v_notes,
        v_service.name, v_service.price_cents, v_settings.currency, 'website'
      )
      returning * into v_booking;
      exit;
    exception
      when exclusion_violation then
        perform booking.raise_error('SLOT_UNAVAILABLE');
      when unique_violation then
        if v_attempt >= 3 then
          raise;
        end if;
    end;
  end loop;

  insert into booking.booking_events (booking_id, event_type, to_status, actor)
  values (v_booking.id, 'created', v_booking.status, 'customer');

  insert into booking.request_log (bucket) values (v_bucket);
  delete from booking.request_log r where r.created_at < now() - interval '1 day';

  return jsonb_build_object(
    'reference', v_booking.reference,
    'status', v_booking.status,
    'startsAt', booking.iso(v_booking.starts_at),
    'endsAt', booking.iso(v_booking.ends_at),
    'date', to_char(v_booking.starts_at at time zone v_settings.timezone, 'YYYY-MM-DD'),
    'time', to_char(v_booking.starts_at at time zone v_settings.timezone, 'HH24:MI'),
    'serviceName', v_booking.service_name,
    'timezone', v_settings.timezone
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- Admin API
-- ----------------------------------------------------------------------------

create or replace function public.booking_admin_list_bookings(p_from date, p_to date, p_statuses text[] default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tz text;
  v_result jsonb;
begin
  perform booking.require_admin();
  if p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to)
     or p_to < p_from or p_to - p_from > 400 then
    perform booking.raise_error('INVALID_INPUT', 'range');
  end if;
  if p_statuses is not null and exists (
       select 1 from unnest(p_statuses) as st(v)
       where st.v is null or st.v not in ('pending', 'confirmed', 'completed', 'cancelled', 'no_show')) then
    perform booking.raise_error('INVALID_INPUT', 'statuses');
  end if;

  select s.timezone into v_tz from booking.settings s where s.id;

  select coalesce(jsonb_agg(booking.booking_json(b, v_tz) order by b.starts_at), '[]'::jsonb)
  into v_result
  from booking.bookings b
  where b.id in (
    select b2.id
    from booking.bookings b2
    where b2.starts_at >= (p_from::timestamp at time zone v_tz)
      and b2.starts_at < ((p_to + 1)::timestamp at time zone v_tz)
      and (p_statuses is null or b2.status = any (p_statuses))
    order by b2.starts_at
    limit 1000
  );
  return v_result;
end;
$$;

create or replace function booking.settings_json()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'businessName', s.business_name,
    'timezone', s.timezone,
    'currency', s.currency,
    'locale', s.locale,
    'publicEmail', s.public_email,
    'publicPhone', s.public_phone,
    'address', s.address,
    'slotIntervalMinutes', s.slot_interval_minutes,
    'minNoticeMinutes', s.min_notice_minutes,
    'maxAdvanceDays', s.max_advance_days,
    'autoConfirm', s.auto_confirm,
    'requirePhone', s.require_phone,
    'maxActiveBookingsPerEmail', s.max_active_bookings_per_email,
    'maxWebsiteBookingsPerHour', s.max_website_bookings_per_hour,
    'updatedAt', booking.iso(s.updated_at)
  )
  from booking.settings s
  where s.id;
$$;

create or replace function public.booking_admin_update_settings(p_settings jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_allowed text[] := array['businessName', 'timezone', 'currency', 'locale', 'publicEmail', 'publicPhone',
                            'address', 'slotIntervalMinutes', 'minNoticeMinutes', 'maxAdvanceDays',
                            'autoConfirm', 'requirePhone', 'maxActiveBookingsPerEmail', 'maxWebsiteBookingsPerHour'];
  v_key text;
  v_email text;
begin
  perform booking.require_admin();
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    perform booking.raise_error('INVALID_INPUT', 'settings');
  end if;
  for v_key in select jsonb_object_keys(p_settings) loop
    if not (v_key = any (v_allowed)) then
      perform booking.raise_error('INVALID_INPUT', v_key);
    end if;
  end loop;

  v_email := lower(booking.j_text(p_settings, 'publicEmail', 254));
  if v_email is not null and v_email !~ '^[^@[:space:]<>()]+@[^@[:space:]<>()]+\.[^@[:space:]<>()]{2,}$' then
    perform booking.raise_error('INVALID_INPUT', 'publicEmail');
  end if;
  if p_settings ? 'currency' and coalesce(booking.j_text(p_settings, 'currency', 3), '') !~ '^[A-Z]{3}$' then
    perform booking.raise_error('INVALID_INPUT', 'currency');
  end if;
  if p_settings ? 'locale'
     and coalesce(booking.j_text(p_settings, 'locale', 35), '') !~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$' then
    perform booking.raise_error('INVALID_INPUT', 'locale');
  end if;

  update booking.settings set
    business_name = case when p_settings ? 'businessName'
                         then booking.j_required_text(p_settings, 'businessName', 120) else business_name end,
    timezone = case when p_settings ? 'timezone' then booking.j_required_text(p_settings, 'timezone', 64) else timezone end,
    currency = case when p_settings ? 'currency' then booking.j_required_text(p_settings, 'currency', 3) else currency end,
    locale = case when p_settings ? 'locale' then booking.j_required_text(p_settings, 'locale', 35) else locale end,
    public_email = case when p_settings ? 'publicEmail' then v_email else public_email end,
    public_phone = case when p_settings ? 'publicPhone' then booking.j_text(p_settings, 'publicPhone', 40) else public_phone end,
    address = case when p_settings ? 'address' then booking.j_text(p_settings, 'address', 300) else address end,
    slot_interval_minutes = case when p_settings ? 'slotIntervalMinutes'
      then coalesce(booking.j_int(p_settings, 'slotIntervalMinutes', 5, 240), slot_interval_minutes) else slot_interval_minutes end,
    min_notice_minutes = case when p_settings ? 'minNoticeMinutes'
      then coalesce(booking.j_int(p_settings, 'minNoticeMinutes', 0, 43200), min_notice_minutes) else min_notice_minutes end,
    max_advance_days = case when p_settings ? 'maxAdvanceDays'
      then coalesce(booking.j_int(p_settings, 'maxAdvanceDays', 1, 730), max_advance_days) else max_advance_days end,
    auto_confirm = case when p_settings ? 'autoConfirm'
      then coalesce(booking.j_bool(p_settings, 'autoConfirm'), auto_confirm) else auto_confirm end,
    require_phone = case when p_settings ? 'requirePhone'
      then coalesce(booking.j_bool(p_settings, 'requirePhone'), require_phone) else require_phone end,
    max_active_bookings_per_email = case when p_settings ? 'maxActiveBookingsPerEmail'
      then coalesce(booking.j_int(p_settings, 'maxActiveBookingsPerEmail', 1, 50), max_active_bookings_per_email)
      else max_active_bookings_per_email end,
    max_website_bookings_per_hour = case when p_settings ? 'maxWebsiteBookingsPerHour'
      then coalesce(booking.j_int(p_settings, 'maxWebsiteBookingsPerHour', 1, 1000), max_website_bookings_per_hour)
      else max_website_bookings_per_hour end
  where id;

  return booking.settings_json();
end;
$$;

create or replace function public.booking_admin_apply_preset(p_preset jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_item jsonb;
  v_count int := 0;
begin
  perform booking.require_admin();
  if p_preset is null or coalesce(jsonb_typeof(p_preset), '') <> 'object'
     or coalesce(jsonb_typeof(p_preset -> 'services'), '') <> 'array'
     or jsonb_array_length(p_preset -> 'services') not between 1 and 50 then
    perform booking.raise_error('INVALID_INPUT', 'preset');
  end if;
  if exists (select 1 from booking.services) then
    perform booking.raise_error('CONFLICT', 'services_exist');
  end if;

  for v_item in select value from jsonb_array_elements(p_preset -> 'services') loop
    if jsonb_typeof(v_item) <> 'object' then
      perform booking.raise_error('INVALID_INPUT', 'preset.services');
    end if;
    v_count := v_count + 1;
    perform public.booking_admin_save_service(
      jsonb_strip_nulls(jsonb_build_object(
        'name', v_item -> 'name',
        'description', v_item -> 'description',
        'durationMinutes', v_item -> 'durationMinutes',
        'bufferAfterMinutes', v_item -> 'bufferAfterMinutes',
        'priceCents', v_item -> 'priceCents',
        'priceFrom', v_item -> 'priceFrom',
        'sortOrder', to_jsonb(v_count * 10)
      )));
  end loop;

  if jsonb_typeof(p_preset -> 'workingHours') = 'array' then
    perform public.booking_admin_set_working_hours(p_preset -> 'workingHours');
  end if;
  if jsonb_typeof(p_preset -> 'policies') = 'object' then
    perform public.booking_admin_update_settings(p_preset -> 'policies');
  end if;

  return jsonb_build_object('servicesAdded', v_count);
end;
$$;

-- ----------------------------------------------------------------------------
-- Owner tools (SQL editor)
-- ----------------------------------------------------------------------------

create or replace function booking.add_admin(p_email text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_ids uuid[];
  v_confirmed boolean;
begin
  select array_agg(u.id), bool_and(u.email_confirmed_at is not null)
  into v_ids, v_confirmed
  from auth.users u
  where lower(u.email) = v_email;
  if v_ids is null then
    raise exception 'No Supabase Auth user with email "%". Create the user first: Authentication > Users > Add user.', v_email;
  end if;
  if array_length(v_ids, 1) > 1 then
    raise exception 'More than one Auth user has email "%"; add the admin by user id instead.', v_email;
  end if;
  if not v_confirmed then
    raise exception 'The Auth user "%" has not confirmed their email. Confirm it (or create the user with Auto Confirm) first.', v_email;
  end if;
  insert into booking.admins (user_id) values (v_ids[1]) on conflict (user_id) do nothing;
  return 'Admin access granted to ' || v_email || ' (user ' || v_ids[1]::text || ')';
end;
$$;

create or replace function booking.remove_admin(p_email text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_removed int;
begin
  delete from booking.admins a
  using auth.users u
  where u.id = a.user_id and lower(u.email) = v_email;
  get diagnostics v_removed = row_count;
  if v_removed = 0 then
    raise exception 'No admin with email "%" was found. List admins with: select u.email from booking.admins a join auth.users u on u.id = a.user_id;', v_email;
  end if;
  return 'Admin access removed from ' || v_email;
end;
$$;

-- ----------------------------------------------------------------------------
-- Privileges
-- ----------------------------------------------------------------------------

revoke all on function booking.client_key() from public, anon, authenticated, service_role;

-- Server-side callers (secret key → service_role) can use the public reads.
grant usage on schema booking to service_role;
grant select on booking.engine_info, booking.services, booking.working_hours to service_role;
grant select (id, business_name, timezone, currency, locale, public_email, public_phone, address,
              slot_interval_minutes, min_notice_minutes, max_advance_days, auto_confirm, require_phone)
  on booking.settings to service_role;
grant execute on function booking.hhmm(time) to service_role;

update booking.engine_info set schema_version = '2.0.0-alpha.2', updated_at = now() where id;
