-- ============================================================================
-- Profit Studio Booking Engine — migration 0003_private_definers_and_holds
-- Engine schema version: 2.0.0-alpha.3
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- 1. No SECURITY DEFINER function remains in an API-exposed schema (Supabase
--    lints 0028/0029 inspect the exposed schemas). The two privileged
--    operations move to the private schema `booking`:
--      booking.get_availability   booking.create_booking
--    public.booking_get_availability and public.booking_create become thin
--    SECURITY INVOKER wrappers with unchanged signatures and results.
-- 2. Booking holds. A website request is `pending` and holds its time only
--    until `hold_expires_at` (owner setting `pending_hold_minutes`, default
--    24 h, never past the appointment start). A lapsed hold stops blocking
--    availability and is released (status `expired`) inside the same
--    transaction as an overlapping new booking. The owner can still confirm
--    an expired request if its time is free.
-- 3. Instant confirmation is disabled until email verification exists, so an
--    anonymous, unverified request can never occupy the calendar permanently.
-- 4. public.booking_admin_request_diagnostics(): admin-only view of the
--    request headers that identify the caller (verifies rate limiting on a
--    real host).
-- 5. Explicit deny-all policies on the two definer-only tables.
--
-- Existing data is preserved. Pending requests get a fresh hold window from
-- the time of the upgrade; auto_confirm is switched off (see CHANGELOG).
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.2' then
    raise exception 'Booking Engine 0003_private_definers_and_holds expects schema 2.0.0-alpha.2, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Schema (additive; one widened check, one new invariant)
-- ----------------------------------------------------------------------------

alter table booking.settings
  add column pending_hold_minutes int not null default 1440
    check (pending_hold_minutes between 15 and 10080);
comment on column booking.settings.pending_hold_minutes is
  'How long a new website request holds its time before it becomes available to others again.';

update booking.settings set auto_confirm = false where id and auto_confirm;
alter table booking.settings
  add constraint settings_instant_confirmation_requires_verification check (not auto_confirm);
comment on constraint settings_instant_confirmation_requires_verification on booking.settings is
  'Instant confirmation stays off until booking requests are verified (email module): unverified requests must not occupy the calendar permanently.';

alter table booking.bookings add column hold_expires_at timestamptz;
comment on column booking.bookings.hold_expires_at is
  'A pending website request blocks its time only until this moment. NULL for confirmed and admin bookings.';
alter table booking.bookings drop constraint bookings_status_check;
alter table booking.bookings add constraint bookings_status_check
  check (status in ('pending', 'confirmed', 'completed', 'cancelled', 'no_show', 'expired'));
update booking.bookings b
   set hold_expires_at = least(now() + interval '1440 minutes', b.starts_at)
 where b.status = 'pending';
alter table booking.bookings add constraint bookings_hold_only_for_requests
  check (hold_expires_at is null or status in ('pending', 'expired'));
create index bookings_pending_holds on booking.bookings (hold_expires_at) where status = 'pending';

-- ----------------------------------------------------------------------------
-- Holds
-- ----------------------------------------------------------------------------

-- What a booking's status means right now: a pending request whose hold has
-- lapsed is "expired" even before the row is updated.
create function booking.effective_status(p_status text, p_hold_expires_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_status = 'pending' and p_hold_expires_at is not null and p_hold_expires_at <= now() then 'expired'
    else p_status
  end;
$$;

-- Same algorithm as before; a pending request blocks its time only while its
-- hold is live (judged at p_now).
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
        and (b.status = 'confirmed' or b.hold_expires_at is null or b.hold_expires_at > p_now)
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
-- The two privileged operations — private schema, not reachable by URL
-- ----------------------------------------------------------------------------

create function booking.get_availability(p_service_id uuid, p_from date, p_to date default null)
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
comment on function booking.get_availability(uuid, date, date) is
  'PRIVILEGED (SECURITY DEFINER), private schema: reads existing bookings to compute free slots and returns times only. Reached through public.booking_get_availability.';

create function booking.create_booking(
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
  v_blocked_until timestamptz;
  v_hold_expires_at timestamptz;
  v_client text;
  v_bucket text;
  v_limit int;
  v_count int;
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

  -- 3. The start must be a slot the engine offers right now (lapsed holds
  --    do not count as taken).
  v_local_day := (p_starts_at at time zone v_settings.timezone)::date;
  if not exists (
    select 1
    from booking.compute_slots(p_service_id, v_local_day, v_local_day, now(), v_resource_id) as cs
    where cs.starts_at = p_starts_at
  ) then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  -- 4. Abuse limits — after the slot check, without saying which limit was
  --    hit, serialised per email and per client. Lock order: email, client.
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:email:' || v_email, 0));
  select count(*) into v_count
  from booking.bookings b
  where lower(b.customer_email) = v_email
    and b.status in ('pending', 'confirmed')
    and (b.status = 'confirmed' or b.hold_expires_at is null or b.hold_expires_at > now())
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

  -- 5. Release lapsed holds that overlap this time, in this transaction, so
  --    the exclusion constraint only sees live holds and confirmed bookings.
  v_blocked_until := p_starts_at + make_interval(mins => v_service.duration_minutes + v_service.buffer_after_minutes);
  with lapsed as (
    update booking.bookings b
       set status = 'expired', status_changed_at = now()
     where b.status = 'pending'
       and b.hold_expires_at is not null
       and b.hold_expires_at <= now()
       and b.resource_id = v_resource_id
       and tstzrange(b.starts_at, b.blocked_until, '[)') && tstzrange(p_starts_at, v_blocked_until, '[)')
    returning b.id
  )
  insert into booking.booking_events (booking_id, event_type, from_status, to_status, actor)
  select l.id, 'status_changed', 'pending', 'expired', 'system' from lapsed l;

  -- 6. Insert a request that holds its time for the owner's hold window.
  v_hold_expires_at := least(now() + make_interval(mins => v_settings.pending_hold_minutes), p_starts_at);
  loop
    v_attempt := v_attempt + 1;
    begin
      insert into booking.bookings (
        reference, service_id, resource_id, starts_at, ends_at, blocked_until, status, hold_expires_at,
        customer_name, customer_email, customer_phone, customer_notes,
        service_name, price_cents, currency, source
      ) values (
        booking.new_reference(), v_service.id, v_resource_id, p_starts_at,
        p_starts_at + make_interval(mins => v_service.duration_minutes),
        v_blocked_until, 'pending', v_hold_expires_at,
        v_name, v_email, v_phone, v_notes,
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
    'timezone', v_settings.timezone,
    'holdExpiresAt', booking.iso(v_booking.hold_expires_at)
  );
end;
$$;
comment on function booking.create_booking(uuid, timestamptz, text, text, text, text) is
  'PRIVILEGED (SECURITY DEFINER), private schema: the only way to create a booking. Validates input, re-checks the slot, applies abuse limits, releases lapsed holds and relies on the exclusion constraint under concurrency. Reached through public.booking_create.';

-- ----------------------------------------------------------------------------
-- Public API: thin SECURITY INVOKER wrappers (same signatures, same results)
-- ----------------------------------------------------------------------------

create or replace function public.booking_get_availability(p_service_id uuid, p_from date, p_to date default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select booking.get_availability(p_service_id, p_from, p_to);
$$;
comment on function public.booking_get_availability(uuid, date, date) is
  'Public. Free slots for one service over business-local dates (at most 42 days). Times only, never people.';

create or replace function public.booking_create(
  p_service_id uuid,
  p_starts_at timestamptz,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text default null,
  p_notes text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select booking.create_booking(p_service_id, p_starts_at, p_customer_name, p_customer_email, p_customer_phone, p_notes);
$$;
comment on function public.booking_create(uuid, timestamptz, text, text, text, text) is
  'Public. Creates a booking request that holds its time for the owner''s hold window.';

create or replace function public.booking_get_business()
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
      'requirePhone', s.require_phone,
      'pendingHoldMinutes', s.pending_hold_minutes
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

-- ----------------------------------------------------------------------------
-- Admin API
-- ----------------------------------------------------------------------------

create or replace function booking.booking_json(b booking.bookings, p_tz text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', b.id,
    'reference', b.reference,
    'status', booking.effective_status(b.status, b.hold_expires_at),
    'holdExpiresAt', booking.iso(b.hold_expires_at),
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
       where st.v is null or st.v not in ('pending', 'confirmed', 'completed', 'cancelled', 'no_show', 'expired')) then
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
      and (p_statuses is null or booking.effective_status(b2.status, b2.hold_expires_at) = any (p_statuses))
    order by b2.starts_at
    limit 1000
  );
  return v_result;
end;
$$;

create or replace function public.booking_admin_set_booking_status(p_booking_id uuid, p_status text)
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

  v_from := booking.effective_status(b.status, b.hold_expires_at);
  if v_from = p_status then
    return booking.booking_json(b, v_tz);
  end if;
  if not (
    (v_from in ('pending', 'expired') and p_status in ('confirmed', 'cancelled'))
    or (v_from = 'confirmed' and p_status in ('cancelled', 'completed', 'no_show'))
  ) then
    perform booking.raise_error('INVALID_TRANSITION', v_from || '->' || p_status);
  end if;
  if p_status in ('completed', 'no_show') and b.starts_at > now() then
    perform booking.raise_error('INVALID_TRANSITION', 'not_started');
  end if;

  begin
    update booking.bookings
       set status = p_status, hold_expires_at = null, status_changed_at = now()
     where id = b.id
    returning * into b;
  exception
    when exclusion_violation then
      -- An expired request's time was booked by someone else meanwhile.
      perform booking.raise_error('CONFLICT', 'slot_taken');
  end;

  insert into booking.booking_events (booking_id, event_type, from_status, to_status, actor, actor_user_id)
  values (b.id, 'status_changed', v_from, p_status, 'admin', v_uid);

  return booking.booking_json(b, v_tz);
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
    'pendingHoldMinutes', s.pending_hold_minutes,
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
                            'autoConfirm', 'requirePhone', 'maxActiveBookingsPerEmail',
                            'maxWebsiteBookingsPerHour', 'pendingHoldMinutes'];
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
  if coalesce(booking.j_bool(p_settings, 'autoConfirm'), false) then
    -- Instant confirmation needs verified requests (email module).
    perform booking.raise_error('INVALID_INPUT', 'autoConfirm');
  end if;

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
    require_phone = case when p_settings ? 'requirePhone'
      then coalesce(booking.j_bool(p_settings, 'requirePhone'), require_phone) else require_phone end,
    max_active_bookings_per_email = case when p_settings ? 'maxActiveBookingsPerEmail'
      then coalesce(booking.j_int(p_settings, 'maxActiveBookingsPerEmail', 1, 50), max_active_bookings_per_email)
      else max_active_bookings_per_email end,
    max_website_bookings_per_hour = case when p_settings ? 'maxWebsiteBookingsPerHour'
      then coalesce(booking.j_int(p_settings, 'maxWebsiteBookingsPerHour', 1, 1000), max_website_bookings_per_hour)
      else max_website_bookings_per_hour end,
    pending_hold_minutes = case when p_settings ? 'pendingHoldMinutes'
      then coalesce(booking.j_int(p_settings, 'pendingHoldMinutes', 15, 10080), pending_hold_minutes)
      else pending_hold_minutes end
  where id;

  return booking.settings_json();
end;
$$;

create function public.booking_admin_request_diagnostics()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  h jsonb;
begin
  perform booking.require_admin();
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    h := null;
  end;
  return jsonb_build_object(
    'headerNames', coalesce((
      select jsonb_agg(k.name order by k.name)
      from jsonb_object_keys(coalesce(h, '{}'::jsonb)) as k(name)
      where k.name not in ('authorization', 'apikey', 'cookie')
    ), '[]'::jsonb),
    'cfConnectingIp', h ->> 'cf-connecting-ip',
    'xRealIp', h ->> 'x-real-ip',
    'xForwardedFor', h ->> 'x-forwarded-for',
    'clientKey', booking.client_key()
  );
end;
$$;
comment on function public.booking_admin_request_diagnostics() is
  'Admin only. The caller-identifying request headers as the database sees them (never credentials), to verify rate limiting on a real host.';

-- ----------------------------------------------------------------------------
-- Explicit deny-all policies on definer-only tables (intent, and Supabase lint 0008)
-- ----------------------------------------------------------------------------

create policy request_log_no_api_access on booking.request_log
  for all to anon, authenticated using (false) with check (false);
create policy engine_secrets_no_api_access on booking.engine_secrets
  for all to anon, authenticated using (false) with check (false);

-- ----------------------------------------------------------------------------
-- Privileges
-- ----------------------------------------------------------------------------

revoke all on function
  booking.get_availability(uuid, date, date),
  booking.create_booking(uuid, timestamptz, text, text, text, text),
  booking.effective_status(text, timestamptz),
  public.booking_admin_request_diagnostics()
from public, anon, authenticated, service_role;

-- The private privileged functions are executable by the API roles but not
-- reachable by URL (schema `booking` is not exposed); the public wrappers are
-- the only entry points.
grant execute on function
  booking.get_availability(uuid, date, date),
  booking.create_booking(uuid, timestamptz, text, text, text, text)
to anon, authenticated, service_role;

grant execute on function booking.effective_status(text, timestamptz) to authenticated;
-- The diagnostics read only the caller's own request headers.
grant execute on function booking.client_ip(), booking.client_key() to authenticated;
grant execute on function public.booking_admin_request_diagnostics() to authenticated;

grant select (pending_hold_minutes) on booking.settings to anon, service_role;

update booking.engine_info set schema_version = '2.0.0-alpha.3', updated_at = now() where id;
