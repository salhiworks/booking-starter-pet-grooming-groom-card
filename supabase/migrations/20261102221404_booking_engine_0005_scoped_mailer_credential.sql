-- ============================================================================
-- Profit Studio Booking Engine — migration 0005_scoped_mailer_credential
-- Engine schema version: 2.0.0-alpha.5
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Phase 2C hardening (docs/adr/0003-scoped-mailer-credential.md):
--   1. The database starts the booking-mailer with a MAILER-ONLY token instead
--      of a Supabase secret key. The token lives in the private table
--      booking.mailer_config; the function compares it in constant time. It can
--      only start the mailer, which can only send emails the database queued.
--      No Supabase key is stored in the database any more (Vault not needed).
--   2. Each start of the mailer is recorded, so the dashboard can show the
--      last result (e.g. HTTP 401 = the token does not match the function).
--   3. Owners can retry emails that failed in the last 23 hours (inside
--      Resend's 24-hour idempotency window: a retry never duplicates).
--
-- After upgrading: run the new `npx booking-engine mailer-sql` once, set the
-- Edge Function secret BOOKING_MAILER_TOKEN, redeploy booking-mailer, and
-- delete the `booking_mailer` secret key alpha.4 asked for (see CHANGELOG).
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.4' then
    raise exception 'Booking Engine 0005_scoped_mailer_credential expects schema 2.0.0-alpha.4, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Schema
-- ----------------------------------------------------------------------------

create table booking.mailer_config (
  id boolean primary key default true check (id),
  function_url text check (function_url is null or char_length(function_url) <= 300),
  -- 64 hex characters from the CSPRNG behind gen_random_uuid().
  token text not null default encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex'),
  token_created_at timestamptz not null default now(),
  configured_at timestamptz
);
insert into booking.mailer_config default values;
comment on table booking.mailer_config is
  'Where the booking-mailer Edge Function is, and the mailer-only token it accepts (Edge Function secret BOOKING_MAILER_TOKEN). The token can only start the mailer. Never readable through the API.';

create table booking.mailer_starts (
  request_id bigint primary key,
  started_at timestamptz not null default now()
);
comment on table booking.mailer_starts is
  'One row per pg_net request that started the mailer (its id in net._http_response); kept one day, for the dashboard''s "last start" result.';

-- ----------------------------------------------------------------------------
-- Owner setup (SQL Editor only — not executable by any API role)
-- ----------------------------------------------------------------------------

-- Store the function address and return the token to copy into the Edge
-- Function secret BOOKING_MAILER_TOKEN. Safe to run again: the token stays the
-- same unless p_rotate is true (then update the secret too).
create function booking.configure_mailer(p_function_url text, p_rotate boolean default false)
returns table (booking_mailer_token text, setup_check text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_url text := btrim(coalesce(p_function_url, ''));
  w jsonb;
  v_missing text[] := '{}';
begin
  if v_url !~ '^https://[^[:space:]/]+(/[^[:space:]]*)?$'
     and v_url !~ '^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/[^[:space:]]*)?$' then
    raise exception 'Give the function address, e.g. https://<project-ref>.supabase.co/functions/v1/booking-mailer';
  end if;
  update booking.mailer_config
     set function_url = v_url,
         configured_at = now(),
         token = case when coalesce(p_rotate, false)
                      then encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex') else token end,
         token_created_at = case when coalesce(p_rotate, false) then now() else token_created_at end
   where id;
  w := booking.mailer_wiring();
  if not (w ->> 'pgNet')::boolean then v_missing := v_missing || 'the pg_net extension'::text; end if;
  if not (w ->> 'schedule')::boolean then v_missing := v_missing || 'the every-minute job (cron.schedule)'::text; end if;
  return query
    select c.token,
           case when cardinality(v_missing) = 0
                then 'OK — now add this token as the Edge Function secret BOOKING_MAILER_TOKEN, then send a test email from the dashboard.'
                else 'Missing: ' || array_to_string(v_missing, ', ') || '. Run the whole mailer-sql output.' end
    from booking.mailer_config c where c.id;
end;
$$;
comment on function booking.configure_mailer(text, boolean) is
  'Owner only (SQL Editor). Stores the booking-mailer address and returns the mailer token for the Edge Function secret BOOKING_MAILER_TOKEN; p_rotate => true issues a new token.';

-- ----------------------------------------------------------------------------
-- Starting the mailer with the scoped token
-- ----------------------------------------------------------------------------

-- Never raises (it runs inside the transaction that queued an email): a
-- wiring problem must not block a booking. At most once per transaction.
create or replace function booking.kick_mailer()
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_token text;
  v_id bigint;
begin
  if coalesce(current_setting('booking_engine.mailer_kicked', true), '') = 'on' then
    return false;
  end if;
  begin
    select c.function_url, c.token into v_url, v_token from booking.mailer_config c where c.id;
    if v_url is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
      return false;
    end if;
    execute 'select net.http_post(url => $1, body => $2, params => $3, headers => $4, timeout_milliseconds => $5)'
      into v_id
      using v_url, '{}'::jsonb, '{}'::jsonb,
            jsonb_build_object('Content-Type', 'application/json', 'x-booking-mailer-token', v_token), 30000;
    insert into booking.mailer_starts (request_id) values (v_id) on conflict (request_id) do nothing;
  exception when others then
    return false;
  end;
  perform set_config('booking_engine.mailer_kicked', 'on', true);
  return true;
end;
$$;
comment on function booking.kick_mailer() is
  'PRIVILEGED (SECURITY DEFINER), private schema. Starts the booking-mailer Edge Function through pg_net with the mailer-only token (header x-booking-mailer-token). Never raises.';

-- Is automatic sending wired up, and how did the last start go? Booleans and
-- an HTTP status only; never the token or the address.
create or replace function booking.mailer_wiring()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_configured boolean;
  v_schedule boolean := false;
  v_net boolean := false;
  v_start booking.mailer_starts%rowtype;
  v_status int;
  v_error text;
  v_last jsonb := null;
begin
  select c.function_url is not null into v_configured from booking.mailer_config c where c.id;
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
  select * into v_start from booking.mailer_starts s order by s.started_at desc, s.request_id desc limit 1;
  if found then
    begin
      if to_regclass('net._http_response') is not null then
        execute 'select r.status_code, r.error_msg from net._http_response r where r.id = $1'
          into v_status, v_error
          using v_start.request_id;
      end if;
    exception when others then
      v_status := null;
      v_error := null;
    end;
    v_last := jsonb_build_object(
      'at', booking.iso(v_start.started_at),
      'status', v_status,
      'error', left(v_error, 200)
    );
  end if;
  return jsonb_build_object('pgNet', v_net, 'configured', coalesce(v_configured, false), 'schedule', v_schedule, 'lastStart', v_last);
end;
$$;

-- Retention for the start log, with the rest of the housekeeping.
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
  delete from booking.mailer_starts s where s.started_at < now() - interval '1 day';

  return jsonb_build_object('released', v_released, 'withdrawn', v_withdrawn);
end;
$$;

-- ----------------------------------------------------------------------------
-- Admin: delivery health incl. the oldest waiting email; retry failed emails
-- ----------------------------------------------------------------------------

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
                                                 and o.created_at > now() - interval '23 hours'),
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

-- Failed emails from the last 23 hours go back into the queue (codes are not
-- retried: they have expired). Resend keeps an idempotency key for 24 hours,
-- so an email whose first attempt did reach Resend is not sent twice.
create function public.booking_admin_retry_failed_emails()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  n int;
begin
  perform booking.require_admin();
  update booking.email_outbox o
     set status = 'pending', attempts = 0, next_attempt_at = now(), locked_until = null, last_error = null
   where o.status = 'failed'
     and o.kind <> 'verification_code'
     and o.created_at > now() - interval '23 hours';
  get diagnostics n = row_count;
  return jsonb_build_object('requeued', n);
end;
$$;
comment on function public.booking_admin_retry_failed_emails() is
  'Admin only. Puts emails that failed in the last 23 hours back in the queue (the every-minute job sends them; idempotent within Resend''s 24-hour window).';

-- ----------------------------------------------------------------------------
-- Obsolete alpha.4 wiring: the Vault entries held a full Supabase secret key.
-- Remove them where possible (the key itself must be deleted in the dashboard).
-- ----------------------------------------------------------------------------

do $$
begin
  if to_regclass('vault.secrets') is not null then
    execute 'delete from vault.secrets where name in (''booking_engine_mailer_url'', ''booking_engine_mailer_key'')';
  end if;
exception when others then
  raise notice 'Booking Engine: could not remove the old booking_engine_mailer_* Vault secrets (%). Delete them in the dashboard.', sqlerrm;
end
$$;

-- ----------------------------------------------------------------------------
-- RLS and privileges
-- ----------------------------------------------------------------------------

alter table booking.mailer_config enable row level security;
alter table booking.mailer_starts enable row level security;
create policy mailer_config_no_api_access on booking.mailer_config
  for all to anon, authenticated using (false) with check (false);
create policy mailer_starts_no_api_access on booking.mailer_starts
  for all to anon, authenticated using (false) with check (false);
create policy email_outbox_admin_retry on booking.email_outbox
  for update to authenticated using ((select booking.is_admin())) with check ((select booking.is_admin()));

revoke all on booking.mailer_config, booking.mailer_starts from public, anon, authenticated, service_role;
grant update (status, attempts, next_attempt_at, locked_until, last_error) on booking.email_outbox to authenticated;

revoke execute on all functions in schema booking from public;
revoke all on function
  booking.configure_mailer(text, boolean),
  public.booking_admin_retry_failed_emails()
from public, anon, authenticated, service_role;
grant execute on function public.booking_admin_retry_failed_emails() to authenticated;

update booking.engine_info set schema_version = '2.0.0-alpha.5', updated_at = now() where id;
