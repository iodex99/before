-- =============================================================================
-- BEFORE — 0002: users and preferences
--
-- auth.users is the identity (Sign in with Apple). public.users is the profile.
-- We deliberately store the minimum: no email is copied here, no Apple
-- credential is stored by us, and no marketing fields exist.
-- =============================================================================

create table public.users (
  id uuid primary key references auth.users (id) on delete cascade,

  -- Apple only gives a name on FIRST authorisation, and only if the user allows
  -- it. Both of these are legitimately null forever.
  display_name text,
  preferred_name text,

  -- Locale settings come from the device and drive currency and date
  -- formatting. Never hard-coded to USD anywhere (spec §3).
  locale text not null default 'en-US',
  currency text not null default 'USD',
  timezone text not null default 'UTC',

  onboarding_completed_at timestamptz,
  deleted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint users_currency_is_iso4217 check (currency ~ '^[A-Z]{3}$'),
  constraint users_locale_shape check (locale ~ '^[a-zA-Z]{2,3}([-_][a-zA-Z0-9]{2,8})*$')
);

comment on table public.users is 'BEFORE profile, 1:1 with auth.users.';
comment on column public.users.deleted_at is
  'Set by account-delete immediately before the cascade runs, so an interrupted deletion is still visible as intent.';

create trigger users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

alter table public.users enable row level security;

create policy users_select_own on public.users
  for select using (auth.uid() = id);

create policy users_insert_own on public.users
  for insert with check (auth.uid() = id);

create policy users_update_own on public.users
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- No delete policy: account deletion runs through the account-delete edge
-- function so storage objects are removed in the same operation. A client
-- cannot delete its own row directly and leave orphaned images behind.

-- -----------------------------------------------------------------------------
-- Preferences — the answers from onboarding, all optional
-- -----------------------------------------------------------------------------

create table public.user_preferences (
  user_id uuid primary key references public.users (id) on delete cascade,

  shopping_priorities public.shopping_priority[] not null default '{}',
  favorite_styles public.style_preference[] not null default '{}',
  budget_sensitivity public.budget_sensitivity not null default 'medium',
  shopping_focus public.shopping_focus not null default 'both',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Spec §7: "choose up to 3". Enforced here so the rule survives a client bug.
  constraint prefs_max_three_priorities check (array_length(shopping_priorities, 1) is null
                                               or array_length(shopping_priorities, 1) <= 3),
  constraint prefs_max_five_styles check (array_length(favorite_styles, 1) is null
                                          or array_length(favorite_styles, 1) <= 5)
);

create trigger user_preferences_set_updated_at
  before update on public.user_preferences
  for each row execute function public.set_updated_at();

alter table public.user_preferences enable row level security;

create policy user_preferences_select_own on public.user_preferences
  for select using (auth.uid() = user_id);

create policy user_preferences_insert_own on public.user_preferences
  for insert with check (auth.uid() = user_id);

create policy user_preferences_update_own on public.user_preferences
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy user_preferences_delete_own on public.user_preferences
  for delete using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Profile bootstrap
--
-- Runs as the definer so a brand-new user has a profile row before their first
-- request. Without this, the client's first write races its own signup.
-- -----------------------------------------------------------------------------

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, display_name)
  values (
    new.id,
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), '')
  )
  on conflict (id) do nothing;

  insert into public.user_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();
