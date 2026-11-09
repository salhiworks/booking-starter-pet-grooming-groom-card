-- ============================================================================
-- Profit Studio Booking Engine — migration 0001_core
-- Engine schema version: 2.0.0-alpha.1
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
-- Changes ship as NEW migrations in new engine versions.
--
-- What this creates
--   * schema "booking" — private tables. It is NOT added to the Data API's
--     exposed schemas, so tables are never reachable by URL.
--   * public.booking_* functions — the only API surface (PostgREST RPC).
--
-- Security model (see docs/SECURITY.md)
--   * RLS is enabled on every table. Default is deny.
--   * Public reads of public data (business profile, active services, opening
--     hours) are SECURITY INVOKER functions over column-limited grants + RLS.
--   * Exactly TWO functions are SECURITY DEFINER, on purpose:
--       booking_get_availability — must see existing bookings to compute free
--                                  slots; returns times only, never people.
--       booking_create           — must insert into a table anon cannot touch;
--                                  validates every input and re-checks the slot.
--   * Admin functions are SECURITY INVOKER: admins pass RLS because
--     booking.is_admin() is true for them. Each also checks explicitly, so a
--     non-admin gets NOT_AUTHORIZED instead of an empty result.
--   * Every function pins search_path = ''. EXECUTE is revoked from PUBLIC and
--     granted per role explicitly at the end of this file.
--   * Double booking is impossible at the database level: an exclusion
--     constraint over (resource, time range incl. buffer) for active bookings.
--
-- Error contract: errors are raised with SQLSTATE P0001 and the message
-- 'booking_engine:<CODE>'; DETAIL carries the field or reason, if any.
-- ============================================================================

do $$
begin
  if to_regnamespace('booking') is not null then
    raise exception 'Booking Engine 0001_core: schema "booking" already exists. This migration must run exactly once.';
  end if;
end
$$;

create extension if not exists btree_gist with schema extensions;

create schema booking;
comment on schema booking is
  'Profit Studio Booking Engine (engine-owned). Private: accessed through public.booking_* functions only.';

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

create table booking.engine_info (
  id boolean primary key default true check (id),
  engine text not null default 'profitstudio-booking-engine',
  schema_version text not null,
  installed_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table booking.engine_info is 'One row. The engine schema version the database is at; checked by the client.';

create table booking.settings (
  id boolean primary key default true check (id),
  -- Business profile (public)
  business_name text not null default 'My Business'
    check (char_length(btrim(business_name)) between 1 and 120),
  timezone text not null default 'UTC' check (char_length(timezone) between 1 and 64),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  locale text not null default 'en-US' check (locale ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
  public_email text check (public_email is null or char_length(public_email) <= 254),
  public_phone text check (public_phone is null or char_length(public_phone) <= 40),
  address text check (address is null or char_length(address) <= 300),
  -- Booking policies
  slot_interval_minutes int not null default 15 check (slot_interval_minutes between 5 and 240),
  min_notice_minutes int not null default 120 check (min_notice_minutes between 0 and 43200),
  max_advance_days int not null default 60 check (max_advance_days between 1 and 730),
  auto_confirm boolean not null default false,
  require_phone boolean not null default true,
  max_active_bookings_per_email int not null default 3 check (max_active_bookings_per_email between 1 and 50),
  updated_at timestamptz not null default now()
);
comment on table booking.settings is 'One row. Business profile and booking policies, edited in the admin dashboard.';

create table booking.resources (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index resources_single_default on booking.resources (is_default) where is_default;
comment on table booking.resources is
  'What a booking occupies (a chair, a person, a room). 2.0 uses one default resource; staff/rooms arrive in a later version without changing the conflict rule.';

create table booking.services (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  description text check (description is null or char_length(description) <= 2000),
  duration_minutes int not null check (duration_minutes between 5 and 720),
  buffer_after_minutes int not null default 0 check (buffer_after_minutes between 0 and 240),
  price_cents int check (price_cents is null or price_cents between 0 and 100000000),
  price_from boolean not null default false,
  is_active boolean not null default true,
  sort_order int not null default 0 check (sort_order between -100000 and 100000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column booking.services.buffer_after_minutes is 'Cleanup time after the service. Blocks the calendar but is not shown to customers.';
comment on column booking.services.price_from is 'Display hint: the price is a starting price ("from $65").';

create table booking.working_hours (
  id uuid primary key default gen_random_uuid(),
  weekday smallint not null check (weekday between 1 and 7),
  start_time time not null,
  end_time time not null,
  check (start_time < end_time),
  constraint working_hours_no_overlap exclude using gist (
    weekday with =,
    tsrange('2000-01-01'::date + start_time, '2000-01-01'::date + end_time, '[)') with &&
  )
);
comment on table booking.working_hours is
  'Weekly opening hours in the business time zone. ISO weekday: 1 = Monday … 7 = Sunday. Several rows per day = breaks.';

create table booking.availability_exceptions (
  id uuid primary key default gen_random_uuid(),
  starts_on date not null,
  ends_on date not null,
  start_time time,
  end_time time,
  reason text check (reason is null or char_length(reason) <= 200),
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  check (ends_on - starts_on <= 366),
  check (
    (start_time is null and end_time is null)
    or (start_time is not null and end_time is not null and start_time < end_time)
  )
);
create index availability_exceptions_dates on booking.availability_exceptions (starts_on, ends_on);
comment on table booking.availability_exceptions is
  'Closures in business-local dates: whole days (no times) or a time range on each day of the range.';

create table booking.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique check (reference ~ '^[A-HJ-NP-Z2-9]{8}$'),
  service_id uuid not null references booking.services (id) on delete restrict,
  resource_id uuid not null references booking.resources (id) on delete restrict,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  blocked_until timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'completed', 'cancelled', 'no_show')),
  customer_name text not null check (char_length(customer_name) between 1 and 120),
  customer_email text not null check (char_length(customer_email) between 3 and 254),
  customer_phone text check (customer_phone is null or char_length(customer_phone) between 5 and 40),
  customer_notes text check (customer_notes is null or char_length(customer_notes) <= 1000),
  service_name text not null,
  price_cents int,
  currency text not null,
  source text not null default 'website' check (source in ('website', 'admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  status_changed_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (blocked_until >= ends_at),
  constraint bookings_no_overlap exclude using gist (
    resource_id with =,
    tstzrange(starts_at, blocked_until, '[)') with &&
  ) where (status in ('pending', 'confirmed'))
);
create index bookings_starts_at on booking.bookings (starts_at);
create index bookings_resource_starts_at on booking.bookings (resource_id, starts_at);
create index bookings_service on booking.bookings (service_id);
create index bookings_email on booking.bookings (lower(customer_email), starts_at);
comment on constraint bookings_no_overlap on booking.bookings is
  'The double-booking guarantee: two active bookings can never overlap on one resource, including buffer time. Holds under concurrent requests.';
comment on column booking.bookings.service_name is 'Snapshot at booking time; later service edits do not rewrite history.';

create table booking.booking_events (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references booking.bookings (id) on delete cascade,
  event_type text not null check (event_type in ('created', 'status_changed')),
  from_status text,
  to_status text,
  actor text not null check (actor in ('customer', 'admin', 'system')),
  actor_user_id uuid,
  created_at timestamptz not null default now()
);
create index booking_events_booking on booking.booking_events (booking_id, created_at);
comment on table booking.booking_events is
  'Append-only history of every booking. Future notification modules read from here.';

create table booking.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
comment on table booking.admins is 'Supabase Auth users allowed into the admin dashboard. Managed with booking.add_admin(email).';

create table booking.request_log (
  id uuid primary key default gen_random_uuid(),
  bucket text not null,
  created_at timestamptz not null default now()
);
create index request_log_bucket on booking.request_log (bucket, created_at);
comment on table booking.request_log is
  'Rate-limit counters for public booking creation. Stores SHA-256 hashes only, kept for 24 hours.';

insert into booking.settings default values;
insert into booking.resources (name, is_default) values ('Main calendar', true);

-- ----------------------------------------------------------------------------
-- Triggers
-- ----------------------------------------------------------------------------

create function booking.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create function booking.validate_settings()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = new.timezone) then
    raise exception using errcode = 'P0001', message = 'booking_engine:INVALID_INPUT', detail = 'timezone';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger settings_validate before insert or update on booking.settings
  for each row execute function booking.validate_settings();
create trigger services_touch before update on booking.services
  for each row execute function booking.touch_updated_at();
create trigger bookings_touch before update on booking.bookings
  for each row execute function booking.touch_updated_at();

-- ----------------------------------------------------------------------------
-- Internal helpers (schema booking; not callable through the API)
-- ----------------------------------------------------------------------------

create function booking.raise_error(p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'booking_engine:' || p_code,
    detail = coalesce(p_detail, '');
end;
$$;

create function booking.is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from booking.admins a where a.user_id = (select auth.uid()));
$$;

create function booking.require_admin()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not booking.is_admin() then
    perform booking.raise_error('NOT_AUTHORIZED');
  end if;
  return v_uid;
end;
$$;

create function booking.iso(p timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
$$;

create function booking.hhmm(p time)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p = '24:00'::time then '24:00' else to_char(p, 'HH24:MI') end;
$$;

-- JSON input readers for admin functions. Each raises INVALID_INPUT(<key>)
-- on a wrong type or range; a missing key or JSON null returns NULL.
create function booking.j_text(p jsonb, p_key text, p_max_len int)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  t text := jsonb_typeof(p -> p_key);
  v text;
begin
  if t is null or t = 'null' then
    return null;
  end if;
  if t <> 'string' then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  v := btrim(p ->> p_key);
  if char_length(v) > p_max_len or v ~ '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]' then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  return nullif(v, '');
end;
$$;

create function booking.j_required_text(p jsonb, p_key text, p_max_len int)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := booking.j_text(p, p_key, p_max_len);
begin
  if v is null then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  return v;
end;
$$;

create function booking.j_int(p jsonb, p_key text, p_min int, p_max int)
returns int
language plpgsql
stable
set search_path = ''
as $$
declare
  t text := jsonb_typeof(p -> p_key);
  v numeric;
begin
  if t is null or t = 'null' then
    return null;
  end if;
  if t <> 'number' then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  v := (p ->> p_key)::numeric;
  if v <> trunc(v) or v < p_min or v > p_max then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  return v::int;
end;
$$;

create function booking.j_bool(p jsonb, p_key text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  t text := jsonb_typeof(p -> p_key);
begin
  if t is null or t = 'null' then
    return null;
  end if;
  if t <> 'boolean' then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  return (p ->> p_key)::boolean;
end;
$$;

-- 'HH:MM' (24-hour). '24:00' only when p_allow_24 (an end of day).
create function booking.j_time(p jsonb, p_key text, p_allow_24 boolean)
returns time
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := booking.j_text(p, p_key, 5);
begin
  if v is null then
    return null;
  end if;
  if v ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or (p_allow_24 and v = '24:00') then
    return v::time;
  end if;
  perform booking.raise_error('INVALID_INPUT', p_key);
  return null;
end;
$$;

create function booking.j_date(p jsonb, p_key text)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := booking.j_text(p, p_key, 10);
  d date;
begin
  if v is null then
    return null;
  end if;
  if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  begin
    d := v::date;
  exception when others then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end;
  if to_char(d, 'YYYY-MM-DD') <> v then
    perform booking.raise_error('INVALID_INPUT', p_key);
  end if;
  return d;
end;
$$;

-- Random 8-character booking reference without look-alike characters.
create function booking.new_reference()
returns text
language sql
volatile
set search_path = ''
as $$
  select string_agg(
           substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (get_byte(r.b, i.n) % 32) + 1, 1),
           '' order by i.n)
  from (select uuid_send(gen_random_uuid()) as b) as r
  cross join unnest(array[0, 1, 2, 3, 4, 5, 10, 11]) as i(n);
$$;

-- Best-effort client IP from the request headers PostgREST exposes.
-- Unverified on hosted Supabase: see docs/SECURITY.md.
create function booking.client_ip()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  h jsonb;
  v text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    return null;
  end;
  if h is null then
    return null;
  end if;
  v := coalesce(h ->> 'cf-connecting-ip', h ->> 'x-real-ip', split_part(h ->> 'x-forwarded-for', ',', 1));
  return left(nullif(btrim(v), ''), 64);
end;
$$;

-- THE availability algorithm. Pure function of the tables and p_now.
-- Slots are generated per opening window as absolute instants:
--   open/close = (local date + local time) AT TIME ZONE business tz,
--   then stepped by the slot interval in real elapsed time.
-- So on DST days a nonexistent local time is never offered and a repeated
-- local hour is offered as two distinct instants.
create function booking.compute_slots(
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
  days as (
    select d::date as day
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as d
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

create function booking.booking_json(b booking.bookings, p_tz text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', b.id,
    'reference', b.reference,
    'status', b.status,
    'startsAt', booking.iso(b.starts_at),
    'endsAt', booking.iso(b.ends_at),
    'date', to_char(b.starts_at at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(b.starts_at at time zone p_tz, 'HH24:MI'),
    'endTime', to_char(b.ends_at at time zone p_tz, 'HH24:MI'),
    'serviceId', b.service_id,
    'serviceName', b.service_name,
    'priceCents', b.price_cents,
    'currency', b.currency,
    'customer', jsonb_build_object('name', b.customer_name, 'email', b.customer_email, 'phone', b.customer_phone),
    'notes', b.customer_notes,
    'source', b.source,
    'createdAt', booking.iso(b.created_at),
    'statusChangedAt', booking.iso(b.status_changed_at)
  );
$$;

create function booking.service_json(sv booking.services)
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
    'createdAt', booking.iso(sv.created_at),
    'updatedAt', booking.iso(sv.updated_at)
  );
$$;

create function booking.settings_json()
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
    'updatedAt', booking.iso(s.updated_at)
  )
  from booking.settings s
  where s.id;
$$;

-- Owner tools, run in the Supabase SQL editor (role postgres). Not exposed.
create function booking.add_admin(p_email text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_ids uuid[];
begin
  select array_agg(u.id) into v_ids from auth.users u where lower(u.email) = v_email;
  if v_ids is null then
    raise exception 'No Supabase Auth user with email "%". Create the user first: Authentication > Users > Add user.', v_email;
  end if;
  if array_length(v_ids, 1) > 1 then
    raise exception 'More than one Auth user has email "%"; add the admin by user id instead.', v_email;
  end if;
  insert into booking.admins (user_id) values (v_ids[1]) on conflict (user_id) do nothing;
  return 'Admin access granted to ' || v_email;
end;
$$;

create function booking.remove_admin(p_email text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  delete from booking.admins a
  using auth.users u
  where u.id = a.user_id and lower(u.email) = v_email;
  return 'Admin access removed from ' || v_email;
end;
$$;

-- ----------------------------------------------------------------------------
-- Row Level Security — default deny; explicit policies only
-- ----------------------------------------------------------------------------

alter table booking.engine_info enable row level security;
alter table booking.settings enable row level security;
alter table booking.resources enable row level security;
alter table booking.services enable row level security;
alter table booking.working_hours enable row level security;
alter table booking.availability_exceptions enable row level security;
alter table booking.bookings enable row level security;
alter table booking.booking_events enable row level security;
alter table booking.admins enable row level security;
alter table booking.request_log enable row level security;  -- no policies: definer-only

create policy engine_info_read on booking.engine_info
  for select to anon, authenticated using (true);

create policy settings_read on booking.settings
  for select to anon, authenticated using (true);
create policy settings_admin_update on booking.settings
  for update to authenticated
  using ((select booking.is_admin())) with check ((select booking.is_admin()));

create policy resources_admin_read on booking.resources
  for select to authenticated using ((select booking.is_admin()));

create policy services_public_read on booking.services
  for select to anon using (is_active);
create policy services_authenticated_read on booking.services
  for select to authenticated using (is_active or (select booking.is_admin()));
create policy services_admin_insert on booking.services
  for insert to authenticated with check ((select booking.is_admin()));
create policy services_admin_update on booking.services
  for update to authenticated
  using ((select booking.is_admin())) with check ((select booking.is_admin()));
create policy services_admin_delete on booking.services
  for delete to authenticated using ((select booking.is_admin()));

create policy working_hours_read on booking.working_hours
  for select to anon, authenticated using (true);
create policy working_hours_admin_insert on booking.working_hours
  for insert to authenticated with check ((select booking.is_admin()));
create policy working_hours_admin_update on booking.working_hours
  for update to authenticated
  using ((select booking.is_admin())) with check ((select booking.is_admin()));
create policy working_hours_admin_delete on booking.working_hours
  for delete to authenticated using ((select booking.is_admin()));

create policy exceptions_admin_read on booking.availability_exceptions
  for select to authenticated using ((select booking.is_admin()));
create policy exceptions_admin_insert on booking.availability_exceptions
  for insert to authenticated with check ((select booking.is_admin()));
create policy exceptions_admin_update on booking.availability_exceptions
  for update to authenticated
  using ((select booking.is_admin())) with check ((select booking.is_admin()));
create policy exceptions_admin_delete on booking.availability_exceptions
  for delete to authenticated using ((select booking.is_admin()));

create policy bookings_admin_read on booking.bookings
  for select to authenticated using ((select booking.is_admin()));
create policy bookings_admin_insert on booking.bookings
  for insert to authenticated with check ((select booking.is_admin()));
create policy bookings_admin_update on booking.bookings
  for update to authenticated
  using ((select booking.is_admin())) with check ((select booking.is_admin()));

create policy booking_events_admin_read on booking.booking_events
  for select to authenticated using ((select booking.is_admin()));
create policy booking_events_admin_insert on booking.booking_events
  for insert to authenticated with check ((select booking.is_admin()));

create policy admins_read_own on booking.admins
  for select to authenticated using (user_id = (select auth.uid()));

-- ----------------------------------------------------------------------------
-- Public API — SECURITY INVOKER reads of public data
-- ----------------------------------------------------------------------------

create function public.booking_engine_info()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object('engine', e.engine, 'schemaVersion', e.schema_version)
  from booking.engine_info e
  where e.id;
$$;
comment on function public.booking_engine_info() is
  'Public. Engine name and database schema version, for the client compatibility check.';

create function public.booking_get_business()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'name', s.business_name,
    'timezone', s.timezone,
    'currency', s.currency,
    'locale', s.locale,
    'contact', jsonb_build_object('email', s.public_email, 'phone', s.public_phone, 'address', s.address),
    'policies', jsonb_build_object(
      'slotIntervalMinutes', s.slot_interval_minutes,
      'minNoticeMinutes', s.min_notice_minutes,
      'maxAdvanceDays', s.max_advance_days,
      'autoConfirm', s.auto_confirm,
      'requirePhone', s.require_phone
    ),
    'openingHours', coalesce((
      select jsonb_agg(
               jsonb_build_object('weekday', w.weekday, 'start', booking.hhmm(w.start_time), 'end', booking.hhmm(w.end_time))
               order by w.weekday, w.start_time)
      from booking.working_hours w
    ), '[]'::jsonb)
  )
  from booking.settings s
  where s.id;
$$;
comment on function public.booking_get_business() is
  'Public. Business profile, public booking policies and weekly opening hours.';

create function public.booking_list_services()
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
             'currency', (select s.currency from booking.settings s where s.id)
           ) order by sv.sort_order, sv.name), '[]'::jsonb)
  from booking.services sv
  where sv.is_active;
$$;
comment on function public.booking_list_services() is 'Public. Active services in display order.';

-- ----------------------------------------------------------------------------
-- Public API — the two intentional SECURITY DEFINER functions
-- ----------------------------------------------------------------------------

create function public.booking_get_availability(p_service_id uuid, p_from date, p_to date default null)
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
  if p_from is null then
    perform booking.raise_error('INVALID_INPUT', 'from');
  end if;
  if v_to < p_from or v_to - p_from >= c_max_days then
    perform booking.raise_error('INVALID_INPUT', 'to');
  end if;
  if not exists (select 1 from booking.services sv where sv.id = p_service_id and sv.is_active) then
    perform booking.raise_error('SERVICE_UNAVAILABLE');
  end if;

  select * into v_settings from booking.settings where id;
  v_today := (now() at time zone v_settings.timezone)::date;
  v_last := v_today + v_settings.max_advance_days;

  with days as (
    select d::date as day
    from generate_series(p_from::timestamp, v_to::timestamp, interval '1 day') as d
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
comment on function public.booking_get_availability(uuid, date, date) is
  'Public, SECURITY DEFINER by design: reads existing bookings to compute free slots and returns times only. Dates are business-local; at most 42 days per call.';

create function public.booking_create(
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
  c_ip_limit_per_hour constant int := 10;
  v_settings booking.settings%rowtype;
  v_service booking.services%rowtype;
  v_resource_id uuid;
  v_name text := btrim(coalesce(p_customer_name, ''));
  v_email text := lower(btrim(coalesce(p_customer_email, '')));
  v_phone text := nullif(btrim(coalesce(p_customer_phone, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_local_day date;
  v_ip text;
  v_ip_bucket text;
  v_count int;
  v_status text;
  v_booking booking.bookings%rowtype;
  v_attempt int := 0;
begin
  -- 1. Validate the request itself.
  if p_service_id is null then
    perform booking.raise_error('INVALID_INPUT', 'serviceId');
  end if;
  if p_starts_at is null then
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

  select * into v_service from booking.services where id = p_service_id and is_active;
  if not found then
    perform booking.raise_error('SERVICE_UNAVAILABLE');
  end if;

  select r.id into v_resource_id from booking.resources r where r.is_default and r.is_active;
  if v_resource_id is null then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  -- 2. Abuse limits (see docs/SECURITY.md).
  select count(*) into v_count
  from booking.bookings b
  where lower(b.customer_email) = v_email
    and b.status in ('pending', 'confirmed')
    and b.starts_at > now();
  if v_count >= v_settings.max_active_bookings_per_email then
    perform booking.raise_error('RATE_LIMITED', 'email');
  end if;

  v_ip := booking.client_ip();
  if v_ip is not null then
    v_ip_bucket := 'ip:' || encode(sha256(convert_to(v_ip, 'UTF8')), 'hex');
    select count(*) into v_count
    from booking.request_log r
    where r.bucket = v_ip_bucket and r.created_at > now() - interval '1 hour';
    if v_count >= c_ip_limit_per_hour then
      perform booking.raise_error('RATE_LIMITED', 'ip');
    end if;
  end if;

  -- 3. The start must be a slot the engine offers right now: inside opening
  --    hours, on the slot grid, after the notice period, inside the booking
  --    window, outside closures, and free.
  v_local_day := (p_starts_at at time zone v_settings.timezone)::date;
  if not exists (
    select 1
    from booking.compute_slots(p_service_id, v_local_day, v_local_day, now(), v_resource_id) as cs
    where cs.starts_at = p_starts_at
  ) then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  v_status := case when v_settings.auto_confirm then 'confirmed' else 'pending' end;

  -- 4. Insert. Under concurrency the exclusion constraint decides: a second
  --    request for an overlapping time waits for the first and then fails.
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

  if v_ip_bucket is not null then
    insert into booking.request_log (bucket) values (v_ip_bucket);
    delete from booking.request_log r where r.created_at < now() - interval '1 day';
  end if;

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
comment on function public.booking_create(uuid, timestamptz, text, text, text, text) is
  'Public, SECURITY DEFINER by design: the only way to create a booking. Validates input, applies abuse limits, re-checks the slot, and relies on the exclusion constraint under concurrency.';

-- ----------------------------------------------------------------------------
-- Admin API — SECURITY INVOKER; RLS + an explicit admin check
-- ----------------------------------------------------------------------------

create function public.booking_admin_whoami()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'userId', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'isAdmin', booking.is_admin()
  );
$$;

create function public.booking_admin_list_bookings(p_from date, p_to date, p_statuses text[] default null)
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
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
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

create function public.booking_admin_set_booking_status(p_booking_id uuid, p_status text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid;
  v_tz text;
  b booking.bookings%rowtype;
  v_from text;
begin
  v_uid := booking.require_admin();
  if p_status is null or p_status not in ('confirmed', 'cancelled', 'completed', 'no_show') then
    perform booking.raise_error('INVALID_INPUT', 'status');
  end if;

  select * into b from booking.bookings where id = p_booking_id for update;
  if not found then
    perform booking.raise_error('NOT_FOUND', 'booking');
  end if;
  select s.timezone into v_tz from booking.settings s where s.id;

  if b.status = p_status then
    return booking.booking_json(b, v_tz);
  end if;
  if not (
    (b.status = 'pending' and p_status in ('confirmed', 'cancelled'))
    or (b.status = 'confirmed' and p_status in ('cancelled', 'completed', 'no_show'))
  ) then
    perform booking.raise_error('INVALID_TRANSITION', b.status || '->' || p_status);
  end if;
  if p_status in ('completed', 'no_show') and b.starts_at > now() then
    perform booking.raise_error('INVALID_TRANSITION', 'not_started');
  end if;

  v_from := b.status;
  update booking.bookings
     set status = p_status, status_changed_at = now()
   where id = b.id
  returning * into b;

  insert into booking.booking_events (booking_id, event_type, from_status, to_status, actor, actor_user_id)
  values (b.id, 'status_changed', v_from, p_status, 'admin', v_uid);

  return booking.booking_json(b, v_tz);
end;
$$;

create function public.booking_admin_list_services()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform booking.require_admin();
  select coalesce(jsonb_agg(booking.service_json(sv) order by sv.sort_order, sv.name), '[]'::jsonb)
  into v_result
  from booking.services sv;
  return v_result;
end;
$$;

create function public.booking_admin_save_service(p_service jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_allowed text[] := array['id', 'name', 'description', 'durationMinutes', 'bufferAfterMinutes',
                            'priceCents', 'priceFrom', 'isActive', 'sortOrder'];
  v_key text;
  v_id uuid;
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

  if v_id is null then
    insert into booking.services (
      name, description, duration_minutes, buffer_after_minutes, price_cents, price_from, is_active, sort_order
    ) values (
      booking.j_required_text(p_service, 'name', 120),
      booking.j_text(p_service, 'description', 2000),
      booking.j_int(p_service, 'durationMinutes', 5, 720),
      coalesce(booking.j_int(p_service, 'bufferAfterMinutes', 0, 240), 0),
      booking.j_int(p_service, 'priceCents', 0, 100000000),
      coalesce(booking.j_bool(p_service, 'priceFrom'), false),
      coalesce(booking.j_bool(p_service, 'isActive'), true),
      coalesce(booking.j_int(p_service, 'sortOrder', -100000, 100000), 0)
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
                        then coalesce(booking.j_int(p_service, 'sortOrder', -100000, 100000), 0) else sort_order end
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

create function public.booking_admin_delete_service(p_service_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform booking.require_admin();
  if exists (select 1 from booking.bookings b where b.service_id = p_service_id) then
    perform booking.raise_error('CONFLICT', 'service_has_bookings');
  end if;
  delete from booking.services sv where sv.id = p_service_id;
  if not found then
    perform booking.raise_error('NOT_FOUND', 'service');
  end if;
  return jsonb_build_object('deleted', true);
end;
$$;

create function public.booking_admin_get_working_hours()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform booking.require_admin();
  select coalesce(jsonb_agg(
           jsonb_build_object('weekday', w.weekday, 'start', booking.hhmm(w.start_time), 'end', booking.hhmm(w.end_time))
           order by w.weekday, w.start_time), '[]'::jsonb)
  into v_result
  from booking.working_hours w;
  return v_result;
end;
$$;

create function public.booking_admin_set_working_hours(p_hours jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_item jsonb;
  v_weekday int;
  v_start time;
  v_end time;
begin
  perform booking.require_admin();
  if p_hours is null or jsonb_typeof(p_hours) <> 'array' or jsonb_array_length(p_hours) > 70 then
    perform booking.raise_error('INVALID_INPUT', 'hours');
  end if;

  delete from booking.working_hours w where w.id is not null;

  for v_item in select value from jsonb_array_elements(p_hours) loop
    if jsonb_typeof(v_item) <> 'object' then
      perform booking.raise_error('INVALID_INPUT', 'hours');
    end if;
    v_weekday := booking.j_int(v_item, 'weekday', 1, 7);
    v_start := booking.j_time(v_item, 'start', false);
    v_end := booking.j_time(v_item, 'end', true);
    if v_weekday is null or v_start is null or v_end is null then
      perform booking.raise_error('INVALID_INPUT', 'hours');
    end if;
    if v_start >= v_end then
      perform booking.raise_error('INVALID_INPUT', 'hours.order');
    end if;
    insert into booking.working_hours (weekday, start_time, end_time) values (v_weekday, v_start, v_end);
  end loop;

  return public.booking_admin_get_working_hours();
exception
  when exclusion_violation then
    perform booking.raise_error('INVALID_INPUT', 'hours.overlap');
    return null;
end;
$$;

create function public.booking_admin_list_exceptions()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform booking.require_admin();
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', e.id,
             'kind', 'closed',
             'startsOn', to_char(e.starts_on, 'YYYY-MM-DD'),
             'endsOn', to_char(e.ends_on, 'YYYY-MM-DD'),
             'startTime', case when e.start_time is null then null else booking.hhmm(e.start_time) end,
             'endTime', case when e.end_time is null then null else booking.hhmm(e.end_time) end,
             'reason', e.reason
           ) order by e.starts_on, e.start_time nulls first), '[]'::jsonb)
  into v_result
  from booking.availability_exceptions e;
  return v_result;
end;
$$;

create function public.booking_admin_add_exception(p_exception jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_allowed text[] := array['startsOn', 'endsOn', 'startTime', 'endTime', 'reason'];
  v_key text;
  v_starts date;
  v_ends date;
  v_start_time time;
  v_end_time time;
  v_id uuid;
begin
  perform booking.require_admin();
  if p_exception is null or jsonb_typeof(p_exception) <> 'object' then
    perform booking.raise_error('INVALID_INPUT', 'exception');
  end if;
  for v_key in select jsonb_object_keys(p_exception) loop
    if not (v_key = any (v_allowed)) then
      perform booking.raise_error('INVALID_INPUT', v_key);
    end if;
  end loop;

  v_starts := booking.j_date(p_exception, 'startsOn');
  v_ends := coalesce(booking.j_date(p_exception, 'endsOn'), v_starts);
  v_start_time := booking.j_time(p_exception, 'startTime', false);
  v_end_time := booking.j_time(p_exception, 'endTime', true);
  if v_starts is null then
    perform booking.raise_error('INVALID_INPUT', 'startsOn');
  end if;
  if v_ends < v_starts or v_ends - v_starts > 366 then
    perform booking.raise_error('INVALID_INPUT', 'endsOn');
  end if;
  if (v_start_time is null) <> (v_end_time is null) or (v_start_time is not null and v_start_time >= v_end_time) then
    perform booking.raise_error('INVALID_INPUT', 'startTime');
  end if;

  insert into booking.availability_exceptions (starts_on, ends_on, start_time, end_time, reason)
  values (v_starts, v_ends, v_start_time, v_end_time, booking.j_text(p_exception, 'reason', 200))
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end;
$$;

create function public.booking_admin_delete_exception(p_exception_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform booking.require_admin();
  delete from booking.availability_exceptions e where e.id = p_exception_id;
  if not found then
    perform booking.raise_error('NOT_FOUND', 'exception');
  end if;
  return jsonb_build_object('deleted', true);
end;
$$;

create function public.booking_admin_get_settings()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  perform booking.require_admin();
  return booking.settings_json();
end;
$$;

create function public.booking_admin_update_settings(p_settings jsonb)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_allowed text[] := array['businessName', 'timezone', 'currency', 'locale', 'publicEmail', 'publicPhone',
                            'address', 'slotIntervalMinutes', 'minNoticeMinutes', 'maxAdvanceDays',
                            'autoConfirm', 'requirePhone', 'maxActiveBookingsPerEmail'];
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
      else max_active_bookings_per_email end
  where id;

  return booking.settings_json();
end;
$$;

create function public.booking_admin_apply_preset(p_preset jsonb)
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
  if p_preset is null or jsonb_typeof(p_preset) <> 'object'
     or jsonb_typeof(p_preset -> 'services') <> 'array'
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
-- Privileges — explicit, least privilege
-- ----------------------------------------------------------------------------

revoke all on all tables in schema booking from public, anon, authenticated, service_role;
revoke all on all sequences in schema booking from public, anon, authenticated, service_role;
revoke all on all functions in schema booking from public, anon, authenticated, service_role;
revoke all on schema booking from public;

grant usage on schema booking to anon, authenticated;

-- Public data (row access further limited by RLS).
grant select on booking.engine_info to anon, authenticated;
grant select (id, business_name, timezone, currency, locale, public_email, public_phone, address,
              slot_interval_minutes, min_notice_minutes, max_advance_days, auto_confirm, require_phone)
  on booking.settings to anon;
grant select on booking.services to anon;
grant select on booking.working_hours to anon;

-- Signed-in users. Every row is still behind RLS: admins pass, others do not.
grant select, update on booking.settings to authenticated;
grant select on booking.resources to authenticated;
grant select, insert, update, delete on booking.services to authenticated;
grant select, insert, update, delete on booking.working_hours to authenticated;
grant select, insert, update, delete on booking.availability_exceptions to authenticated;
grant select, insert, update on booking.bookings to authenticated;
grant select, insert on booking.booking_events to authenticated;
grant select on booking.admins to authenticated;

-- Helpers used inside SECURITY INVOKER admin functions.
grant execute on function
  booking.raise_error(text, text),
  booking.is_admin(),
  booking.require_admin(),
  booking.iso(timestamptz),
  booking.hhmm(time),
  booking.j_text(jsonb, text, int),
  booking.j_required_text(jsonb, text, int),
  booking.j_int(jsonb, text, int, int),
  booking.j_bool(jsonb, text),
  booking.j_time(jsonb, text, boolean),
  booking.j_date(jsonb, text),
  booking.booking_json(booking.bookings, text),
  booking.service_json(booking.services),
  booking.settings_json()
to authenticated;
-- booking.hhmm is used by the anon-callable booking_get_business().
grant execute on function booking.hhmm(time) to anon;

-- API functions: revoke the PostgreSQL default (PUBLIC) and Supabase's default
-- grants (anon, authenticated, service_role in schema public) — by exact
-- signature, so a project's own functions are never touched — then grant on
-- purpose.
revoke all on function
  public.booking_engine_info(),
  public.booking_get_business(),
  public.booking_list_services(),
  public.booking_get_availability(uuid, date, date),
  public.booking_create(uuid, timestamptz, text, text, text, text),
  public.booking_admin_whoami(),
  public.booking_admin_list_bookings(date, date, text[]),
  public.booking_admin_set_booking_status(uuid, text),
  public.booking_admin_list_services(),
  public.booking_admin_save_service(jsonb),
  public.booking_admin_delete_service(uuid),
  public.booking_admin_get_working_hours(),
  public.booking_admin_set_working_hours(jsonb),
  public.booking_admin_list_exceptions(),
  public.booking_admin_add_exception(jsonb),
  public.booking_admin_delete_exception(uuid),
  public.booking_admin_get_settings(),
  public.booking_admin_update_settings(jsonb),
  public.booking_admin_apply_preset(jsonb)
from public, anon, authenticated, service_role;

grant execute on function
  public.booking_engine_info(),
  public.booking_get_business(),
  public.booking_list_services(),
  public.booking_get_availability(uuid, date, date),
  public.booking_create(uuid, timestamptz, text, text, text, text)
to anon, authenticated, service_role;

grant execute on function
  public.booking_admin_whoami(),
  public.booking_admin_list_bookings(date, date, text[]),
  public.booking_admin_set_booking_status(uuid, text),
  public.booking_admin_list_services(),
  public.booking_admin_save_service(jsonb),
  public.booking_admin_delete_service(uuid),
  public.booking_admin_get_working_hours(),
  public.booking_admin_set_working_hours(jsonb),
  public.booking_admin_list_exceptions(),
  public.booking_admin_add_exception(jsonb),
  public.booking_admin_delete_exception(uuid),
  public.booking_admin_get_settings(),
  public.booking_admin_update_settings(jsonb),
  public.booking_admin_apply_preset(jsonb)
to authenticated;

insert into booking.engine_info (schema_version) values ('2.0.0-alpha.1');
