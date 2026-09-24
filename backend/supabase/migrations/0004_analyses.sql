-- =============================================================================
-- BEFORE — 0004: analyses
--
-- One analysis = one "should I buy this". Split across three tables:
--   analyses          the verdict, the score, and the versions it ran under
--   analysis_products what we believe the product is, and how sure we are
--   analysis_factors  the per-signal breakdown shown on the result screen
--
-- Two version columns are not optional. Without them, changing the prompt or
-- the weights silently redefines what every historical score meant.
-- =============================================================================

create table public.analyses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,

  status public.analysis_status not null default 'pending',
  input_type public.input_type not null,

  -- Path in the private `analyses` bucket. Null once a non-saved image has been
  -- cleaned up; the analysis itself survives its image.
  image_path text,
  source_url text,
  user_note text,

  -- Outputs. Null until status = 'completed'.
  score smallint,
  verdict public.verdict,
  suggested_action public.suggested_action,
  confidence numeric(4, 3),

  positive_factors text[] not null default '{}',
  negative_factors text[] not null default '{}',
  key_risk text,
  advice text,
  uncertainties text[] not null default '{}',

  -- Provenance. Every completed row records how it was produced.
  prompt_version text not null,
  score_algorithm_version text not null,
  ai_provider text,
  ai_model text,
  -- Deterministic rules that fired, e.g. {duplication_dominant_bye}.
  applied_rules text[] not null default '{}',

  failure_code text,

  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),

  constraint analyses_score_range check (score is null or (score >= 0 and score <= 100)),
  constraint analyses_confidence_range check (confidence is null or (confidence >= 0 and confidence <= 1)),
  -- A completed analysis must actually have an answer in it.
  constraint analyses_completed_has_outputs check (
    status <> 'completed'
    or (score is not null and verdict is not null and confidence is not null)
  ),
  constraint analyses_failed_has_reason check (status <> 'failed' or failure_code is not null),
  constraint analyses_reason_counts check (
    array_length(positive_factors, 1) is null or array_length(positive_factors, 1) <= 4
  )
);

comment on column public.analyses.score_algorithm_version is
  'The scoring version this row was computed under. Historical scores keep their meaning when weights change.';
comment on column public.analyses.applied_rules is
  'Audit trail of deterministic overrides. Explains why a 83 became a WAIT.';

create trigger analyses_set_updated_at
  before update on public.analyses
  for each row execute function public.set_updated_at();

create index analyses_user_created_idx on public.analyses (user_id, created_at desc);
create index analyses_user_verdict_idx on public.analyses (user_id, verdict, created_at desc);
-- Supports the in-flight concurrency check without a full scan.
create index analyses_user_status_idx on public.analyses (user_id, status)
  where status in ('pending', 'processing');

alter table public.analyses enable row level security;

create policy analyses_select_own on public.analyses
  for select using (auth.uid() = user_id);

create policy analyses_insert_own on public.analyses
  for insert with check (auth.uid() = user_id);

create policy analyses_update_own on public.analyses
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy analyses_delete_own on public.analyses
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- What we think the product is
-- -----------------------------------------------------------------------------

create table public.analysis_products (
  analysis_id uuid primary key references public.analyses (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,

  name text,
  brand text,
  category public.product_category not null default 'other',
  subcategory text,
  material text,
  retailer text,

  price numeric(12, 2),
  currency text,

  -- The URL the USER supplied. Never a model-generated link (Rule 6).
  product_url text,

  -- Per-field provenance: {"price": "confirmed", "brand": "unknown"}.
  -- This is what drives the "Price found on the product page" / "Estimated from
  -- image" / "Not confidently identified" chips (spec §25).
  fact_sources jsonb not null default '{}'::jsonb,

  price_confidence numeric(4, 3),
  identity_confidence numeric(4, 3),

  colors text[] not null default '{}',
  style_tags text[] not null default '{}',
  occasion_tags text[] not null default '{}',
  versatility_estimate smallint,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint analysis_products_price_non_negative check (price is null or price >= 0),
  constraint analysis_products_currency_iso4217 check (currency is null or currency ~ '^[A-Z]{3}$'),
  constraint analysis_products_confidences check (
    (price_confidence is null or (price_confidence >= 0 and price_confidence <= 1))
    and (identity_confidence is null or (identity_confidence >= 0 and identity_confidence <= 1))
  ),
  constraint analysis_products_fact_sources_is_object check (jsonb_typeof(fact_sources) = 'object')
);

create trigger analysis_products_set_updated_at
  before update on public.analysis_products
  for each row execute function public.set_updated_at();

create index analysis_products_user_category_idx
  on public.analysis_products (user_id, category, subcategory);

alter table public.analysis_products enable row level security;

create policy analysis_products_select_own on public.analysis_products
  for select using (auth.uid() = user_id);

create policy analysis_products_insert_own on public.analysis_products
  for insert with check (auth.uid() = user_id);

create policy analysis_products_update_own on public.analysis_products
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy analysis_products_delete_own on public.analysis_products
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- The factor breakdown
--
-- Excluded factors are stored too, with their reason. The result screen has to
-- be able to say "BEFORE doesn't know your wardrobe well enough yet" rather
-- than quietly showing six rows instead of seven.
-- -----------------------------------------------------------------------------

create table public.analysis_factors (
  id uuid primary key default gen_random_uuid(),
  analysis_id uuid not null references public.analyses (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,

  signal public.signal_key not null,
  -- 0..10 as displayed. Already inverted for duplication, so higher is always
  -- better on this column — the same direction as every other row in the UI.
  value numeric(4, 1) not null,
  -- Effective weight after redistribution, 0..1. Zero when excluded.
  weight numeric(5, 4) not null,
  included boolean not null,
  excluded_reason text,
  -- The raw 0..100 signal from the model, kept for offline evaluation.
  raw_signal smallint,

  created_at timestamptz not null default now(),

  constraint analysis_factors_value_range check (value >= 0 and value <= 10),
  constraint analysis_factors_weight_range check (weight >= 0 and weight <= 1),
  constraint analysis_factors_excluded_has_reason check (included or excluded_reason is not null),
  unique (analysis_id, signal)
);

create index analysis_factors_analysis_idx on public.analysis_factors (analysis_id);

alter table public.analysis_factors enable row level security;

create policy analysis_factors_select_own on public.analysis_factors
  for select using (auth.uid() = user_id);

create policy analysis_factors_insert_own on public.analysis_factors
  for insert with check (auth.uid() = user_id);

create policy analysis_factors_delete_own on public.analysis_factors
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Idempotency (spec §50)
--
-- The client sends Idempotency-Key. A repeat of the same key returns the
-- existing analysis instead of spending another AI call and another quota unit
-- because someone double-tapped.
-- -----------------------------------------------------------------------------

create table public.idempotency_keys (
  user_id uuid not null references public.users (id) on delete cascade,
  key text not null,
  analysis_id uuid references public.analyses (id) on delete cascade,
  -- Hash of the request body. A repeated key with different content is a client
  -- bug and must be rejected, not silently answered with the wrong analysis.
  request_hash text not null,
  created_at timestamptz not null default now(),

  primary key (user_id, key)
);

create index idempotency_keys_created_idx on public.idempotency_keys (created_at);

alter table public.idempotency_keys enable row level security;

create policy idempotency_keys_select_own on public.idempotency_keys
  for select using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Product metadata cache (spec §51, cost control)
--
-- Two users checking the same product page should not cause two fetches. Keyed
-- by normalised URL and holds no user data, so it is service-role only.
-- -----------------------------------------------------------------------------

create table public.product_metadata_cache (
  url text primary key,
  title text,
  brand text,
  price numeric(12, 2),
  currency text,
  availability text,
  image_url text,
  retailer text,
  structured boolean not null default false,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);

create index product_metadata_cache_expires_idx on public.product_metadata_cache (expires_at);

alter table public.product_metadata_cache enable row level security;
-- No policies: this table is reachable only with the service role, from inside
-- an edge function. RLS on with zero policies denies every client by default.
