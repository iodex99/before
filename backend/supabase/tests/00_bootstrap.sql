-- =============================================================================
-- BEFORE — Supabase-compatible bootstrap for a plain Postgres.
--
-- The migrations depend on things Supabase provides: the `auth` and `storage`
-- schemas, `auth.uid()`, and the `anon` / `authenticated` roles. This file
-- creates the minimum stand-in so the migrations can be applied and, more
-- importantly, so RLS can be exercised against a real database.
--
-- This is a TEST harness. It is never applied to a real environment — Supabase
-- already provides all of it, and `supabase db reset` skips this directory.
-- What it buys is a migration check that runs on any Postgres 15+ in about ten
-- seconds, with no Supabase CLI and no Docker-in-Docker.
-- =============================================================================

-- ---- Roles ------------------------------------------------------------------
-- RLS does not apply to superusers, so the functional tests connect as
-- `authenticated`. Without a genuinely unprivileged role, every policy test
-- would pass vacuously.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

-- ---- auth -------------------------------------------------------------------

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid,
  aud text,
  role text,
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

/**
 * Mirrors Supabase's own implementation: the current user id is read from the
 * request's JWT claims, which is what makes it settable per transaction.
 *
 *   set local request.jwt.claims = '{"sub": "<uuid>"}';
 *
 * Reading it any other way would make the RLS tests test the wrong thing.
 */
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
    ),
    ''
  )::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(current_setting('request.jwt.claim.role', true), 'authenticated');
$$;

-- ---- storage ----------------------------------------------------------------

create schema if not exists storage;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz not null default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table storage.objects enable row level security;

/**
 * Supabase splits an object name on '/' and returns everything except the
 * final segment, so `storage.foldername('uid/file.jpg')` is `{uid}`.
 *
 * The storage policies in migration 0007 index `[1]` to match the owning user's
 * prefix, so getting this wrong would make those policies silently pass or
 * silently fail. Worth stating precisely.
 */
create or replace function storage.foldername(name text)
returns text[]
language plpgsql
immutable
as $$
declare
  parts text[];
begin
  parts := string_to_array(name, '/');
  return parts[1:array_length(parts, 1) - 1];
end;
$$;

-- ---- Grants -----------------------------------------------------------------
-- Matches Supabase's defaults closely enough that the migrations behave the
-- same way. RLS still governs row visibility; these are table-level grants.

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema storage to anon, authenticated, service_role;

alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role;

grant all on all tables in schema storage to authenticated, service_role;
grant select on auth.users to authenticated, service_role;
