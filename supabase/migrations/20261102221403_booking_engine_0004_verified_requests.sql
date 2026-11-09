-- ============================================================================
-- Profit Studio Booking Engine — migration 0004_verified_requests
-- Engine schema version: 2.0.0-alpha.4
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Verified booking requests and essential emails
-- (docs/adr/0002-verified-booking-requests.md):
--
--   * booking_request  — validates and rate-limits, holds the time as an
--     `unverified` booking for the verification window only (default 15 min)
--     and queues a 6-digit one-time code email (only a salted hash is stored;
--     5 attempts; at most 3 re-sends).
--   * booking_verify   — proves email ownership, rechecks the time, applies the
--     per-email booking cap and turns the hold into `pending` (owner approval)
--     or `confirmed` (instant confirmation). Idempotent.
--   * booking_cancel_request — the visitor releases their own unverified hold
--     (the request id they were given is the capability).
--   * Unverified requests are invisible to the owner and deleted when they lapse.
--   * Every email is a row in a transactional outbox (written in the same
--     transaction as the change that causes it, once per de-duplication key),
--     sent by the `booking-mailer` Edge Function. The database starts the
--     function itself (pg_net + Vault, when configured) and a pg_cron job
--     runs maintenance and retries; the website never calls the mailer.
--   * Online booking stays off until a test email has been delivered.
--   * booking_create is closed: it raises VERIFICATION_REQUIRED.
--
-- Existing data is preserved. Online booking is OFF after the upgrade until
-- email sending is set up (see CHANGELOG).
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.3' then
    raise exception 'Booking Engine 0004_verified_requests expects schema 2.0.0-alpha.3, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Schema
-- ----------------------------------------------------------------------------

alter table booking.bookings drop constraint bookings_status_check;
alter table booking.bookings add constraint bookings_status_check
  check (status in ('unverified', 'pending', 'confirmed', 'completed', 'cancelled', 'no_show', 'expired'));
alter table booking.bookings drop constraint bookings_hold_only_for_requests;
alter table booking.bookings add constraint bookings_hold_only_for_requests
  check (hold_expires_at is null or status in ('unverified', 'pending', 'expired'));
alter table booking.bookings add constraint bookings_unverified_is_held
  check (status <> 'unverified' or hold_expires_at is not null);
alter table booking.bookings drop constraint bookings_no_overlap;
alter table booking.bookings add constraint bookings_no_overlap exclude using gist (
  resource_id with =,
  tstzrange(starts_at, blocked_until, '[)') with &&
) where (status in ('unverified', 'pending', 'confirmed'));
comment on constraint bookings_no_overlap on booking.bookings is
  'The double-booking guarantee: verification holds, requests and confirmed bookings never overlap on one resource, including buffer time. Holds under concurrent requests.';
alter table booking.bookings add column email_verified_at timestamptz;
comment on column booking.bookings.email_verified_at is
  'When the customer proved they control customer_email. NULL for bookings made before verification existed (2.0.0-alpha.3 and earlier) and for admin bookings.';
create index bookings_unverified_holds on booking.bookings (hold_expires_at) where status = 'unverified';

alter table booking.settings drop constraint settings_instant_confirmation_requires_verification;
alter table booking.settings
  add column owner_notification_email text
    check (owner_notification_email is null or char_length(owner_notification_email) <= 254),
  add column verification_window_minutes int not null default 15
    check (verification_window_minutes between 5 and 30),
  add column max_verification_emails_per_day int not null default 50
    check (max_verification_emails_per_day between 1 and 5000),
  add column online_booking_enabled boolean not null default false;
comment on column booking.settings.owner_notification_email is
  'Where new-request alerts go. When empty, the public business email is used.';
comment on column booking.settings.verification_window_minutes is
  'How long a customer has to enter their code. The time is held for them meanwhile.';
comment on column booking.settings.max_verification_emails_per_day is
  'Site-wide ceiling on code emails per 24 hours (cost and abuse control). The default fits Resend''s free plan.';
comment on column booking.settings.online_booking_enabled is
  'Website booking accepts requests only when on. It can be switched on once a test email has been delivered.';

create table booking.verifications (
  id uuid primary key,
  booking_id uuid unique references booking.bookings (id) on delete set null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0 check (attempts >= 0),
  sends int not null default 1 check (sends >= 1),
  last_sent_at timestamptz not null default now(),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table booking.verifications is
  'One-time codes for booking requests (the request id is this row''s id). Only salted SHA-256 hashes are stored. Rows are deleted after a day.';

create table booking.email_outbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in (
    'verification_code', 'request_received', 'booking_confirmed', 'booking_declined',
    'booking_cancelled', 'request_expired', 'owner_new_request', 'test')),
  recipient text not null check (char_length(recipient) between 3 and 254),
  booking_id uuid references booking.bookings (id) on delete set null,
  payload jsonb not null,
  dedupe_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'cancelled')),
  attempts int not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default clock_timestamp(), -- keeps emails of one transaction in order
  sent_at timestamptz
);
create index email_outbox_due on booking.email_outbox (next_attempt_at) where status in ('pending', 'sending');
create index email_outbox_kind_created on booking.email_outbox (kind, created_at);
create index email_outbox_recipient_created on booking.email_outbox (recipient, created_at);
create index email_outbox_booking on booking.email_outbox (booking_id);
comment on table booking.email_outbox is
  'Transactional outbox: each email is written in the same transaction as the change that causes it, once per dedupe_key, and sent by the booking-mailer Edge Function. Codes are removed once sent or no longer usable. Code emails are kept 2 days, others 30 days.';

create table booking.mailer_state (
  id boolean primary key default true check (id),
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text
);
insert into booking.mailer_state default values;
comment on table booking.mailer_state is 'Health of email sending, shown in the dashboard. last_success_at unlocks online booking.';

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

create or replace function booking.effective_status(p_status text, p_hold_expires_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_status in ('unverified', 'pending') and p_hold_expires_at is not null and p_hold_expires_at <= now() then 'expired'
    else p_status
  end;
$$;

create function booking.mask_email(p_email text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_email is null or position('@' in p_email) < 2 then '***'
    else left(p_email, 1) || '***' || substr(p_email, position('@' in p_email))
  end;
$$;

-- Six digits from the CSPRNG behind gen_random_uuid() (modulo bias < 0.03 %).
create function booking.new_code()
returns text
language sql
volatile
set search_path = ''
as $$
  select lpad(((((get_byte(r.b, 0)::bigint << 24) | (get_byte(r.b, 1) << 16) | (get_byte(r.b, 2) << 8) | get_byte(r.b, 3))
               % 1000000))::text, 6, '0')
  from (select uuid_send(gen_random_uuid()) as b) as r;
$$;

create function booking.code_hash(p_verification_id uuid, p_code text)
returns text
language sql
stable
set search_path = ''
as $$
  select encode(sha256(convert_to(
    (select es.hash_salt from booking.engine_secrets es where es.id) || ':' || p_verification_id::text || ':' || p_code,
    'UTF8')), 'hex');
$$;

-- What a customer is shown about their own booking (BookingConfirmation).
create function booking.public_booking_json(b booking.bookings)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'reference', b.reference,
    'status', booking.effective_status(b.status, b.hold_expires_at),
    'startsAt', booking.iso(b.starts_at),
    'endsAt', booking.iso(b.ends_at),
    'date', to_char(b.starts_at at time zone s.timezone, 'YYYY-MM-DD'),
    'time', to_char(b.starts_at at time zone s.timezone, 'HH24:MI'),
    'serviceName', b.service_name,
    'timezone', s.timezone,
    'holdExpiresAt', case when b.status = 'pending' then booking.iso(b.hold_expires_at) end
  )
  from booking.settings s
  where s.id;
$$;

-- Everything an email about one booking needs, captured when it is queued.
create function booking.booking_email_payload(b booking.bookings, p_include_contact boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'businessName', s.business_name,
    'businessEmail', s.public_email,
    'businessPhone', s.public_phone,
    'address', s.address,
    'timezone', s.timezone,
    'locale', s.locale,
    'currency', b.currency,
    'reference', b.reference,
    'serviceName', b.service_name,
    'startsAt', booking.iso(b.starts_at),
    'endsAt', booking.iso(b.ends_at),
    'priceCents', b.price_cents,
    'status', b.status,
    'holdExpiresAt', case when b.status = 'pending' then booking.iso(b.hold_expires_at) end,
    'customerName', b.customer_name,
    'customerEmail', case when p_include_contact then b.customer_email end,
    'customerPhone', case when p_include_contact then b.customer_phone end,
    'notes', case when p_include_contact then b.customer_notes end
  ))
  from booking.settings s
  where s.id;
$$;

-- Queue one email, at most once per de-duplication key. No recipient, no email.
create function booking.enqueue_email(p_kind text, p_recipient text, p_booking_id uuid, p_payload jsonb, p_dedupe_key text)
returns boolean
language plpgsql
volatile
set search_path = ''
as $$
begin
  if p_recipient is null or btrim(p_recipient) = '' then
    return false;
  end if;
  insert into booking.email_outbox (kind, recipient, booking_id, payload, dedupe_key)
  values (p_kind, lower(btrim(p_recipient)), p_booking_id, p_payload, p_dedupe_key)
  on conflict (dedupe_key) do nothing;
  return found;
end;
$$;

-- Ask the booking-mailer Edge Function to run now (at most once per
-- transaction; pg_net sends the request after commit). A no-op until pg_net
-- and the two Vault secrets exist; the scheduled job also starts it. It runs
-- inside the transaction that queued an email (a booking request, a status
-- change), so it never raises: a wiring problem must not block a booking —
-- the email stays queued for the scheduled job and the dashboard shows it.
create function booking.kick_mailer()
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_key text;
begin
  if coalesce(current_setting('booking_engine.mailer_kicked', true), '') = 'on' then
    return false;
  end if;
  begin
    if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null
       or to_regclass('vault.decrypted_secrets') is null then
      return false;
    end if;
    execute 'select max(d.decrypted_secret) filter (where d.name = $1), max(d.decrypted_secret) filter (where d.name = $2)
             from vault.decrypted_secrets d where d.name in ($1, $2)'
      into v_url, v_key
      using 'booking_engine_mailer_url', 'booking_engine_mailer_key';
    if v_url is null or v_key is null then
      return false;
    end if;
    execute 'select net.http_post(url => $1, body => $2, params => $3, headers => $4, timeout_milliseconds => $5)'
      using v_url, '{}'::jsonb, '{}'::jsonb,
            jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key), 30000;
  exception when others then
    return false;
  end;
  perform set_config('booking_engine.mailer_kicked', 'on', true);
  return true;
end;
$$;
comment on function booking.kick_mailer() is
  'PRIVILEGED (SECURITY DEFINER), private schema. Starts the booking-mailer Edge Function through pg_net with the secret key kept in Vault (booking_engine_mailer_url, booking_engine_mailer_key).';

create function booking.email_outbox_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform booking.kick_mailer();
  return null;
end;
$$;
create trigger email_outbox_kick after insert on booking.email_outbox
  for each row execute function booking.email_outbox_after_insert();

-- Release lapsed holds without waiting on rows another transaction is working
-- on: lapsed verification holds are deleted (with their personal data);
-- lapsed requests become `expired` and a verified customer is told once.
-- With a resource and range, only overlapping holds; without, all of them.
create function booking.expire_lapsed(
  p_resource_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  r booking.bookings%rowtype;
  n int;
begin
  with lapsed as (
    select b.id
    from booking.bookings b
    where b.status = 'unverified'
      and b.hold_expires_at <= now()
      and (p_resource_id is null or (b.resource_id = p_resource_id
           and tstzrange(b.starts_at, b.blocked_until, '[)') && tstzrange(p_from, p_to, '[)')))
    for update skip locked
  )
  delete from booking.bookings b using lapsed l where b.id = l.id;
  get diagnostics n = row_count;

  for r in
    with lapsed as (
      select b.id
      from booking.bookings b
      where b.status = 'pending'
        and b.hold_expires_at is not null
        and b.hold_expires_at <= now()
        and (p_resource_id is null or (b.resource_id = p_resource_id
             and tstzrange(b.starts_at, b.blocked_until, '[)') && tstzrange(p_from, p_to, '[)')))
      for update skip locked
    )
    update booking.bookings b
       set status = 'expired', status_changed_at = now()
      from lapsed l
     where b.id = l.id
    returning b.*
  loop
    insert into booking.booking_events (booking_id, event_type, from_status, to_status, actor)
    values (r.id, 'status_changed', 'pending', 'expired', 'system');
    if r.email_verified_at is not null then
      perform booking.enqueue_email('request_expired', r.customer_email, r.id,
        booking.booking_email_payload(r, false), 'request_expired:' || r.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Availability: verification holds block like requests while their hold is
-- live. p_ignore_booking_id leaves one booking out (rechecking its own time).
drop function booking.compute_slots(uuid, date, date, timestamptz, uuid);
create function booking.compute_slots(
  p_service_id uuid,
  p_from date,
  p_to date,
  p_now timestamptz,
  p_resource_id uuid default null,
  p_ignore_booking_id uuid default null
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
        and b.status in ('unverified', 'pending', 'confirmed')
        and (b.status = 'confirmed' or b.hold_expires_at is null or b.hold_expires_at > p_now)
        and (p_ignore_booking_id is null or b.id <> p_ignore_booking_id)
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

-- Housekeeping for the mailer and the scheduled job: release lapsed holds,
-- withdraw code emails that can no longer be used, give up on emails whose
-- sending keeps being interrupted, apply retention.
create function booking.run_maintenance()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_released int;
  v_withdrawn int;
begin
  v_released := booking.expire_lapsed();

  update booking.email_outbox o
     set status = 'cancelled', payload = o.payload - 'code', locked_until = null
   where o.kind = 'verification_code'
     and o.status in ('pending', 'sending')
     and (o.locked_until is null or o.locked_until <= now())
     and ((o.payload ->> 'expiresAt')::timestamptz <= now()
          or not exists (select 1 from booking.bookings b where b.id = o.booking_id and b.status = 'unverified'));
  get diagnostics v_withdrawn = row_count;

  update booking.email_outbox o
     set status = 'failed', locked_until = null,
         payload = case when o.kind = 'verification_code' then o.payload - 'code' else o.payload end,
         last_error = coalesce(o.last_error, 'Sending was interrupted repeatedly')
   where o.status = 'sending' and o.locked_until <= now() and o.attempts >= 5;

  delete from booking.email_outbox o
   where o.status in ('sent', 'failed', 'cancelled')
     and o.created_at < now() - case when o.kind = 'verification_code' then interval '2 days' else interval '30 days' end;
  delete from booking.verifications v where v.created_at < now() - interval '1 day';

  return jsonb_build_object('released', v_released, 'withdrawn', v_withdrawn);
end;
$$;
comment on function booking.run_maintenance() is
  'PRIVILEGED (SECURITY DEFINER), private schema. Releases lapsed holds and keeps the outbox tidy. Used by booking_mailer_claim and booking.mailer_tick.';

-- The scheduled job (pg_cron, every minute): maintenance, then start the
-- mailer only when an email is due.
create function booking.mailer_tick()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v jsonb;
  v_kicked boolean := false;
begin
  v := booking.run_maintenance();
  if exists (
    select 1 from booking.email_outbox o
    where o.status in ('pending', 'sending') and o.next_attempt_at <= now()
      and (o.locked_until is null or o.locked_until <= now())
  ) then
    v_kicked := booking.kick_mailer();
  end if;
  return v || jsonb_build_object('kicked', v_kicked);
end;
$$;
comment on function booking.mailer_tick() is
  'Run every minute by pg_cron (see `booking-engine mailer-sql`): maintenance, then starts booking-mailer if an email is due.';

-- Whether the automatic sending is wired up (booleans only; never values).
create function booking.mailer_wiring()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_url boolean := false;
  v_key boolean := false;
  v_schedule boolean := false;
  v_net boolean := false;
begin
  -- Optional extensions: missing or unreadable means "not set up", never an error.
  begin
    if to_regclass('vault.secrets') is not null then
      execute 'select coalesce(bool_or(s.name = $1), false), coalesce(bool_or(s.name = $2), false)
               from vault.secrets s where s.name in ($1, $2)'
        into v_url, v_key
        using 'booking_engine_mailer_url', 'booking_engine_mailer_key';
    end if;
  exception when others then
    v_url := false;
    v_key := false;
  end;
  begin
    if to_regclass('cron.job') is not null then
      execute 'select exists (select 1 from cron.job j where j.jobname = $1 and j.active)'
        into v_schedule
        using 'booking-engine-mailer';
    end if;
  exception when others then
    v_schedule := false;
  end;
  begin
    v_net := to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null;
  exception when others then
    v_net := false;
  end;
  return jsonb_build_object('pgNet', v_net, 'mailerUrl', v_url, 'mailerKey', v_key, 'schedule', v_schedule);
end;
$$;

-- ----------------------------------------------------------------------------
-- Privileged booking operations (private schema, not reachable by URL)
-- ----------------------------------------------------------------------------

create function booking.request_booking(
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
  c_codes_per_address_per_hour constant int := 5;
  c_codes_per_address_per_day constant int := 10;
  v_settings booking.settings%rowtype;
  v_service booking.services%rowtype;
  v_resource_id uuid;
  v_name text := btrim(coalesce(p_customer_name, ''));
  v_email text := lower(btrim(coalesce(p_customer_email, '')));
  v_phone text := nullif(btrim(coalesce(p_customer_phone, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_local_day date;
  v_blocked_until timestamptz;
  v_hold timestamptz;
  v_client text;
  v_bucket text;
  v_limit int;
  v_hour int;
  v_day int;
  v_booking booking.bookings%rowtype;
  v_request_id uuid := gen_random_uuid();
  v_code text;
  v_attempt int := 0;
begin
  -- 1. The request itself (cheap, no table access).
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
  if not v_settings.online_booking_enabled then
    perform booking.raise_error('BOOKING_DISABLED');
  end if;
  if v_settings.require_phone and v_phone is null then
    perform booking.raise_error('INVALID_INPUT', 'customer.phone');
  end if;

  -- 2. Only times inside the booking window are worth checking.
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

  -- 3. Abuse and cost limits. They count code emails and requests, never
  --    bookings, so a refusal says nothing about anyone's appointments.
  --    Lock order everywhere: address, client, site, then rows.
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:email:' || v_email, 0));
  select count(*) filter (where o.created_at > now() - interval '1 hour'), count(*)
    into v_hour, v_day
  from booking.email_outbox o
  where o.recipient = v_email and o.kind = 'verification_code' and o.created_at > now() - interval '1 day';
  if v_hour >= c_codes_per_address_per_hour or v_day >= c_codes_per_address_per_day then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  v_client := booking.client_key();
  v_bucket := 'client:' || encode(sha256(convert_to(
    (select es.hash_salt from booking.engine_secrets es where es.id) || ':' || v_client, 'UTF8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:' || v_bucket, 0));
  v_limit := case when v_client = 'unknown' then v_settings.max_website_bookings_per_hour else c_client_limit_per_hour end;
  select count(*) into v_hour
  from booking.request_log r
  where r.bucket = v_bucket and r.created_at > now() - interval '1 hour';
  if v_hour >= v_limit then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('booking_engine:site', 0));
  select count(*) into v_hour
  from booking.request_log r
  where r.bucket = 'site' and r.created_at > now() - interval '1 hour';
  if v_hour >= v_settings.max_website_bookings_per_hour then
    perform booking.raise_error('RATE_LIMITED');
  end if;
  select count(*) into v_day
  from booking.email_outbox o
  where o.kind = 'verification_code' and o.created_at > now() - interval '1 day';
  if v_day >= v_settings.max_verification_emails_per_day then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  -- 4. One open verification per address: a new request replaces the last
  --    one (its time becomes free again, also for this customer).
  delete from booking.bookings b where b.status = 'unverified' and lower(b.customer_email) = v_email;

  -- 5. The start must be a slot the engine offers right now.
  v_local_day := (p_starts_at at time zone v_settings.timezone)::date;
  if not exists (
    select 1
    from booking.compute_slots(p_service_id, v_local_day, v_local_day, now(), v_resource_id) as cs
    where cs.starts_at = p_starts_at
  ) then
    perform booking.raise_error('SLOT_UNAVAILABLE');
  end if;

  -- 6. Release lapsed holds overlapping this time, then hold it briefly.
  v_blocked_until := p_starts_at + make_interval(mins => v_service.duration_minutes + v_service.buffer_after_minutes);
  perform booking.expire_lapsed(v_resource_id, p_starts_at, v_blocked_until);
  v_hold := least(now() + make_interval(mins => v_settings.verification_window_minutes), p_starts_at);
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
        v_blocked_until, 'unverified', v_hold,
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
  values (v_booking.id, 'created', 'unverified', 'customer');

  -- 7. The one-time code (stored only as a salted hash) and its email. The
  --    email carries no text the requester typed: it may reach someone who
  --    never asked for it.
  v_code := booking.new_code();
  insert into booking.verifications (id, booking_id, code_hash, expires_at)
  values (v_request_id, v_booking.id, booking.code_hash(v_request_id, v_code), v_hold);
  perform booking.enqueue_email('verification_code', v_email, v_booking.id,
    (booking.booking_email_payload(v_booking, false) - 'customerName' - 'status')
      || jsonb_build_object('code', v_code, 'expiresAt', booking.iso(v_hold),
                            'minutesValid', v_settings.verification_window_minutes),
    'verification_code:' || v_request_id || ':1');

  insert into booking.request_log (bucket) values (v_bucket), ('site');
  delete from booking.request_log r where r.created_at < now() - interval '1 day';

  return jsonb_build_object(
    'requestId', v_request_id,
    'expiresAt', booking.iso(v_hold),
    'email', booking.mask_email(v_email),
    'codeLength', 6,
    'resendAfterSeconds', 60,
    'resendsLeft', 3
  );
end;
$$;
comment on function booking.request_booking(uuid, timestamptz, text, text, text, text) is
  'PRIVILEGED (SECURITY DEFINER), private schema. Validates and rate-limits a booking request, holds its time only for the verification window and queues a one-time code email. Reached through public.booking_request.';

create function booking.verify_booking(p_request_id uuid, p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_max_attempts constant int := 5;
  v_code text := regexp_replace(coalesce(p_code, ''), '[[:space:]-]', '', 'g');
  v booking.verifications%rowtype;
  b booking.bookings%rowtype;
  v_settings booking.settings%rowtype;
  v_local_day date;
  v_count int;
  v_status text;
begin
  if p_request_id is null then
    perform booking.raise_error('INVALID_INPUT', 'requestId');
  end if;
  if v_code !~ '^[0-9]{6}$' then
    perform booking.raise_error('INVALID_INPUT', 'code');
  end if;

  -- Results are returned, not raised, so counted attempts are kept.
  select * into v from booking.verifications where id = p_request_id for update;
  if not found then
    return jsonb_build_object('result', 'expired');
  end if;
  select * into b from booking.bookings where id = v.booking_id for update;

  -- Already verified: the same code gives the same answer (retries, double clicks).
  if v.verified_at is not null then
    if b.id is not null and v.code_hash = booking.code_hash(v.id, v_code) then
      return jsonb_build_object('result', 'verified', 'booking', booking.public_booking_json(b));
    end if;
    return jsonb_build_object('result', 'invalid_code', 'attemptsLeft', 0);
  end if;

  if v.attempts >= c_max_attempts then
    if b.id is not null and b.status = 'unverified' then
      delete from booking.bookings where id = b.id;
    end if;
    return jsonb_build_object('result', 'locked');
  end if;

  if b.id is null or b.status <> 'unverified' or v.expires_at <= now() or b.hold_expires_at <= now() then
    if b.id is not null and b.status = 'unverified' then
      delete from booking.bookings where id = b.id;
    end if;
    return jsonb_build_object('result', 'expired');
  end if;

  if v.code_hash <> booking.code_hash(v.id, v_code) then
    update booking.verifications set attempts = attempts + 1 where id = v.id returning * into v;
    if v.attempts >= c_max_attempts then
      delete from booking.bookings where id = b.id;
      return jsonb_build_object('result', 'locked');
    end if;
    return jsonb_build_object('result', 'invalid_code', 'attemptsLeft', c_max_attempts - v.attempts);
  end if;

  -- The code is right. Recheck the time as it was offered when requested:
  -- the hold kept other customers out, but the owner may have closed it.
  select * into v_settings from booking.settings where id;
  v_local_day := (b.starts_at at time zone v_settings.timezone)::date;
  if b.starts_at <= now() or not exists (
    select 1
    from booking.compute_slots(b.service_id, v_local_day, v_local_day, b.created_at, b.resource_id, b.id) as cs
    where cs.starts_at = b.starts_at
  ) then
    delete from booking.bookings where id = b.id;
    return jsonb_build_object('result', 'slot_unavailable');
  end if;

  -- The per-address cap applies only now: the person asking owns the address.
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:verified:' || lower(b.customer_email), 0));
  select count(*) into v_count
  from booking.bookings x
  where lower(x.customer_email) = lower(b.customer_email)
    and x.id <> b.id
    and x.status in ('pending', 'confirmed')
    and (x.status = 'confirmed' or x.hold_expires_at is null or x.hold_expires_at > now())
    and x.starts_at > now();
  if v_count >= v_settings.max_active_bookings_per_email then
    delete from booking.bookings where id = b.id;
    return jsonb_build_object('result', 'too_many_bookings');
  end if;

  v_status := case when v_settings.auto_confirm then 'confirmed' else 'pending' end;
  update booking.bookings
     set status = v_status,
         email_verified_at = now(),
         status_changed_at = now(),
         hold_expires_at = case when v_status = 'pending'
                                then least(now() + make_interval(mins => v_settings.pending_hold_minutes), b.starts_at) end
   where id = b.id
  returning * into b;
  update booking.verifications set verified_at = now() where id = v.id;

  insert into booking.booking_events (booking_id, event_type, from_status, to_status, actor)
  values (b.id, 'status_changed', 'unverified', v_status, 'customer');

  perform booking.enqueue_email(
    case when v_status = 'confirmed' then 'booking_confirmed' else 'request_received' end,
    b.customer_email, b.id, booking.booking_email_payload(b, false),
    case when v_status = 'confirmed' then 'booking_confirmed:' else 'request_received:' end || b.id);
  perform booking.enqueue_email('owner_new_request',
    coalesce(v_settings.owner_notification_email, v_settings.public_email), b.id,
    booking.booking_email_payload(b, true), 'owner_new_request:' || b.id);

  return jsonb_build_object('result', 'verified', 'booking', booking.public_booking_json(b));
end;
$$;
comment on function booking.verify_booking(uuid, text) is
  'PRIVILEGED (SECURITY DEFINER), private schema. Checks a one-time code (5 attempts, single use), rechecks the time and turns the hold into a request or a confirmed booking; queues the customer and owner emails. Idempotent. Reached through public.booking_verify.';

create function booking.resend_code(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_max_sends constant int := 4; -- the first email and 3 re-sends
  c_codes_per_address_per_hour constant int := 5;
  c_codes_per_address_per_day constant int := 10;
  v_email text;
  v booking.verifications%rowtype;
  b booking.bookings%rowtype;
  v_settings booking.settings%rowtype;
  v_hour int;
  v_day int;
  v_code text;
begin
  if p_request_id is null then
    perform booking.raise_error('INVALID_INPUT', 'requestId');
  end if;

  -- Advisory locks first (address, site), then rows: the order request_booking uses.
  select lower(x.customer_email) into v_email
  from booking.verifications vv
  join booking.bookings x on x.id = vv.booking_id
  where vv.id = p_request_id;
  if v_email is null then
    return jsonb_build_object('result', 'expired');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:email:' || v_email, 0));
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:site', 0));

  select * into v from booking.verifications where id = p_request_id for update;
  select * into b from booking.bookings where id = v.booking_id for update;
  if v.verified_at is not null then
    return jsonb_build_object('result', 'verified');
  end if;
  if b.id is null or b.status <> 'unverified' or v.attempts >= 5
     or v.expires_at <= now() or b.hold_expires_at <= now() then
    if b.id is not null and b.status = 'unverified' then
      delete from booking.bookings where id = b.id;
    end if;
    return jsonb_build_object('result', 'expired');
  end if;
  if v.sends >= c_max_sends then
    return jsonb_build_object('result', 'limit_reached');
  end if;
  if v.last_sent_at > now() - interval '60 seconds' then
    return jsonb_build_object('result', 'too_soon',
      'retryAfterSeconds', greatest(1, ceil(60 - extract(epoch from now() - v.last_sent_at))::int));
  end if;

  select * into v_settings from booking.settings where id;
  select count(*) filter (where o.created_at > now() - interval '1 hour'), count(*)
    into v_hour, v_day
  from booking.email_outbox o
  where o.recipient = v_email and o.kind = 'verification_code' and o.created_at > now() - interval '1 day';
  if v_hour >= c_codes_per_address_per_hour or v_day >= c_codes_per_address_per_day then
    perform booking.raise_error('RATE_LIMITED');
  end if;
  select count(*) into v_day
  from booking.email_outbox o
  where o.kind = 'verification_code' and o.created_at > now() - interval '1 day';
  if v_day >= v_settings.max_verification_emails_per_day then
    perform booking.raise_error('RATE_LIMITED');
  end if;

  -- A new code; the earlier one stops working. The window is not extended.
  v_code := booking.new_code();
  update booking.verifications
     set code_hash = booking.code_hash(v.id, v_code), attempts = 0, sends = sends + 1, last_sent_at = now()
   where id = v.id
  returning * into v;
  update booking.email_outbox o
     set status = 'cancelled', payload = o.payload - 'code', locked_until = null
   where o.kind = 'verification_code' and o.booking_id = b.id and o.status in ('pending', 'sending');
  perform booking.enqueue_email('verification_code', b.customer_email, b.id,
    (booking.booking_email_payload(b, false) - 'customerName' - 'status')
      || jsonb_build_object('code', v_code, 'expiresAt', booking.iso(v.expires_at),
                            'minutesValid', v_settings.verification_window_minutes),
    'verification_code:' || v.id || ':' || v.sends);

  return jsonb_build_object('result', 'sent', 'expiresAt', booking.iso(v.expires_at),
                            'resendsLeft', c_max_sends - v.sends, 'resendAfterSeconds', 60);
end;
$$;
comment on function booking.resend_code(uuid) is
  'PRIVILEGED (SECURITY DEFINER), private schema. A new one-time code for an open request (at most 3 re-sends, 60 s apart, same expiry). Reached through public.booking_resend_code.';

-- The visitor changed their mind (another time, a mistyped address): release
-- the hold at once instead of keeping the time from everyone until it lapses.
-- Only the holder of the request id can do this; a verified request is the
-- owner's to decline.
create function booking.cancel_request(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v booking.verifications%rowtype;
  b booking.bookings%rowtype;
begin
  if p_request_id is null then
    perform booking.raise_error('INVALID_INPUT', 'requestId');
  end if;
  select * into v from booking.verifications where id = p_request_id for update;
  if not found then
    return jsonb_build_object('result', 'expired');
  end if;
  if v.verified_at is not null then
    return jsonb_build_object('result', 'verified');
  end if;
  select * into b from booking.bookings where id = v.booking_id for update;
  if b.id is null or b.status <> 'unverified' then
    return jsonb_build_object('result', 'expired');
  end if;
  -- Withdraw its unsent code email first (the row keeps no link once the booking is gone).
  update booking.email_outbox o
     set status = 'cancelled', payload = o.payload - 'code', locked_until = null
   where o.kind = 'verification_code' and o.booking_id = b.id and o.status in ('pending', 'sending')
     and (o.locked_until is null or o.locked_until <= now());
  delete from booking.bookings where id = b.id;
  return jsonb_build_object('result', 'cancelled');
end;
$$;
comment on function booking.cancel_request(uuid) is
  'PRIVILEGED (SECURITY DEFINER), private schema. Releases an unverified hold for the holder of its request id. Reached through public.booking_cancel_request.';

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

create function public.booking_request(
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
  select booking.request_booking(p_service_id, p_starts_at, p_customer_name, p_customer_email, p_customer_phone, p_notes);
$$;
comment on function public.booking_request(uuid, timestamptz, text, text, text, text) is
  'Public. Starts a booking request: holds the time for the verification window and emails a one-time code. Reveals nothing about other bookings.';

create function public.booking_verify(p_request_id uuid, p_code text)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select booking.verify_booking(p_request_id, p_code);
$$;
comment on function public.booking_verify(uuid, text) is
  'Public. Checks the one-time code and turns the hold into a request (or a confirmed booking).';

create function public.booking_resend_code(p_request_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select booking.resend_code(p_request_id);
$$;
comment on function public.booking_resend_code(uuid) is 'Public. Emails a new one-time code for an open request.';

create function public.booking_cancel_request(p_request_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select booking.cancel_request(p_request_id);
$$;
comment on function public.booking_cancel_request(uuid) is
  'Public. Releases the caller''s own unverified hold (identified by its request id) so the time is free again at once.';

-- The unverified path is closed; the signature stays so older sites get a clear error.
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
security invoker
set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = 'booking_engine:VERIFICATION_REQUIRED', detail = '';
end;
$$;
comment on function public.booking_create(uuid, timestamptz, text, text, text, text) is
  'Closed since 2.0.0-alpha.4: bookings need a verified email. Use booking_request and booking_verify.';
drop function booking.create_booking(uuid, timestamptz, text, text, text, text);

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
      'pendingHoldMinutes', s.pending_hold_minutes,
      'onlineBookingEnabled', s.online_booking_enabled,
      'verificationWindowMinutes', s.verification_window_minutes
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
    'emailVerified', b.email_verified_at is not null,
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

-- Unverified holds are not requests yet: the owner never sees them.
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
    where b2.status <> 'unverified'
      and b2.starts_at >= (p_from::timestamp at time zone v_tz)
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
  v_stored text;
begin
  v_uid := booking.require_admin();
  if p_status is null or p_status not in ('confirmed', 'cancelled', 'completed', 'no_show') then
    perform booking.raise_error('INVALID_INPUT', 'status');
  end if;

  select * into b from booking.bookings where id = p_booking_id for update;
  if not found or b.status = 'unverified' then
    perform booking.raise_error('NOT_FOUND', 'booking');
  end if;
  select s.timezone into v_tz from booking.settings s where s.id;

  v_stored := b.status;
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
      -- An expired request's time was taken by someone else meanwhile.
      perform booking.raise_error('CONFLICT', 'slot_taken');
  end;

  insert into booking.booking_events (booking_id, event_type, from_status, to_status, actor, actor_user_id)
  values (b.id, 'status_changed', v_from, p_status, 'admin', v_uid);

  -- Tell the customer. Only verified addresses are emailed; a customer whose
  -- request was already reported as expired is not told twice.
  if b.email_verified_at is not null then
    if p_status = 'confirmed' then
      perform booking.enqueue_email('booking_confirmed', b.customer_email, b.id,
        booking.booking_email_payload(b, false), 'booking_confirmed:' || b.id);
    elsif p_status = 'cancelled' and v_from = 'confirmed' then
      perform booking.enqueue_email('booking_cancelled', b.customer_email, b.id,
        booking.booking_email_payload(b, false), 'booking_cancelled:' || b.id);
    elsif p_status = 'cancelled' and v_stored = 'pending' then
      perform booking.enqueue_email('booking_declined', b.customer_email, b.id,
        booking.booking_email_payload(b, false), 'booking_declined:' || b.id);
    end if;
  end if;

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
    'ownerNotificationEmail', s.owner_notification_email,
    'verificationWindowMinutes', s.verification_window_minutes,
    'maxVerificationEmailsPerDay', s.max_verification_emails_per_day,
    'onlineBookingEnabled', s.online_booking_enabled,
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
                            'maxWebsiteBookingsPerHour', 'pendingHoldMinutes', 'ownerNotificationEmail',
                            'verificationWindowMinutes', 'maxVerificationEmailsPerDay', 'onlineBookingEnabled'];
  c_email_re constant text := '^[^@[:space:]<>()]+@[^@[:space:]<>()]+\.[^@[:space:]<>()]{2,}$';
  v_key text;
  v_email text;
  v_owner_email text;
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
  if v_email is not null and v_email !~ c_email_re then
    perform booking.raise_error('INVALID_INPUT', 'publicEmail');
  end if;
  v_owner_email := lower(booking.j_text(p_settings, 'ownerNotificationEmail', 254));
  if v_owner_email is not null and v_owner_email !~ c_email_re then
    perform booking.raise_error('INVALID_INPUT', 'ownerNotificationEmail');
  end if;
  if p_settings ? 'currency' and coalesce(booking.j_text(p_settings, 'currency', 3), '') !~ '^[A-Z]{3}$' then
    perform booking.raise_error('INVALID_INPUT', 'currency');
  end if;
  if p_settings ? 'locale'
     and coalesce(booking.j_text(p_settings, 'locale', 35), '') !~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$' then
    perform booking.raise_error('INVALID_INPUT', 'locale');
  end if;
  if coalesce(booking.j_bool(p_settings, 'onlineBookingEnabled'), false)
     and not exists (select 1 from booking.mailer_state m where m.id and m.last_success_at is not null) then
    -- Customers must be able to receive their code: deliver a test email first.
    perform booking.raise_error('INVALID_INPUT', 'onlineBookingEnabled');
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
      else max_website_bookings_per_hour end,
    pending_hold_minutes = case when p_settings ? 'pendingHoldMinutes'
      then coalesce(booking.j_int(p_settings, 'pendingHoldMinutes', 15, 10080), pending_hold_minutes)
      else pending_hold_minutes end,
    owner_notification_email = case when p_settings ? 'ownerNotificationEmail' then v_owner_email else owner_notification_email end,
    verification_window_minutes = case when p_settings ? 'verificationWindowMinutes'
      then coalesce(booking.j_int(p_settings, 'verificationWindowMinutes', 5, 30), verification_window_minutes)
      else verification_window_minutes end,
    max_verification_emails_per_day = case when p_settings ? 'maxVerificationEmailsPerDay'
      then coalesce(booking.j_int(p_settings, 'maxVerificationEmailsPerDay', 1, 5000), max_verification_emails_per_day)
      else max_verification_emails_per_day end,
    online_booking_enabled = case when p_settings ? 'onlineBookingEnabled'
      then coalesce(booking.j_bool(p_settings, 'onlineBookingEnabled'), online_booking_enabled)
      else online_booking_enabled end
  where id;

  return booking.settings_json();
end;
$$;

create function public.booking_admin_email_status()
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
  select jsonb_build_object(
    'mailer', (select jsonb_build_object(
                 'lastAttemptAt', booking.iso(m.last_attempt_at),
                 'lastSuccessAt', booking.iso(m.last_success_at),
                 'lastFailureAt', booking.iso(m.last_failure_at),
                 'lastError', m.last_error)
               from booking.mailer_state m where m.id),
    'wiring', booking.mailer_wiring(),
    'counts', (select jsonb_build_object(
                 'queued', count(*) filter (where o.status in ('pending', 'sending')),
                 'failedLast7Days', count(*) filter (where o.status = 'failed' and o.created_at > now() - interval '7 days'),
                 'sentLast24h', count(*) filter (where o.status = 'sent' and o.sent_at > now() - interval '1 day'),
                 'codesLast24h', count(*) filter (where o.kind = 'verification_code' and o.created_at > now() - interval '1 day'))
               from booking.email_outbox o),
    'recent', coalesce((
      select jsonb_agg(x.j order by x.created_at desc)
      from (
        select o.created_at, jsonb_build_object(
                 'id', o.id, 'kind', o.kind, 'status', o.status, 'recipient', booking.mask_email(o.recipient),
                 'attempts', o.attempts, 'createdAt', booking.iso(o.created_at), 'sentAt', booking.iso(o.sent_at),
                 'lastError', o.last_error) as j
        from booking.email_outbox o
        order by o.created_at desc
        limit 20
      ) as x), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
comment on function public.booking_admin_email_status() is
  'Admin only. Email sending health, wiring (booleans), counts and the 20 latest emails (masked recipients, never contents).';

create function public.booking_admin_send_test_email(p_recipient text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c_tests_per_hour constant int := 10;
  v_email text := lower(btrim(coalesce(p_recipient, '')));
  v_count int;
begin
  perform booking.require_admin();
  if char_length(v_email) > 254 or v_email !~ '^[^@[:space:]<>()]+@[^@[:space:]<>()]+\.[^@[:space:]<>()]{2,}$' then
    perform booking.raise_error('INVALID_INPUT', 'recipient');
  end if;
  select count(*) into v_count
  from booking.email_outbox o
  where o.kind = 'test' and o.created_at > now() - interval '1 hour';
  if v_count >= c_tests_per_hour then
    perform booking.raise_error('RATE_LIMITED');
  end if;
  perform booking.enqueue_email('test', v_email, null,
    (select jsonb_strip_nulls(jsonb_build_object('businessName', s.business_name, 'businessEmail', s.public_email,
                                                 'timezone', s.timezone, 'locale', s.locale))
     from booking.settings s where s.id),
    'test:' || gen_random_uuid());
  return jsonb_build_object('queued', true);
end;
$$;
comment on function public.booking_admin_send_test_email(text) is
  'Admin only. Queues a test email (at most 10 an hour). A delivered test email unlocks online booking.';

-- ----------------------------------------------------------------------------
-- Mailer API — the booking-mailer Edge Function only (service_role)
-- ----------------------------------------------------------------------------

create function public.booking_mailer_claim(p_limit int default 10)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_result jsonb;
begin
  perform booking.run_maintenance();
  update booking.mailer_state set last_attempt_at = now() where id;

  with due as (
    select o.id
    from booking.email_outbox o
    where o.status in ('pending', 'sending')
      and o.next_attempt_at <= now()
      and (o.locked_until is null or o.locked_until <= now())
    order by o.created_at
    limit v_limit
    for update skip locked
  ),
  claimed as (
    update booking.email_outbox o
       set status = 'sending', locked_until = now() + interval '2 minutes', attempts = o.attempts + 1
      from due
     where o.id = due.id
    returning o.id, o.kind, o.recipient, o.payload, o.attempts, o.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'kind', c.kind, 'to', c.recipient, 'payload', c.payload, 'attempt', c.attempts)
           order by c.created_at), '[]'::jsonb)
  into v_result
  from claimed c;
  return v_result;
end;
$$;
comment on function public.booking_mailer_claim(int) is
  'service_role only (booking-mailer). Runs maintenance, then leases up to p_limit due emails for 2 minutes.';

create function public.booking_mailer_report(
  p_id uuid,
  p_attempt int,
  p_ok boolean,
  p_provider_id text default null,
  p_error text default null,
  p_permanent boolean default false
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c_max_attempts constant int := 5;
  o booking.email_outbox%rowtype;
  v_give_up boolean;
  v_error text := left(coalesce(nullif(btrim(p_error), ''), 'Unknown error'), 500);
begin
  select * into o from booking.email_outbox where id = p_id for update;
  if not found or o.status <> 'sending' or o.attempts is distinct from p_attempt then
    return jsonb_build_object('updated', false);
  end if;
  if coalesce(p_ok, false) then
    update booking.email_outbox
       set status = 'sent', sent_at = now(), provider_message_id = left(p_provider_id, 200), locked_until = null,
           last_error = null,
           payload = case when kind = 'verification_code' then payload - 'code' else payload end
     where id = p_id;
    update booking.mailer_state set last_success_at = now() where id;
  else
    v_give_up := coalesce(p_permanent, false) or o.attempts >= c_max_attempts;
    update booking.email_outbox
       set status = case when v_give_up then 'failed' else 'pending' end,
           next_attempt_at = now() + interval '1 minute' * power(4, least(o.attempts, 4) - 1),
           locked_until = null,
           last_error = v_error,
           payload = case when v_give_up and kind = 'verification_code' then payload - 'code' else payload end
     where id = p_id;
    update booking.mailer_state set last_failure_at = now(), last_error = v_error where id;
  end if;
  return jsonb_build_object('updated', true);
end;
$$;
comment on function public.booking_mailer_report(uuid, int, boolean, text, text, boolean) is
  'service_role only (booking-mailer). Records one delivery result for a leased email; retries after 1, 4, 16 and 64 minutes, then gives up.';

create function public.booking_mailer_report_unconfigured(p_error text)
returns void
language sql
volatile
security invoker
set search_path = ''
as $$
  update booking.mailer_state
     set last_attempt_at = now(), last_failure_at = now(),
         last_error = left(coalesce(nullif(btrim(p_error), ''), 'Email sending is not configured'), 500)
   where id;
$$;
comment on function public.booking_mailer_report_unconfigured(text) is
  'service_role only (booking-mailer). Records that the function is missing its provider settings; nothing is claimed.';

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------

alter table booking.verifications enable row level security;
alter table booking.email_outbox enable row level security;
alter table booking.mailer_state enable row level security;

create policy verifications_no_api_access on booking.verifications
  for all to anon, authenticated using (false) with check (false);
create policy email_outbox_admin_read on booking.email_outbox
  for select to authenticated using ((select booking.is_admin()));
create policy email_outbox_admin_insert on booking.email_outbox
  for insert to authenticated with check ((select booking.is_admin()));
create policy mailer_state_admin_read on booking.mailer_state
  for select to authenticated using ((select booking.is_admin()));

-- ----------------------------------------------------------------------------
-- Privileges
-- ----------------------------------------------------------------------------

revoke all on booking.verifications, booking.email_outbox, booking.mailer_state
  from public, anon, authenticated, service_role;

-- Admins (through the INVOKER admin functions): queue emails and read their
-- status, never their contents.
grant select (id, kind, recipient, booking_id, dedupe_key, status, attempts, next_attempt_at, locked_until,
              provider_message_id, last_error, created_at, sent_at)
  on booking.email_outbox to authenticated;
grant insert (kind, recipient, booking_id, payload, dedupe_key) on booking.email_outbox to authenticated;
grant select on booking.mailer_state to authenticated;

-- The mailer (secret key → service_role): lease and report.
grant select, update on booking.email_outbox to service_role;
grant select, update on booking.mailer_state to service_role;

grant select (online_booking_enabled, verification_window_minutes) on booking.settings to anon, service_role;

-- New functions start with no access (PostgreSQL grants EXECUTE to PUBLIC by
-- default); then grant on purpose.
revoke execute on all functions in schema booking from public;
revoke all on function
  booking.mask_email(text),
  booking.new_code(),
  booking.code_hash(uuid, text),
  booking.public_booking_json(booking.bookings),
  booking.booking_email_payload(booking.bookings, boolean),
  booking.enqueue_email(text, text, uuid, jsonb, text),
  booking.kick_mailer(),
  booking.email_outbox_after_insert(),
  booking.expire_lapsed(uuid, timestamptz, timestamptz),
  booking.compute_slots(uuid, date, date, timestamptz, uuid, uuid),
  booking.run_maintenance(),
  booking.mailer_tick(),
  booking.mailer_wiring(),
  booking.request_booking(uuid, timestamptz, text, text, text, text),
  booking.verify_booking(uuid, text),
  booking.resend_code(uuid),
  booking.cancel_request(uuid),
  public.booking_request(uuid, timestamptz, text, text, text, text),
  public.booking_verify(uuid, text),
  public.booking_resend_code(uuid),
  public.booking_cancel_request(uuid),
  public.booking_admin_email_status(),
  public.booking_admin_send_test_email(text),
  public.booking_mailer_claim(int),
  public.booking_mailer_report(uuid, int, boolean, text, text, boolean),
  public.booking_mailer_report_unconfigured(text)
from public, anon, authenticated, service_role;

-- Public booking flow: the wrappers and the private privileged functions they
-- call (executable, but not reachable by URL: schema `booking` is not exposed).
grant execute on function
  public.booking_request(uuid, timestamptz, text, text, text, text),
  public.booking_verify(uuid, text),
  public.booking_resend_code(uuid),
  public.booking_cancel_request(uuid),
  booking.request_booking(uuid, timestamptz, text, text, text, text),
  booking.verify_booking(uuid, text),
  booking.resend_code(uuid),
  booking.cancel_request(uuid)
to anon, authenticated, service_role;

-- Admin.
grant execute on function
  public.booking_admin_email_status(),
  public.booking_admin_send_test_email(text),
  booking.mask_email(text),
  booking.mailer_wiring(),
  booking.enqueue_email(text, text, uuid, jsonb, text),
  booking.booking_email_payload(booking.bookings, boolean)
to authenticated;

-- Mailer.
grant execute on function
  public.booking_mailer_claim(int),
  public.booking_mailer_report(uuid, int, boolean, text, text, boolean),
  public.booking_mailer_report_unconfigured(text),
  booking.run_maintenance()
to service_role;

update booking.engine_info set schema_version = '2.0.0-alpha.4', updated_at = now() where id;
