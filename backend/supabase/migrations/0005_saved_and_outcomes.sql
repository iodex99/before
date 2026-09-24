-- =============================================================================
-- BEFORE — 0005: saved items and purchase outcomes
--
-- Outcomes are the only ground truth BEFORE ever gets. Everything else is the
-- model's opinion; "you bought it and regretted it" is a fact. The learning
-- loop is not built in MVP, but the data it will need is collected from day one
-- — retrofitting this later means a year of blind history.
-- =============================================================================

create table public.saved_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  analysis_id uuid references public.analyses (id) on delete cascade,

  bucket public.saved_bucket not null default 'maybe',
  note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One save per analysis per user; moving between buckets is an update.
  unique (user_id, analysis_id)
);

comment on table public.saved_items is 'The Maybe / Bought / Owned lists.';

create trigger saved_items_set_updated_at
  before update on public.saved_items
  for each row execute function public.set_updated_at();

create index saved_items_user_bucket_idx on public.saved_items (user_id, bucket, created_at desc);

alter table public.saved_items enable row level security;

create policy saved_items_select_own on public.saved_items
  for select using (auth.uid() = user_id);

create policy saved_items_insert_own on public.saved_items
  for insert with check (auth.uid() = user_id);

create policy saved_items_update_own on public.saved_items
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy saved_items_delete_own on public.saved_items
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Purchase outcomes
-- -----------------------------------------------------------------------------

create table public.purchase_outcomes (
  id uuid primary key default gen_random_uuid(),
  analysis_id uuid not null references public.analyses (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,

  action public.outcome_action not null,
  purchase_date date,
  actual_price numeric(12, 2),
  currency text,
  returned boolean not null default false,
  satisfaction public.satisfaction,
  notes text,

  -- When we may ask "how's it going?". Null until a follow-up is appropriate,
  -- and only ever acted on if notification permission was granted (spec §64).
  followup_due_at timestamptz,
  followup_sent_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (analysis_id),
  constraint outcomes_price_non_negative check (actual_price is null or actual_price >= 0),
  constraint outcomes_currency_iso4217 check (currency is null or currency ~ '^[A-Z]{3}$'),
  -- Only a purchase can be returned or rated.
  constraint outcomes_returned_implies_bought check (not returned or action = 'bought'),
  constraint outcomes_satisfaction_implies_bought check (satisfaction is null or action = 'bought')
);

create trigger purchase_outcomes_set_updated_at
  before update on public.purchase_outcomes
  for each row execute function public.set_updated_at();

create index purchase_outcomes_user_idx on public.purchase_outcomes (user_id, created_at desc);
create index purchase_outcomes_followup_idx on public.purchase_outcomes (followup_due_at)
  where followup_due_at is not null and followup_sent_at is null;

alter table public.purchase_outcomes enable row level security;

create policy purchase_outcomes_select_own on public.purchase_outcomes
  for select using (auth.uid() = user_id);

create policy purchase_outcomes_insert_own on public.purchase_outcomes
  for insert with check (auth.uid() = user_id);

create policy purchase_outcomes_update_own on public.purchase_outcomes
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy purchase_outcomes_delete_own on public.purchase_outcomes
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Potential spend avoided (spec §32)
--
-- Deliberately narrow. It counts ONLY the case where BEFORE said BYE and the
-- user then said they skipped it, using the price we actually had. It is not
-- "money you saved" and the view name is not allowed to drift into implying it.
-- -----------------------------------------------------------------------------

create or replace view public.potential_spend_avoided
with (security_invoker = true) as
select
  o.user_id,
  date_trunc('month', o.created_at) as month,
  p.currency,
  sum(coalesce(o.actual_price, p.price)) as amount,
  count(*) as item_count
from public.purchase_outcomes o
join public.analyses a on a.id = o.analysis_id
join public.analysis_products p on p.analysis_id = o.analysis_id
where o.action = 'skipped'
  and a.verdict = 'BYE'
  and coalesce(o.actual_price, p.price) is not null
group by o.user_id, date_trunc('month', o.created_at), p.currency;

comment on view public.potential_spend_avoided is
  'Items BEFORE advised skipping that the user then skipped. Surfaced as "potential spend avoided", never as guaranteed savings. security_invoker keeps each user inside their own RLS.';
