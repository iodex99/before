-- =============================================================================
-- BEFORE — 0001: extensions, enums, shared helpers
--
-- Enumerations are Postgres types rather than free text so that a typo in a
-- client becomes a write error instead of a silent second category that nobody
-- notices for six months.
--
-- Adding a value later: `alter type ... add value '...'` in a NEW migration.
-- Never edit this file once it has been applied anywhere.
-- =============================================================================

create extension if not exists "pgcrypto";      -- gen_random_uuid()
create extension if not exists "pg_trgm";       -- fuzzy matching on item names

-- -----------------------------------------------------------------------------
-- Domain enums. These mirror backend/shared/types.ts exactly.
-- -----------------------------------------------------------------------------

create type public.verdict as enum ('BUY', 'WAIT', 'BYE');

create type public.suggested_action as enum (
  'BUY_IT',
  'WAIT_48_HOURS',
  'CHECK_WARDROBE_FIRST',
  'WAIT_FOR_SALE',
  'SKIP_IT'
);

-- fashion and beauty ship now; the rest exist so stored rows stay valid when
-- those surfaces open up, without a migration on launch day.
create type public.product_category as enum (
  'fashion',
  'beauty',
  'accessory',
  'home',
  'travel',
  'gift',
  'other'
);

create type public.analysis_status as enum ('pending', 'processing', 'completed', 'failed');

create type public.input_type as enum ('photo', 'camera', 'screenshot', 'url', 'share_extension');

create type public.shopping_priority as enum (
  'style',
  'price',
  'quality',
  'versatility',
  'longevity',
  'trend',
  'sustainability'
);

create type public.style_preference as enum (
  'minimal',
  'classic',
  'feminine',
  'casual',
  'edgy',
  'romantic',
  'streetwear',
  'preppy',
  'bohemian',
  'sporty'
);

create type public.budget_sensitivity as enum ('low', 'medium', 'high');

create type public.shopping_focus as enum ('fashion', 'beauty', 'both');

create type public.outcome_action as enum ('bought', 'skipped', 'still_thinking');

create type public.satisfaction as enum ('love_it', 'good', 'fine', 'regret_it', 'returned');

create type public.saved_bucket as enum ('maybe', 'bought', 'owned');

create type public.signal_key as enum (
  'style_match',
  'wardrobe_compatibility',
  'duplication_risk',
  'expected_usage',
  'value_for_money',
  'budget_fit',
  'wardrobe_gap'
);

create type public.fact_source as enum ('confirmed', 'estimated', 'unknown');

create type public.subscription_status as enum (
  'active',
  'expired',
  'in_grace_period',
  'in_billing_retry',
  'revoked',
  'refunded'
);

create type public.store_environment as enum ('sandbox', 'production');

-- -----------------------------------------------------------------------------
-- Shared trigger: keep updated_at honest without trusting the client to send it
-- -----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Sets updated_at on UPDATE. Attach to every table with an updated_at column.';
