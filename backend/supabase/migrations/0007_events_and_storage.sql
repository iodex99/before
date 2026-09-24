-- =============================================================================
-- BEFORE — 0007: events, AI call log, storage
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Share events (spec §44)
-- -----------------------------------------------------------------------------

create table public.share_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  analysis_id uuid references public.analyses (id) on delete cascade,

  -- 'story' | 'standard'. The image itself is generated on-device and never
  -- uploaded — a share card is a picture of the user's shopping decision.
  card_style text not null default 'standard',
  destination text,
  completed boolean not null default false,

  created_at timestamptz not null default now(),

  constraint share_events_card_style_known check (card_style in ('story', 'standard'))
);

create index share_events_user_idx on public.share_events (user_id, created_at desc);

alter table public.share_events enable row level security;

create policy share_events_select_own on public.share_events
  for select using (auth.uid() = user_id);

create policy share_events_insert_own on public.share_events
  for insert with check (auth.uid() = user_id);

create policy share_events_delete_own on public.share_events
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Analytics events
--
-- Deliberately narrow columns. There is no free-form payload column, because a
-- free-form payload column is where raw images, URLs with tokens, and personal
-- history end up six months later (spec §43, §44).
-- -----------------------------------------------------------------------------

create table public.analytics_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users (id) on delete set null,

  name text not null,
  category public.product_category,
  verdict public.verdict,
  -- Bucketed, not exact: '0-59' | '60-79' | '80-100'.
  score_bucket text,
  input_type public.input_type,
  subscription_state text,

  created_at timestamptz not null default now(),

  constraint analytics_score_bucket_known check (
    score_bucket is null or score_bucket in ('0-59', '60-79', '80-100')
  ),
  constraint analytics_subscription_state_known check (
    subscription_state is null or subscription_state in ('free', 'plus')
  )
);

comment on table public.analytics_events is
  'Bucketed product analytics. No images, no URLs, no prices, no free-form payload.';

create index analytics_events_name_created_idx on public.analytics_events (name, created_at desc);

alter table public.analytics_events enable row level security;

create policy analytics_events_insert_own on public.analytics_events
  for insert with check (auth.uid() = user_id);

-- Deliberately no select policy: analytics are written by the client and read
-- only by the service role. Nobody queries another user's behaviour from a phone.

-- -----------------------------------------------------------------------------
-- AI call log (spec §51, §74)
--
-- Operational, not user-facing. Records what a call cost and how it failed.
-- Never records the prompt, the image, or the response.
-- -----------------------------------------------------------------------------

create table public.ai_call_log (
  id uuid primary key default gen_random_uuid(),
  analysis_id uuid references public.analyses (id) on delete set null,
  -- Not a foreign key: this log outlives a deleted account on purpose, so cost
  -- history survives. Nulled on account deletion rather than removed.
  user_id uuid,

  request_id text not null,
  provider text not null,
  model text not null,
  prompt_version text,

  input_tokens integer,
  output_tokens integer,
  estimated_cost_usd numeric(10, 6),
  latency_ms integer,

  success boolean not null,
  error_kind text,
  -- Count only. The offending text is not stored here.
  safety_findings smallint not null default 0,
  schema_warnings smallint not null default 0,
  retried boolean not null default false,

  created_at timestamptz not null default now()
);

create index ai_call_log_created_idx on public.ai_call_log (created_at desc);
create index ai_call_log_failures_idx on public.ai_call_log (created_at desc) where not success;

alter table public.ai_call_log enable row level security;
-- No policies. Service role only. Cost data is not user-facing (spec §51).

-- -----------------------------------------------------------------------------
-- Storage buckets
--
-- Both private. Reads go through short-lived signed URLs issued by the backend.
-- There is no public bucket in this project, by design.
-- -----------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('analyses', 'analyses', false, 6291456, array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  ('wardrobe', 'wardrobe', false, 6291456, array['image/jpeg', 'image/png', 'image/heic', 'image/webp'])
on conflict (id) do nothing;

-- Objects are namespaced by user id: `<user-uuid>/<file>`. The policies below
-- are what make that prefix meaningful rather than a convention.

create policy "analyses: read own objects"
  on storage.objects for select
  using (bucket_id = 'analyses' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "analyses: write own objects"
  on storage.objects for insert
  with check (bucket_id = 'analyses' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "analyses: delete own objects"
  on storage.objects for delete
  using (bucket_id = 'analyses' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "wardrobe: read own objects"
  on storage.objects for select
  using (bucket_id = 'wardrobe' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "wardrobe: write own objects"
  on storage.objects for insert
  with check (bucket_id = 'wardrobe' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "wardrobe: delete own objects"
  on storage.objects for delete
  using (bucket_id = 'wardrobe' and (storage.foldername(name))[1] = auth.uid()::text);
