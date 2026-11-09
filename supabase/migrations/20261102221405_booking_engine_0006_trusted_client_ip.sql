-- ============================================================================
-- Profit Studio Booking Engine — migration 0006_trusted_client_ip
-- Engine schema version: 2.0.0-alpha.6
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Security patch (verified need: hosted run of 2026-11-01, docs/SECURITY.md §3).
-- A client's address for per-client limits now comes ONLY from the header the
-- platform's edge sets: `cf-connecting-ip` (Cloudflare, in front of every
-- hosted Supabase project, refuses requests that send their own). `x-real-ip`
-- and `x-forwarded-for` are never used any more: on hosted Supabase the first
-- `x-forwarded-for` entry is whatever the client sent. Without a usable
-- `cf-connecting-ip` the request falls into the shared `unknown` bucket, which
-- the site-wide hourly cap limits — fail-closed: no header a client controls
-- can open a fresh bucket.
--
-- Same function signatures; no data change; nothing to do after upgrading.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.5' then
    raise exception 'Booking Engine 0006_trusted_client_ip expects schema 2.0.0-alpha.5, found %', coalesce(v, 'none');
  end if;
end
$$;

-- The client's address as set by the platform's edge, or null.
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
  -- Only the edge's header. Never x-real-ip or x-forwarded-for: a client can write those.
  return left(nullif(btrim(h ->> 'cf-connecting-ip'), ''), 64);
end;
$$;
comment on function booking.client_ip() is
  'The client address from cf-connecting-ip (set by the platform edge; clients cannot send it). Null when absent: the caller then shares the unknown bucket.';

update booking.engine_info set schema_version = '2.0.0-alpha.6', updated_at = now() where id;
