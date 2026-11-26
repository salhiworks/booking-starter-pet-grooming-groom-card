-- ============================================================================
-- Profit Studio Booking Engine — migration 0012_component_versions
-- Engine schema version: 2.0.0-beta.5
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Which mailer is deployed (the dashboard's Software updates). Additive only:
-- two nullable columns, one function for the mailer, and the email status
-- replaced with the same signature (its grants are kept). No row changes
-- when this migration runs.
--
--   1. booking.mailer_state gains mailer_revision and mailer_revision_at: the
--      code revision the deployed booking-mailer reports at the start of each
--      run (a digest of its own files, written by the engine's build — the
--      same value as package.json → bookingEngine.functions["booking-mailer"]).
--      It identifies code, not a person, a key or a project.
--   2. public.booking_mailer_hello(p_revision): the mailer (service_role
--      only) reports it. It writes only when the revision changed or an hour
--      has passed, so the every-minute run does not rewrite the row.
--   3. public.booking_admin_email_status() also returns mailer.revision and
--      mailer.revisionAt (admins only, as before). The dashboard compares the
--      revision with the one its own engine ships: the same, different (the
--      mailer needs redeploying, or the website rebuilding), or unknown (a
--      mailer from before 2.0.0-beta.5, which never reports one).
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-beta.5'
     or to_regprocedure('public.booking_admin_search_bookings(text, jsonb, integer)') is null then
    raise exception 'Booking Engine 0012_component_versions expects schema 2.0.0-beta.5 with 0011 applied, found %', coalesce(v, 'none');
  end if;
  -- 0010, 0011 and 0012 share the schema label: the new function tells a second run.
  if to_regprocedure('public.booking_mailer_hello(text)') is not null then
    raise exception 'Booking Engine 0012_component_versions has already been applied to this database';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Where the deployed mailer's revision is kept
-- ----------------------------------------------------------------------------

alter table booking.mailer_state
  add column mailer_revision text check (mailer_revision ~ '^[0-9a-f]{64}$'),
  add column mailer_revision_at timestamptz;
comment on column booking.mailer_state.mailer_revision is
  'The code revision (sha256 of its files) the deployed booking-mailer last reported; null before a 2.0.0-beta.5 mailer has run.';
comment on column booking.mailer_state.mailer_revision_at is 'When the deployed booking-mailer last reported its revision (refreshed hourly at most).';

-- ----------------------------------------------------------------------------
-- 2. The mailer reports it
-- ----------------------------------------------------------------------------

create function public.booking_mailer_hello(p_revision text)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if p_revision is null or p_revision !~ '^[0-9a-f]{64}$' then
    raise exception 'A mailer revision is a 64-character lowercase hex digest' using errcode = '22023';
  end if;
  update booking.mailer_state
     set mailer_revision = p_revision, mailer_revision_at = now()
   where id
     and (mailer_revision is distinct from p_revision
          or mailer_revision_at is null
          or mailer_revision_at < now() - interval '1 hour');
end;
$$;
comment on function public.booking_mailer_hello(text) is
  'service_role only (booking-mailer, from 2.0.0-beta.5). Records the code revision of the deployed mailer, for the dashboard''s Software updates.';

-- ----------------------------------------------------------------------------
-- 3. The email status says which mailer is deployed
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
                 'lastError', m.last_error,
                 -- 0012: the code revision the deployed mailer reported (null: a mailer older
                 -- than 2.0.0-beta.5, or none has run since this migration).
                 'revision', m.mailer_revision,
                 'revisionAt', booking.iso(m.mailer_revision_at))
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
-- Privileges: the new function starts with no access, then the mailer.
-- `create or replace` keeps the grants of the replaced email status.
-- ----------------------------------------------------------------------------

revoke all on function public.booking_mailer_hello(text) from public, anon, authenticated, service_role;
grant execute on function public.booking_mailer_hello(text) to service_role;

update booking.engine_info set schema_version = '2.0.0-beta.5', updated_at = now() where id;
