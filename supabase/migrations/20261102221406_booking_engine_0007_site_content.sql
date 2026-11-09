-- ============================================================================
-- Profit Studio Booking Engine — migration 0007_site_content
-- Engine schema version: 2.0.0-alpha.7
--
-- ENGINE-OWNED FILE. Do not edit. `booking-engine doctor` reports changes.
--
-- Owner customization (Phase 3, docs/adr/0004-site-content.md):
--   1. Website content the owner edits in the dashboard: one document of
--      values keyed by field id. Each website declares its own fields (with
--      types and defaults) in its code; the engine stores values only, so every
--      AI-generated site keeps its own design.
--   2. A draft and a published copy: visitors only ever read the published
--      one; signed-in admins can preview the draft before publishing.
--   3. Images in the Supabase Storage bucket `booking-site-media`: public to
--      read, uploaded and deleted by admins only; images only, 5 MB at most.
--
-- No booking, customer or settings data changes.
-- ============================================================================

do $$
declare
  v text;
begin
  select e.schema_version into v from booking.engine_info e where e.id;
  if v is distinct from '2.0.0-alpha.6' then
    raise exception 'Booking Engine 0007_site_content expects schema 2.0.0-alpha.6, found %', coalesce(v, 'none');
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Schema
-- ----------------------------------------------------------------------------

create table booking.site_content (
  id boolean primary key default true check (id),
  draft jsonb not null default '{}'::jsonb check (jsonb_typeof(draft) = 'object'),
  published jsonb not null default '{}'::jsonb check (jsonb_typeof(published) = 'object'),
  draft_revision integer not null default 0,
  published_version integer not null default 0,
  draft_updated_at timestamptz,
  published_at timestamptz,
  updated_by uuid
);
insert into booking.site_content default values;
comment on table booking.site_content is
  'Website content values (field id → value) edited in the dashboard. Visitors read only `published`; `draft` is for signed-in admins (preview). Field definitions live in each website''s code.';

-- ----------------------------------------------------------------------------
-- Validation. Generic on purpose: the website's own schema (types, lengths,
-- links, colours) is checked by the dashboard and again when the website reads
-- the values. The database guarantees shapes and sizes only.
-- ----------------------------------------------------------------------------

-- An image value: { path, alt, width?, height? }, path inside the media bucket.
create function booking.site_image_ok(p_image jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_image) = 'object'
     and not exists (select 1 from jsonb_object_keys(p_image) k where k not in ('path', 'alt', 'width', 'height'))
     and jsonb_typeof(p_image -> 'path') = 'string'
     and (p_image ->> 'path') ~ '^site/[a-z0-9][a-z0-9._-]{0,120}$'
     and position('..' in (p_image ->> 'path')) = 0
     and coalesce(jsonb_typeof(p_image -> 'alt'), 'string') = 'string'
     and char_length(coalesce(p_image ->> 'alt', '')) <= 300
     and coalesce(jsonb_typeof(p_image -> 'width'), 'number') = 'number'
     and coalesce(jsonb_typeof(p_image -> 'height'), 'number') = 'number';
$$;

-- A value: text (≤ 5000 characters, no control characters except line breaks
-- and tabs), true/false, null, an image, or — at the top level only — a list
-- of up to 50 items, each with up to 20 such values.
create function booking.site_content_value_ok(p_value jsonb, p_allow_list boolean)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_item jsonb;
  v_key text;
  v_inner jsonb;
  v_count integer;
begin
  case jsonb_typeof(p_value)
    when 'string' then
      return char_length(p_value #>> '{}') <= 5000
         and (p_value #>> '{}') !~ '[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]';
    when 'boolean', 'null' then
      return true;
    when 'object' then
      return booking.site_image_ok(p_value);
    when 'array' then
      if not p_allow_list or jsonb_array_length(p_value) > 50 then
        return false;
      end if;
      for v_item in select e from jsonb_array_elements(p_value) e loop
        if jsonb_typeof(v_item) <> 'object' then
          return false;
        end if;
        v_count := 0;
        for v_key, v_inner in select k, v from jsonb_each(v_item) as t(k, v) loop
          v_count := v_count + 1;
          if v_count > 20 or v_key !~ '^[a-zA-Z][a-zA-Z0-9_]{0,31}$' or not booking.site_content_value_ok(v_inner, false) then
            return false;
          end if;
        end loop;
      end loop;
      return true;
    else
      return false;
  end case;
end;
$$;

-- Null when the document is valid; otherwise the offending field id.
create function booking.site_content_problem(p_values jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text;
  v_value jsonb;
  v_count integer := 0;
begin
  if p_values is null or jsonb_typeof(p_values) <> 'object' or octet_length(p_values::text) > 200000 then
    return 'values';
  end if;
  for v_key, v_value in select k, v from jsonb_each(p_values) as t(k, v) loop
    v_count := v_count + 1;
    if v_count > 300
       or char_length(v_key) > 64
       or v_key !~ '^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9_-]+){0,4}$'
       or not booking.site_content_value_ok(v_value, true) then
      return v_key;
    end if;
  end loop;
  return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- Public read: the published copy only (never the draft).
-- ----------------------------------------------------------------------------

create function booking.published_site_content()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'version', c.published_version,
    'publishedAt', booking.iso(c.published_at),
    'values', c.published)
  from booking.site_content c
  where c.id;
$$;

create function public.booking_get_site_content()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select booking.published_site_content();
$$;
comment on function public.booking_get_site_content() is
  'Published website content: { version, publishedAt, values }. Contains only what the owner published; no booking or customer data.';

-- ----------------------------------------------------------------------------
-- Admin: read both copies, save the draft, publish, discard.
-- ----------------------------------------------------------------------------

create function booking.site_content_json(c booking.site_content)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'draft', c.draft,
    'published', c.published,
    'draftRevision', c.draft_revision,
    'version', c.published_version,
    'draftUpdatedAt', booking.iso(c.draft_updated_at),
    'publishedAt', booking.iso(c.published_at),
    'hasUnpublishedChanges', c.draft is distinct from c.published);
$$;

create function public.booking_admin_get_site_content()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  c booking.site_content;
begin
  perform booking.require_admin();
  select * into c from booking.site_content s where s.id;
  return booking.site_content_json(c);
end;
$$;

-- Saves the whole draft. p_base_revision is the draftRevision the editor
-- started from: another admin's newer save is never overwritten (CONFLICT).
create function public.booking_admin_save_site_content(p_values jsonb, p_base_revision integer)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := booking.require_admin();
  v_problem text := booking.site_content_problem(p_values);
  c booking.site_content;
begin
  if v_problem is not null then
    perform booking.raise_error('INVALID_INPUT', v_problem);
  end if;
  update booking.site_content s
     set draft = p_values,
         draft_revision = s.draft_revision + 1,
         draft_updated_at = now(),
         updated_by = v_uid
   where s.id and s.draft_revision = coalesce(p_base_revision, s.draft_revision)
  returning * into c;
  if not found then
    perform booking.raise_error('CONFLICT', 'draftRevision');
  end if;
  return booking.site_content_json(c);
end;
$$;

-- The draft becomes what visitors see.
create function public.booking_admin_publish_site_content(p_base_revision integer)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := booking.require_admin();
  c booking.site_content;
begin
  update booking.site_content s
     set published = s.draft,
         published_version = s.published_version + 1,
         published_at = now(),
         updated_by = v_uid
   where s.id and s.draft_revision = coalesce(p_base_revision, s.draft_revision)
  returning * into c;
  if not found then
    perform booking.raise_error('CONFLICT', 'draftRevision');
  end if;
  return booking.site_content_json(c);
end;
$$;

-- The draft goes back to what is published.
create function public.booking_admin_discard_site_content_draft()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := booking.require_admin();
  c booking.site_content;
begin
  update booking.site_content s
     set draft = s.published,
         draft_revision = s.draft_revision + 1,
         draft_updated_at = now(),
         updated_by = v_uid
   where s.id
  returning * into c;
  return booking.site_content_json(c);
end;
$$;

-- ----------------------------------------------------------------------------
-- Media: a public Storage bucket that only admins can write to.
-- Skipped (with a notice) in databases without Supabase Storage.
-- ----------------------------------------------------------------------------

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice 'Booking Engine 0007: no Supabase Storage here; website images stay unavailable until it exists.';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('booking-site-media', 'booking-site-media', true, 5242880,
          array['image/jpeg', 'image/png', 'image/webp', 'image/avif'])
  on conflict (id) do update
    set public = true,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;
  -- Reading files needs no policy (public bucket, public URLs). Listing,
  -- uploading and deleting are for admins only. No update policy: files are
  -- never overwritten — a replacement is a new file with a new name.
  execute $policy$
    create policy booking_site_media_admin_read on storage.objects
      for select to authenticated
      using (bucket_id = 'booking-site-media' and (select booking.is_admin()))
  $policy$;
  execute $policy$
    create policy booking_site_media_admin_insert on storage.objects
      for insert to authenticated
      with check (bucket_id = 'booking-site-media' and (select booking.is_admin()))
  $policy$;
  execute $policy$
    create policy booking_site_media_admin_delete on storage.objects
      for delete to authenticated
      using (bucket_id = 'booking-site-media' and (select booking.is_admin()))
  $policy$;
end
$$;

-- ----------------------------------------------------------------------------
-- RLS and privileges
-- ----------------------------------------------------------------------------

alter table booking.site_content enable row level security;
create policy site_content_admin_read on booking.site_content
  for select to authenticated using ((select booking.is_admin()));
create policy site_content_admin_update on booking.site_content
  for update to authenticated using ((select booking.is_admin())) with check ((select booking.is_admin()));

revoke all on booking.site_content from public, anon, authenticated, service_role;
grant select on booking.site_content to authenticated;
grant update (draft, published, draft_revision, published_version, draft_updated_at, published_at, updated_by)
  on booking.site_content to authenticated;

revoke execute on all functions in schema booking from public;
revoke all on function
  booking.site_image_ok(jsonb),
  booking.site_content_value_ok(jsonb, boolean),
  booking.site_content_problem(jsonb),
  booking.published_site_content(),
  booking.site_content_json(booking.site_content),
  public.booking_get_site_content(),
  public.booking_admin_get_site_content(),
  public.booking_admin_save_site_content(jsonb, integer),
  public.booking_admin_publish_site_content(integer),
  public.booking_admin_discard_site_content_draft()
from public, anon, authenticated, service_role;

-- Visitors: the published copy.
grant execute on function
  public.booking_get_site_content(),
  booking.published_site_content()
to anon, authenticated;

-- Admins.
grant execute on function
  public.booking_admin_get_site_content(),
  public.booking_admin_save_site_content(jsonb, integer),
  public.booking_admin_publish_site_content(integer),
  public.booking_admin_discard_site_content_draft(),
  booking.site_content_json(booking.site_content),
  booking.site_content_problem(jsonb),
  booking.site_content_value_ok(jsonb, boolean),
  booking.site_image_ok(jsonb)
to authenticated;

update booking.engine_info set schema_version = '2.0.0-alpha.7', updated_at = now() where id;
