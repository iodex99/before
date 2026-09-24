-- =============================================================================
-- BEFORE — 0006: usage ledger and subscriptions
--
-- Two rules this file exists to enforce:
--   1. The quota is counted server-side. A client counter is a display, not a
--      limit (spec §33).
--   2. Entitlement is never a boolean the client can send. It is derived from
--      verified App Store transactions (spec §76).
-- =============================================================================

create table public.usage_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  analysis_id uuid references public.analyses (id) on delete set null,

  kind text not null default 'analysis',
  -- Recorded at consumption time so a later plan change never rewrites history.
  counted_against_free_quota boolean not null,

  created_at timestamptz not null default now(),

  constraint usage_ledger_kind_known check (kind in ('analysis', 'reanalysis'))
);

comment on table public.usage_ledger is
  'One row per consumed analysis. The authoritative source for the monthly quota.';

-- The quota query is always "this user, this month", so it gets a covering index.
create index usage_ledger_user_created_idx on public.usage_ledger (user_id, created_at desc);
create index usage_ledger_user_quota_idx on public.usage_ledger (user_id, created_at)
  where counted_against_free_quota;

alter table public.usage_ledger enable row level security;

-- Read-only to the owner. Rows are written by the edge function with the
-- service role: a client that could insert here could also not insert here.
create policy usage_ledger_select_own on public.usage_ledger
  for select using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Subscriptions
--
-- The client uses StoreKit entitlements for immediate UX. This table is the
-- authoritative record, reconciled from the App Store Server API and from
-- App Store Server Notifications V2.
-- -----------------------------------------------------------------------------

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,

  product_id text not null,
  -- Stable across renewals: the identity of the subscription itself.
  original_transaction_id text not null,
  transaction_id text,

  purchase_date timestamptz,
  expiration_date timestamptz,
  environment public.store_environment not null default 'production',
  status public.subscription_status not null,

  -- Ties an App Store transaction back to a BEFORE account. Derived from the
  -- user id via HMAC (APP_ACCOUNT_TOKEN_SECRET) so it is stable and reveals
  -- nothing if it leaks.
  app_account_token uuid,

  auto_renew_status boolean,
  revocation_date timestamptz,
  last_verified_at timestamptz not null default now(),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One row per subscription identity, per environment. Sandbox and production
  -- share an original_transaction_id space, so both belong in the key.
  unique (original_transaction_id, environment)
);

create trigger subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

create index subscriptions_user_idx on public.subscriptions (user_id, status);
create index subscriptions_app_account_token_idx on public.subscriptions (app_account_token)
  where app_account_token is not null;
create index subscriptions_expiration_idx on public.subscriptions (expiration_date)
  where status in ('active', 'in_grace_period', 'in_billing_retry');

alter table public.subscriptions enable row level security;

-- Read-only to the owner. Writes happen with the service role only: a client
-- that could write here could grant itself Plus.
create policy subscriptions_select_own on public.subscriptions
  for select using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Entitlement
--
-- One definition of "is this user Plus", used by every endpoint. A grace period
-- or billing retry still counts as entitled — Apple is retrying the charge and
-- cutting access off mid-retry is a bad experience for a billing hiccup.
-- -----------------------------------------------------------------------------

create or replace function public.is_plus(target_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.subscriptions s
    where s.user_id = target_user
      and s.status in ('active', 'in_grace_period', 'in_billing_retry')
      and (s.expiration_date is null or s.expiration_date > now())
      and s.revocation_date is null
  );
$$;

comment on function public.is_plus(uuid) is
  'Authoritative entitlement check. Derived from verified App Store transactions only — never from a client-supplied flag.';

-- -----------------------------------------------------------------------------
-- App Store Server Notifications V2 (spec §37)
--
-- Documented placeholder: the table and the endpoint contract exist, the
-- handler is a stub. Raw payloads are retained briefly for replay, then purged.
-- -----------------------------------------------------------------------------

create table public.app_store_notifications (
  id uuid primary key default gen_random_uuid(),
  notification_uuid text unique,
  notification_type text,
  subtype text,
  original_transaction_id text,
  environment public.store_environment,
  signed_payload text,
  processed_at timestamptz,
  processing_error text,
  received_at timestamptz not null default now()
);

create index app_store_notifications_unprocessed_idx on public.app_store_notifications (received_at)
  where processed_at is null;

alter table public.app_store_notifications enable row level security;
-- No policies. Service role only; no user ever reads this table.
