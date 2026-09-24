-- =============================================================================
-- BEFORE — 0003: wardrobe
--
-- Wardrobe memory is built up naturally, one answer at a time, after an
-- analysis ("do you own something similar?"). There is deliberately no bulk
-- import flow and no onboarding step that demands a closet inventory.
-- =============================================================================

create table public.wardrobe_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,

  -- Path inside the private `wardrobe` storage bucket. Never a public URL;
  -- the app is served short-lived signed URLs.
  image_path text,

  category public.product_category not null default 'fashion',
  subcategory text,
  color text,
  brand text,

  price numeric(12, 2),
  currency text,
  purchase_date date,

  -- 'analysis' when created from a "yes, I own something similar" answer,
  -- 'manual' when added directly.
  source text not null default 'manual',

  style_tags text[] not null default '{}',
  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint wardrobe_price_non_negative check (price is null or price >= 0),
  constraint wardrobe_currency_iso4217 check (currency is null or currency ~ '^[A-Z]{3}$'),
  -- A price without a currency cannot be formatted for anyone, so refuse it.
  constraint wardrobe_price_needs_currency check (price is null or currency is not null),
  constraint wardrobe_source_known check (source in ('manual', 'analysis', 'import')),
  constraint wardrobe_tag_count check (array_length(style_tags, 1) is null
                                       or array_length(style_tags, 1) <= 12)
);

comment on table public.wardrobe_items is
  'What the user owns. Built incrementally from analysis answers, never demanded up front.';

create trigger wardrobe_items_set_updated_at
  before update on public.wardrobe_items
  for each row execute function public.set_updated_at();

-- The relevance filter queries by (user, category, subcategory) on every
-- analysis, so that is the index it gets.
create index wardrobe_items_user_category_idx
  on public.wardrobe_items (user_id, category, subcategory);

create index wardrobe_items_user_created_idx
  on public.wardrobe_items (user_id, created_at desc);

create index wardrobe_items_style_tags_idx
  on public.wardrobe_items using gin (style_tags);

alter table public.wardrobe_items enable row level security;

create policy wardrobe_items_select_own on public.wardrobe_items
  for select using (auth.uid() = user_id);

create policy wardrobe_items_insert_own on public.wardrobe_items
  for insert with check (auth.uid() = user_id);

create policy wardrobe_items_update_own on public.wardrobe_items
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy wardrobe_items_delete_own on public.wardrobe_items
  for delete using (auth.uid() = user_id);
