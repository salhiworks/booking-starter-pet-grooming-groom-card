-- ============================================================================
-- Profit Studio Booking Engine — migration 0009_reliable_answers
-- Engine schema version: 2.0.0-beta.4
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Bug fixes only (no table, column, constraint, policy or grant on existing
-- objects changes; the two replaced functions keep their signatures):
--   1. Verifying again with an accepted code answers with the booking as it
--      stands now, and only an active one (pending or confirmed) is
--      `verified`. A declined, cancelled, lapsed, completed or no-show booking is
--      `{ result: 'inactive', status, reference }`, never a booking a website
--      could show as booked. (Before: `verified` with the current status,
--      e.g. 'cancelled'.)
--   2. The owner can no longer confirm a request whose time has started
--      (INVALID_TRANSITION, detail `already_started`).
--   3. Confirming an expired request first releases holds that lapsed but were
--      not released yet, so only a real conflict refuses it: a request or
--      booking (CONFLICT `slot_taken`, as before) or a visitor entering their
--      code for that time right now (CONFLICT `slot_held`, new).
--
-- No row changes. Bookings, holds, emails and settings are untouched.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.10' then
    raise exception 'Booking Engine 0009_reliable_answers expects schema 2.0.0-alpha.10, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Verifying again: only an active booking is an answer of 'verified'
-- ----------------------------------------------------------------------------

create or replace function booking.verify_booking(p_request_id uuid, p_code text)
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

  -- Already verified: the same code gives the booking's answer as it stands now
  -- (retries, double clicks, an answer lost on the way). Only a booking that is
  -- still active is an answer of 'verified'; one the owner declined or
  -- cancelled, a request whose hold lapsed, or an appointment marked done or a
  -- no-show is 'inactive', so no website can show it as booked.
  if v.verified_at is not null then
    if b.id is not null and v.code_hash = booking.code_hash(v.id, v_code) then
      v_status := booking.effective_status(b.status, b.hold_expires_at);
      if v_status in ('pending', 'confirmed') then
        return jsonb_build_object('result', 'verified', 'booking', booking.public_booking_json(b));
      end if;
      return jsonb_build_object('result', 'inactive', 'status', v_status, 'reference', b.reference);
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
  'PRIVILEGED (SECURITY DEFINER), private schema. Checks a one-time code (5 attempts, single use), rechecks the time and turns the hold into a request or a confirmed booking; queues the customer and owner emails. Idempotent: the same code again answers with the booking as it stands now — verified while pending or confirmed, inactive (with its status) once declined, cancelled, expired, completed or a no-show. Reached through public.booking_verify.';

-- ----------------------------------------------------------------------------
-- 2 and 3. The owner's answer to a request
-- ----------------------------------------------------------------------------

-- Releases the holds around one booking's time that lapsed but were not
-- released yet — exactly what a visitor's request for that time does
-- (booking.expire_lapsed). Live holds and every other booking are untouched.
-- Admins only; used by booking_admin_set_booking_status, which runs with the
-- admin's own rights and cannot delete holds itself.
create function booking.release_lapsed_holds(p_booking_id uuid)
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  b booking.bookings%rowtype;
begin
  perform booking.require_admin();
  select * into b from booking.bookings where id = p_booking_id;
  if not found then
    return 0;
  end if;
  return booking.expire_lapsed(b.resource_id, b.starts_at, b.blocked_until);
end;
$$;
comment on function booking.release_lapsed_holds(uuid) is
  'PRIVILEGED (SECURITY DEFINER), private schema, admins only. Releases lapsed holds overlapping one booking''s time (booking.expire_lapsed) before the owner confirms an expired request. Reached through public.booking_admin_set_booking_status.';

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
  -- A request can be confirmed only for a time still ahead: once it has
  -- started, the customer has been told it expired, and a confirmation would
  -- be for a time that has passed.
  if p_status = 'confirmed' and b.starts_at <= now() then
    perform booking.raise_error('INVALID_TRANSITION', 'already_started');
  end if;

  -- An expired request no longer holds its time. Before it takes the time
  -- back, holds that lapsed but were not released yet (the regular sweep runs
  -- every few minutes) are released, as a visitor asking for the time would.
  -- A request still stored as pending holds its time, so nothing overlaps it.
  if p_status = 'confirmed' and v_stored = 'expired' then
    perform booking.release_lapsed_holds(b.id);
  end if;

  begin
    update booking.bookings
       set status = p_status, hold_expires_at = null, status_changed_at = now()
     where id = b.id
    returning * into b;
  exception
    when exclusion_violation then
      -- The time is no longer free: a request or booking took it meanwhile, or
      -- a visitor is entering their email code for it right now (a live hold
      -- that ends within the verification window).
      if exists (
        select 1 from booking.bookings x
        where x.resource_id = b.resource_id
          and x.id <> b.id
          and x.status in ('pending', 'confirmed')
          and tstzrange(x.starts_at, x.blocked_until, '[)') && tstzrange(b.starts_at, b.blocked_until, '[)')
      ) then
        perform booking.raise_error('CONFLICT', 'slot_taken');
      end if;
      perform booking.raise_error('CONFLICT', 'slot_held');
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


-- ----------------------------------------------------------------------------
-- Privileges: the new helper starts with no access, then admins (signed in).
-- `create or replace` keeps the grants of the two replaced functions.
-- ----------------------------------------------------------------------------

revoke all on function booking.release_lapsed_holds(uuid) from public, anon, authenticated, service_role;
grant execute on function booking.release_lapsed_holds(uuid) to authenticated;

update booking.engine_info set schema_version = '2.0.0-beta.4', updated_at = now() where id;
