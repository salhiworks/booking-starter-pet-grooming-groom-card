-- ============================================================================
-- Profit Studio Booking Engine — migration 0010_customer_data_erasure
-- Engine schema version: 2.0.0-beta.5
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Customer data erasure: the owner answers a customer's request to have their
-- personal data deleted, from the dashboard. Additive only — one nullable
-- column, one more history event type, one private function and two admin
-- functions; `booking.booking_json` gains one key. No row changes when this
-- migration runs, and nothing existing changes meaning.
--
--   public.booking_admin_customer_data(email)
--     What the booking database holds for one email address: bookings,
--     unfinished requests, booking emails, and the requests or bookings that
--     are still ahead (those must be answered or cancelled first).
--
--   public.booking_admin_erase_customer_data(email)
--     Erases it, in one transaction. Refused (CONFLICT, customer_has_upcoming)
--     while the customer has a request or booking still ahead — answering or
--     cancelling it first tells the customer, as usual.
--       * Unfinished requests (verification holds) are deleted with their codes.
--       * Every other booking keeps what the business needs for its records —
--         date, time, service, price, status, reference — but its name, email,
--         phone and note are replaced ("Erased customer",
--         erased@erased.invalid, none, none). Its address counts as unverified,
--         so no booking email can ever be sent about it again.
--       * Booking emails still waiting (or failed) are withdrawn. Every booking
--         email about these bookings — and any email to this address that
--         belongs to no booking (codes of lapsed requests, test emails) — loses
--         the customer's details, and the address itself is replaced. Emails to
--         this address about other people's bookings (the owner's alerts, when
--         the owner erases their own test data) are left alone.
--       * Each erased booking gets a `customer_erased` history event (which
--         admin, when) and `customer_erased_at`.
--     Outside the database, and so not affected: emails already delivered
--     (the customer's and the owner's inboxes), the email provider's logs,
--     and database backups until they expire.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-beta.4' then
    raise exception 'Booking Engine 0010_customer_data_erasure expects schema 2.0.0-beta.4, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Schema
-- ----------------------------------------------------------------------------

alter table booking.bookings add column customer_erased_at timestamptz;
comment on column booking.bookings.customer_erased_at is
  'When the owner erased this customer''s personal data (name, email, phone and note replaced). NULL otherwise.';

alter table booking.booking_events drop constraint booking_events_event_type_check;
alter table booking.booking_events add constraint booking_events_event_type_check
  check (event_type in ('created', 'status_changed', 'customer_erased'));

-- ----------------------------------------------------------------------------
-- What the dashboard shows of a booking: unchanged, plus customerErasedAt
-- (same signature; the grants of the existing function are kept).
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
    'statusChangedAt', booking.iso(b.status_changed_at),
    'customerErasedAt', booking.iso(b.customer_erased_at)
  );
$$;

-- ----------------------------------------------------------------------------
-- What the database holds for one address (admins; reads only)
-- ----------------------------------------------------------------------------

create function public.booking_admin_customer_data(p_email text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_tz text;
begin
  perform booking.require_admin();
  if char_length(v_email) < 3 or char_length(v_email) > 254
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' or v_email = 'erased@erased.invalid' then
    perform booking.raise_error('INVALID_INPUT', 'email');
  end if;
  select s.timezone into v_tz from booking.settings s where s.id;

  return jsonb_build_object(
    'email', v_email,
    'bookings', (
      select count(*)::int from booking.bookings b
      where lower(b.customer_email) = v_email and b.status <> 'unverified'),
    'openRequests', (
      select count(*)::int from booking.bookings b
      where lower(b.customer_email) = v_email and b.status = 'unverified'),
    'emails', (
      select count(*)::int from booking.email_outbox o
      where o.booking_id in (select b.id from booking.bookings b where lower(b.customer_email) = v_email)
         or (o.booking_id is null and o.recipient = v_email)),
    -- The latest delivery error the dashboard shows may quote the address.
    'otherMentions', (
      select count(*)::int from booking.mailer_state m
      where m.id and position(v_email in lower(coalesce(m.last_error, ''))) > 0),
    -- Still ahead: answered or cancelled first, so the customer is told as usual.
    'upcoming', coalesce((
      select jsonb_agg(booking.booking_json(b, v_tz) order by b.starts_at)
      from booking.bookings b
      where lower(b.customer_email) = v_email
        and b.status <> 'unverified'
        and booking.effective_status(b.status, b.hold_expires_at) in ('pending', 'confirmed', 'expired')
        and b.starts_at > now()), '[]'::jsonb)
  );
end;
$$;
comment on function public.booking_admin_customer_data(text) is
  'Admins only. What the booking database holds for one email address (counts, and the requests or bookings still ahead). Reads only.';

-- ----------------------------------------------------------------------------
-- The erasure (private: it deletes unfinished requests and rewrites booking
-- emails, which admins cannot do directly)
-- ----------------------------------------------------------------------------

create function booking.erase_customer_data(p_email text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_name constant text := 'Erased customer';
  c_email constant text := 'erased@erased.invalid';
  c_detail_keys constant text[] := array['customerName', 'customerEmail', 'customerPhone', 'notes', 'code'];
  v_uid uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_now timestamptz := now();
  v_ids uuid[];
  v_holds uuid[];
  v_kept uuid[];
  v_withdrawn int;
  v_cleared int;
  v_removed int;
  v_erased int;
begin
  v_uid := booking.require_admin();
  if char_length(v_email) < 3 or char_length(v_email) > 254
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' or v_email = c_email then
    perform booking.raise_error('INVALID_INPUT', 'email');
  end if;

  -- The lock a booking request for this address takes: no new request for it
  -- can start meanwhile (requests insert only after taking it).
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:email:' || v_email, 0));

  select coalesce(array_agg(b.id order by b.id), '{}') into v_ids
  from booking.bookings b
  where lower(b.customer_email) = v_email;
  -- Row locks in the order verifying and cancelling a request take them (the
  -- code, then the booking), so a customer entering a code at this moment waits
  -- instead of deadlocking. A request verified meanwhile is seen by the check below.
  perform 1 from booking.verifications v where v.booking_id = any (v_ids) order by v.id for update;
  perform 1 from booking.bookings b where b.id = any (v_ids) order by b.id for update;

  if exists (
    select 1 from booking.bookings b
    where b.id = any (v_ids)
      and b.status <> 'unverified'
      and booking.effective_status(b.status, b.hold_expires_at) in ('pending', 'confirmed', 'expired')
      and b.starts_at > v_now
  ) then
    perform booking.raise_error('CONFLICT', 'customer_has_upcoming');
  end if;

  select coalesce(array_agg(b.id) filter (where b.status = 'unverified'), '{}'),
         coalesce(array_agg(b.id) filter (where b.status <> 'unverified'), '{}')
    into v_holds, v_kept
  from booking.bookings b
  where b.id = any (v_ids);

  -- 1. Booking emails about these bookings, and emails to this address that
  --    belong to no booking: the ones still waiting (or failed, which "Retry
  --    failed emails" could send again) are withdrawn; all of them lose the
  --    customer's details and address.
  perform 1 from booking.email_outbox o
   where o.booking_id = any (v_ids) or (o.booking_id is null and o.recipient = v_email)
   order by o.id
   for update;
  select count(*) filter (where o.status in ('pending', 'sending', 'failed'))::int, count(*)::int
    into v_withdrawn, v_cleared
  from booking.email_outbox o
  where o.booking_id = any (v_ids) or (o.booking_id is null and o.recipient = v_email);
  update booking.email_outbox o
     set status = case when o.status in ('pending', 'sending', 'failed') then 'cancelled' else o.status end,
         locked_until = case when o.status in ('pending', 'sending', 'failed') then null else o.locked_until end,
         recipient = case when o.recipient = v_email then c_email else o.recipient end,
         payload = o.payload - c_detail_keys,
         last_error = case when o.last_error is null then null else 'Details removed with the customer''s data' end
   where o.booking_id = any (v_ids) or (o.booking_id is null and o.recipient = v_email);
  -- The latest delivery error shown in the dashboard may quote the address.
  update booking.mailer_state m
     set last_error = 'Details removed with the customer''s data'
   where m.id and position(v_email in lower(coalesce(m.last_error, ''))) > 0;

  -- 2. Codes of these bookings (salted hashes only), then the unfinished
  --    requests themselves (their history goes with them).
  delete from booking.verifications v where v.booking_id = any (v_ids);
  delete from booking.bookings b where b.id = any (v_holds);
  get diagnostics v_removed = row_count;

  -- 3. Every other booking stays for the business's records, without the
  --    person. An unverified address is never emailed (see the status and
  --    expiry functions), so nothing can be sent about these bookings again.
  update booking.bookings b
     set customer_name = c_name,
         customer_email = c_email,
         customer_phone = null,
         customer_notes = null,
         email_verified_at = null,
         customer_erased_at = v_now
   where b.id = any (v_kept);
  get diagnostics v_erased = row_count;
  insert into booking.booking_events (booking_id, event_type, actor, actor_user_id)
  select k.id, 'customer_erased', 'admin', v_uid from unnest(v_kept) as k(id);

  return jsonb_build_object(
    'email', v_email,
    'bookingsErased', v_erased,
    'requestsRemoved', v_removed,
    'emailsWithdrawn', v_withdrawn,
    'emailsCleared', v_cleared,
    'erasedAt', booking.iso(v_now)
  );
end;
$$;
comment on function booking.erase_customer_data(text) is
  'PRIVILEGED (SECURITY DEFINER), private schema, admins only. Erases one customer''s personal data (by email): deletes unfinished requests and their codes, anonymises the other bookings, withdraws and scrubs booking emails. Refused while a request or booking is still ahead. Reached through public.booking_admin_erase_customer_data.';

create function public.booking_admin_erase_customer_data(p_email text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform booking.require_admin();
  return booking.erase_customer_data(p_email);
end;
$$;
comment on function public.booking_admin_erase_customer_data(text) is
  'Admins only. Erases one customer''s personal data (see booking.erase_customer_data). Cannot be undone.';

-- ----------------------------------------------------------------------------
-- Privileges: the new functions start with no access, then admins (signed in;
-- each one checks the admin itself). `create or replace` keeps booking_json's.
-- ----------------------------------------------------------------------------

revoke all on function
  booking.erase_customer_data(text),
  public.booking_admin_customer_data(text),
  public.booking_admin_erase_customer_data(text)
from public, anon, authenticated, service_role;
grant execute on function
  booking.erase_customer_data(text),
  public.booking_admin_customer_data(text),
  public.booking_admin_erase_customer_data(text)
to authenticated;

update booking.engine_info set schema_version = '2.0.0-beta.5', updated_at = now() where id;
