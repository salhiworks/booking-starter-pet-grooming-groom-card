-- ============================================================================
-- Profit Studio Booking Engine — migration 0011_reliable_email_and_search
-- Engine schema version: 2.0.0-beta.5
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Email and dashboard reliability. No table, column, constraint, policy or
-- grant on existing objects changes, and no row changes when this migration
-- runs. Two private helpers and one admin function are added; four functions
-- are replaced with the same signatures (their grants are kept):
-- booking.run_maintenance, booking_mailer_claim, booking_admin_retry_failed_emails
-- and booking_admin_email_status.
--
--   1. Customer emails that no longer match their booking are withdrawn
--      before they are sent. Each email is a snapshot of the moment it was
--      queued; one that is still waiting (for example after a failed attempt)
--      when the booking changes would otherwise arrive later with old news —
--      a "Confirmed" after the "Cancelled". An email about a booking is
--      withdrawn ('cancelled', with the reason in last_error — "Not sent: …",
--      or "Not retried: …" after an earlier attempt) when:
--        * the booking is no longer in the state it announces (a "Request
--          received" once the owner answered, a "Confirmed" once cancelled or
--          done, a "Request expired" once confirmed after all), or
--        * a "Confirmed" email is still waiting when the appointment starts, or
--        * a newer email about the same booking has been queued since.
--      Checked by the regular maintenance (before every mailer run and every
--      minute), again when emails are leased, and by "Retry failed emails",
--      which no longer sends such an email again; a failed one stays failed
--      (that is what happened) and the email status says it will not be
--      retried. Owner alerts, test emails and codes keep their own rules.
--   2. The emails of one booking are handed to the email provider in the order
--      they were queued: a newer one waits while an older one is being sent.
--      Mailer runs lease one at a time (a transaction lock). (The order in
--      which inboxes show them is up to the email services between; the engine
--      controls what it sends and when.)
--   3. A lease covers the time its email may wait in the mailer's batch: 1
--      minute plus 20 seconds for each place in the batch (a send times out
--      after 15 seconds) — 80 s for the first email, 260 s for the tenth —
--      instead of 2 minutes for all, so a slow batch is never handed to a
--      second mailer while it is being sent. The mailer (2.0.0-beta.5) stops
--      before an email's lease ends.
--   4. public.booking_admin_search_bookings: the dashboard's search looks at
--      every booking (names, email addresses, phone numbers, references,
--      services, notes) — not a year either side — and returns it page by
--      page: upcoming bookings first (soonest first), then past ones (most
--      recent first), with the number of matches. Admins only.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-beta.5' then
    raise exception 'Booking Engine 0011_reliable_email_and_search expects schema 2.0.0-beta.5 (migration 0010 first), found %', coalesce(v, 'none');
  end if;
  -- 0010 and 0011 share the schema label: the new search function tells a second run.
  if to_regprocedure('public.booking_admin_search_bookings(text, jsonb, integer)') is not null then
    raise exception 'Booking Engine 0011_reliable_email_and_search has already been applied to this database';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Which customer emails no longer apply
-- ----------------------------------------------------------------------------

-- Why a customer email about a booking should not be sent any more, in the
-- owner's words (e.g. "the booking is now cancelled."); null while it still
-- applies. Only the five customer email kinds about a booking are judged
-- (codes, owner alerts and test emails have their own rules), and only while
-- the booking exists. Emails queued at the same instant are ordered by id.
create function booking.outdated_email_reason(p_id uuid, p_kind text, p_booking_id uuid, p_created_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when (p_kind = 'request_received' and v.status <> 'pending')
      or (p_kind = 'booking_confirmed' and v.status <> 'confirmed')
      or (p_kind in ('booking_declined', 'booking_cancelled') and v.status <> 'cancelled')
      or (p_kind = 'request_expired' and v.status not in ('expired', 'cancelled'))
      then 'the booking is now ' || case v.status
             when 'pending' then 'waiting for your answer'
             when 'confirmed' then 'confirmed'
             when 'cancelled' then 'cancelled'
             when 'expired' then 'expired'
             when 'completed' then 'marked done'
             when 'no_show' then 'marked as a no-show'
             else v.status end || '.'
    when p_kind = 'booking_confirmed' and b.starts_at <= now()
      then 'the appointment had already started.'
    when exists (
      select 1
      from booking.email_outbox n
      where n.booking_id = p_booking_id
        and n.kind in ('request_received', 'booking_confirmed', 'booking_declined', 'booking_cancelled', 'request_expired')
        and n.status <> 'cancelled'
        and (n.created_at, n.id) > (p_created_at, p_id)
    )
      then 'a newer email about this booking replaces it.'
  end
  from booking.bookings b
  cross join lateral (select booking.effective_status(b.status, b.hold_expires_at) as status) as v
  where b.id = p_booking_id
    and p_kind in ('request_received', 'booking_confirmed', 'booking_declined', 'booking_cancelled', 'request_expired');
$$;
comment on function booking.outdated_email_reason(uuid, text, uuid, timestamptz) is
  'Why a waiting or failed customer email about a booking no longer applies (null while it does): the booking left the state it announces, a confirmation would arrive after the start, or a newer email about the booking was queued. Used by maintenance, "Retry failed emails" and the email status.';

-- Housekeeping (0005) plus: outdated customer emails are withdrawn before any
-- mailer can lease them. Emails being sent right now (a live lease) are left
-- to their mailer.
create or replace function booking.run_maintenance()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_released int;
  v_withdrawn int;
  v_outdated int;
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

  -- The conditions are on the updated row itself, so a row another mailer
  -- leases meanwhile is re-checked (and left alone) once its lock is free.
  -- An email tried before is "not retried"; one whose mailer never reported
  -- back (its lease ran out) may still have been delivered, and says so.
  update booking.email_outbox o
     set status = 'cancelled', locked_until = null,
         last_error = case when o.attempts > 0 then 'Not retried: ' else 'Not sent: ' end
                      || booking.outdated_email_reason(o.id, o.kind, o.booking_id, o.created_at)
                      || case when o.status = 'sending' then ' The interrupted attempt may still have been delivered.' else '' end
   where o.status in ('pending', 'sending')
     and (o.locked_until is null or o.locked_until <= now())
     and o.kind in ('request_received', 'booking_confirmed', 'booking_declined', 'booking_cancelled', 'request_expired')
     and o.booking_id is not null
     and booking.outdated_email_reason(o.id, o.kind, o.booking_id, o.created_at) is not null;
  get diagnostics v_outdated = row_count;

  update booking.email_outbox o
     set status = 'failed', locked_until = null,
         payload = case when o.kind = 'verification_code' then o.payload - 'code' else o.payload end,
         last_error = coalesce(o.last_error, 'Sending was interrupted repeatedly')
   where o.status = 'sending' and o.locked_until <= now() and o.attempts >= 5;

  delete from booking.email_outbox o
   where o.status in ('sent', 'failed', 'cancelled')
     and o.created_at < now() - case when o.kind = 'verification_code' then interval '2 days' else interval '30 days' end;
  delete from booking.verifications v where v.created_at < now() - interval '1 day';
  delete from booking.mailer_starts s where s.started_at < now() - interval '1 day';

  return jsonb_build_object('released', v_released, 'withdrawn', v_withdrawn, 'outdated', v_outdated);
end;
$$;

-- ----------------------------------------------------------------------------
-- 2 and 3. Leasing: one booking's emails in order; a lease covers the batch
-- ----------------------------------------------------------------------------

create or replace function public.booking_mailer_claim(p_limit int default 10)
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
  -- One lease at a time: a second mailer run waits until this one's leases are
  -- committed, so it sees which emails are being sent (the order rule below).
  perform pg_advisory_xact_lock(hashtextextended('booking_engine:mailer_claim', 0));
  perform booking.run_maintenance();
  update booking.mailer_state set last_attempt_at = now() where id;

  with due as (
    select o.id, o.created_at
    from booking.email_outbox o
    where o.status in ('pending', 'sending')
      and o.next_attempt_at <= now()
      and (o.locked_until is null or o.locked_until <= now())
      -- A booking's customer emails go out in the order they were queued:
      -- never while an older one is still being sent, and never once a newer
      -- one exists (checked again here, in the snapshot of the lease, for an
      -- answer the owner gave after the maintenance above).
      and not (
        o.kind in ('request_received', 'booking_confirmed', 'booking_declined', 'booking_cancelled', 'request_expired')
        and o.booking_id is not null
        and exists (
          select 1
          from booking.email_outbox p
          where p.booking_id = o.booking_id
            and p.kind in ('request_received', 'booking_confirmed', 'booking_declined', 'booking_cancelled', 'request_expired')
            and p.id <> o.id
            and (
              ((p.created_at, p.id) < (o.created_at, o.id) and p.status = 'sending' and p.locked_until > now())
              or ((p.created_at, p.id) > (o.created_at, o.id) and p.status <> 'cancelled')
            )
        )
      )
    order by o.created_at, o.id
    limit v_limit
    for update skip locked
  ),
  -- The mailer sends a batch one by one (each send gives up after 15 s): the
  -- n-th email may wait for n-1 sends, so its lease is 60 s + 20 s × n.
  placed as (
    select d.id, (60 + 20 * row_number() over (order by d.created_at, d.id))::int as lease_seconds
    from due d
  ),
  claimed as (
    update booking.email_outbox o
       set status = 'sending', locked_until = now() + make_interval(secs => pl.lease_seconds), attempts = o.attempts + 1
      from placed pl
     where o.id = pl.id
    returning o.id, o.kind, o.recipient, o.payload, o.attempts, o.created_at, pl.lease_seconds
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'kind', c.kind, 'to', c.recipient, 'payload', c.payload, 'attempt', c.attempts,
           'leaseSeconds', c.lease_seconds)
           order by c.created_at, c.id), '[]'::jsonb)
  into v_result
  from claimed c;
  return v_result;
end;
$$;
comment on function public.booking_mailer_claim(int) is
  'service_role only (booking-mailer). One run at a time: runs maintenance (outdated customer emails are withdrawn), then leases up to p_limit due emails, the n-th for 60 + 20 × n seconds (leaseSeconds in each) — a booking''s customer emails one at a time, in the order they were queued, never one a newer email replaces.';

-- ----------------------------------------------------------------------------
-- 1 (cont.). "Retry failed emails" never sends an outdated email again
-- ----------------------------------------------------------------------------

create or replace function public.booking_admin_retry_failed_emails()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  n int;
  v_withdrawn int;
begin
  perform booking.require_admin();
  update booking.email_outbox o
     set status = 'cancelled',
         last_error = 'Not retried: ' || booking.outdated_email_reason(o.id, o.kind, o.booking_id, o.created_at)
   where o.status = 'failed'
     and o.kind <> 'verification_code'
     and o.created_at > now() - interval '23 hours'
     and booking.outdated_email_reason(o.id, o.kind, o.booking_id, o.created_at) is not null;
  get diagnostics v_withdrawn = row_count;
  update booking.email_outbox o
     set status = 'pending', attempts = 0, next_attempt_at = now(), locked_until = null, last_error = null
   where o.status = 'failed'
     and o.kind <> 'verification_code'
     and o.created_at > now() - interval '23 hours';
  get diagnostics n = row_count;
  return jsonb_build_object('requeued', n, 'withdrawn', v_withdrawn);
end;
$$;
comment on function public.booking_admin_retry_failed_emails() is
  'Admin only. Puts emails that failed in the last 23 hours back in the queue (idempotent within Resend''s 24-hour window). Customer emails that no longer match their booking are withdrawn instead (reason in last_error). Returns { requeued, withdrawn }.';

-- The email status of 0005; "retryable" counts only emails a retry would send,
-- and each recent failed email says when its booking has outdated it ("outdated").
create or replace function public.booking_admin_email_status()
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
                 'oldestQueuedAt', booking.iso(min(o.created_at) filter (where o.status in ('pending', 'sending'))),
                 'failedLast7Days', count(*) filter (where o.status = 'failed' and o.created_at > now() - interval '7 days'),
                 'retryable', count(*) filter (where o.status = 'failed' and o.kind <> 'verification_code'
                                                 and o.created_at > now() - interval '23 hours'
                                                 and booking.outdated_email_reason(o.id, o.kind, o.booking_id, o.created_at) is null),
                 'sentLast24h', count(*) filter (where o.status = 'sent' and o.sent_at > now() - interval '1 day'),
                 'codesLast24h', count(*) filter (where o.kind = 'verification_code' and o.created_at > now() - interval '1 day'))
               from booking.email_outbox o),
    'recent', coalesce((
      select jsonb_agg(x.j order by x.created_at desc)
      from (
        select o.created_at, jsonb_build_object(
                 'id', o.id, 'kind', o.kind, 'status', o.status, 'recipient', booking.mask_email(o.recipient),
                 'attempts', o.attempts, 'createdAt', booking.iso(o.created_at), 'sentAt', booking.iso(o.sent_at),
                 'lastError', o.last_error,
                 -- A failed customer email its booking has outdated is not retried: why.
                 'outdated', case when o.status = 'failed'
                                  then booking.outdated_email_reason(o.id, o.kind, o.booking_id, o.created_at) end) as j
        from booking.email_outbox o
        order by o.created_at desc
        limit 20
      ) as x), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Searching every booking, page by page
-- ----------------------------------------------------------------------------

-- Does a booking match what the owner typed? Every word in its name, email,
-- reference, service or note; or, when the owner typed a phone number (only
-- digits and + ( ) . / - spaces, at least 3 digits), its phone number. p_digits
-- is empty for any other query, so "K7MP2X4Q" never matches a phone with 724.
create function booking.search_matches(b booking.bookings, p_words text[], p_digits text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (
    cardinality(p_words) > 0
    and not exists (
      select 1
      from unnest(p_words) as w(word)
      where strpos(lower(concat_ws(' ', b.customer_name, b.customer_email, b.reference, b.service_name, b.customer_notes)), w.word) = 0
    )
  ) or (
    char_length(coalesce(p_digits, '')) >= 3
    and b.customer_phone is not null
    and strpos(regexp_replace(b.customer_phone, '[^0-9]', '', 'g'), p_digits) > 0
  );
$$;
comment on function booking.search_matches(booking.bookings, text[], text) is
  'The dashboard search rule: every word in the name, email, reference, service or note; or, for a query that is a phone number (3+ digits), the phone number.';

-- p_after: null for the first page, then the `next` value of the page before
-- (opaque to callers). The first page fixes the boundary between upcoming and
-- past (the start of today in the business's time zone), so pages never skip
-- or repeat a booking while the owner reads them.
create function public.booking_admin_search_bookings(p_query text, p_after jsonb default null, p_limit int default 50)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_text text := lower(btrim(coalesce(p_query, '')));
  v_words text[];
  v_digits text;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_tz text;
  v_part text := 'upcoming';
  v_pivot timestamptz;
  v_at timestamptz;
  v_id uuid;
  v_bad boolean := false;
  v_upcoming uuid[] := '{}';
  v_past uuid[] := '{}';
  v_page uuid[] := '{}';
  v_need int;
  v_total int;
  v_next jsonb;
  v_last_at timestamptz;
begin
  perform booking.require_admin();
  if char_length(v_text) = 0 or char_length(v_text) > 100 then
    perform booking.raise_error('INVALID_INPUT', 'query');
  end if;
  select coalesce(array_agg(w.word), '{}') into v_words
  from regexp_split_to_table(v_text, '[[:space:]]+') as w(word)
  where w.word <> '';
  if cardinality(v_words) > 8 then
    perform booking.raise_error('INVALID_INPUT', 'query');
  end if;
  -- Phone numbers are searched only for a query that is one.
  v_digits := case when v_text ~ '^[0-9+()./[:space:]-]+$' then regexp_replace(v_text, '[^0-9]', '', 'g') else '' end;
  select s.timezone into v_tz from booking.settings s where s.id;

  if p_after is null then
    v_pivot := date_trunc('day', now() at time zone v_tz) at time zone v_tz;
  else
    begin
      v_part := p_after ->> 'part';
      v_pivot := (p_after ->> 'pivot')::timestamptz;
      v_at := (p_after ->> 'at')::timestamptz;
      v_id := (p_after ->> 'id')::uuid;
    exception when others then
      v_bad := true;
    end;
    if v_bad or jsonb_typeof(p_after) <> 'object' or v_part is null or v_part not in ('upcoming', 'past')
       or v_pivot is null or not isfinite(v_pivot) or (v_at is null) <> (v_id is null)
       or (v_at is not null and not isfinite(v_at)) or (v_part = 'upcoming' and v_at is null) then
      perform booking.raise_error('INVALID_INPUT', 'after');
    end if;
  end if;

  -- How many bookings match in all (first page only: the count costs a pass).
  if p_after is null then
    select count(*)::int into v_total
    from booking.bookings b
    where b.status <> 'unverified' and booking.search_matches(b, v_words, v_digits);
  end if;

  -- Upcoming (from the start of today), soonest first.
  if v_part = 'upcoming' then
    select coalesce(array_agg(x.id order by x.starts_at, x.id), '{}') into v_upcoming
    from (
      select b.id, b.starts_at
      from booking.bookings b
      where b.status <> 'unverified'
        and b.starts_at >= v_pivot
        and (v_at is null or (b.starts_at, b.id) > (v_at, v_id))
        and booking.search_matches(b, v_words, v_digits)
      order by b.starts_at, b.id
      limit v_limit + 1
    ) as x;
    if cardinality(v_upcoming) > v_limit then
      v_page := v_upcoming[1:v_limit];
      select b.starts_at into v_last_at from booking.bookings b where b.id = v_page[v_limit];
      v_next := jsonb_build_object('part', 'upcoming', 'pivot', to_jsonb(v_pivot), 'at', to_jsonb(v_last_at), 'id', v_page[v_limit]);
    else
      v_page := v_upcoming;
      -- The past part starts at the boundary.
      v_at := null;
      v_id := null;
    end if;
  end if;

  -- Then past bookings, most recent first (also when the page is full: one
  -- row is enough to know whether there is more).
  if v_next is null then
    v_need := v_limit - cardinality(v_page);
    select coalesce(array_agg(x.id order by x.starts_at desc, x.id desc), '{}') into v_past
    from (
      select b.id, b.starts_at
      from booking.bookings b
      where b.status <> 'unverified'
        and b.starts_at < v_pivot
        and (v_at is null or (b.starts_at, b.id) < (v_at, v_id))
        and booking.search_matches(b, v_words, v_digits)
      order by b.starts_at desc, b.id desc
      limit v_need + 1
    ) as x;
    if cardinality(v_past) > v_need then
      v_page := v_page || v_past[1:v_need];
      if v_need = 0 then
        v_next := jsonb_build_object('part', 'past', 'pivot', to_jsonb(v_pivot));
      else
        select b.starts_at into v_last_at from booking.bookings b where b.id = v_past[v_need];
        v_next := jsonb_build_object('part', 'past', 'pivot', to_jsonb(v_pivot), 'at', to_jsonb(v_last_at), 'id', v_past[v_need]);
      end if;
    else
      v_page := v_page || v_past;
    end if;
  end if;

  return jsonb_build_object(
    'bookings', coalesce((
      select jsonb_agg(booking.booking_json(b, v_tz) order by u.ord)
      from unnest(v_page) with ordinality as u(id, ord)
      join booking.bookings b on b.id = u.id
    ), '[]'::jsonb),
    'total', v_total,
    'next', v_next
  );
end;
$$;
comment on function public.booking_admin_search_bookings(text, jsonb, int) is
  'Admin only. Searches every booking (not unfinished requests) by name, email, reference, service, note or phone digits; pages of up to 100: upcoming soonest first, then past most recent first. total on the first page only; pass next back as p_after for the following page.';

-- ----------------------------------------------------------------------------
-- Privileges: new functions start with no access, then admins (signed in).
-- `create or replace` keeps the grants of the five replaced functions.
-- ----------------------------------------------------------------------------

revoke execute on all functions in schema booking from public;
revoke all on function
  booking.outdated_email_reason(uuid, text, uuid, timestamptz),
  booking.search_matches(booking.bookings, text[], text),
  public.booking_admin_search_bookings(text, jsonb, int)
from public, anon, authenticated, service_role;
grant execute on function
  booking.outdated_email_reason(uuid, text, uuid, timestamptz),
  booking.search_matches(booking.bookings, text[], text),
  public.booking_admin_search_bookings(text, jsonb, int)
to authenticated;

update booking.engine_info set schema_version = '2.0.0-beta.5', updated_at = now() where id;
