-- =============================================================================
-- BEFORE — development seed data.
--
-- NEVER run this against production (spec §73). It creates a fake auth user.
-- `supabase db reset` applies it automatically to a LOCAL database only.
--
-- Gives you a user with enough wardrobe and history that the relevance filter,
-- the duplication signal, and the budget override rule all have something real
-- to work with — an empty database exercises none of them.
-- =============================================================================

do $$
declare
  demo_user uuid := '00000000-0000-4000-8000-000000000001';
begin
  -- Refuse to run anywhere that looks like production.
  if current_setting('app.settings.environment', true) = 'production' then
    raise exception 'seed.sql must never run against production';
  end if;

  -- --------------------------------------------------------------------------
  -- Identity. Mirrors what Sign in with Apple would produce.
  -- --------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  values (
    demo_user,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'demo@example.invalid',
    '{"full_name": "Sam Rivera"}'::jsonb,
    now() - interval '40 days',
    now()
  )
  on conflict (id) do nothing;

  -- The on_auth_user_created trigger creates the profile and preferences rows.
  update public.users
  set locale = 'en-US', currency = 'USD', timezone = 'America/New_York',
      onboarding_completed_at = now() - interval '39 days'
  where id = demo_user;

  update public.user_preferences
  set shopping_priorities = array['style', 'versatility', 'quality']::public.shopping_priority[],
      favorite_styles = array['minimal', 'classic']::public.style_preference[],
      budget_sensitivity = 'medium',
      shopping_focus = 'both'
  where user_id = demo_user;

  -- --------------------------------------------------------------------------
  -- Wardrobe.
  --
  -- Two black outerwear pieces on purpose: checking a third black jacket should
  -- produce a high duplication signal, which is the behaviour worth seeing
  -- during development.
  -- --------------------------------------------------------------------------
  insert into public.wardrobe_items
    (user_id, category, subcategory, color, brand, price, currency, purchase_date, source, style_tags)
  values
    (demo_user, 'fashion', 'outerwear', 'black',  null, 210, 'USD', current_date - 300, 'manual',   array['minimal','edgy']),
    (demo_user, 'fashion', 'outerwear', 'black',  null, 165, 'USD', current_date - 140, 'analysis', array['classic']),
    (demo_user, 'fashion', 'outerwear', 'camel',  null, 240, 'USD', current_date - 420, 'manual',   array['classic']),
    (demo_user, 'fashion', 'tops',      'black',  null,  60, 'USD', current_date - 90,  'manual',   array['minimal']),
    (demo_user, 'fashion', 'tops',      'white',  null,  55, 'USD', current_date - 200, 'manual',   array['minimal']),
    (demo_user, 'fashion', 'tops',      'black',  null,  48, 'USD', current_date - 60,  'analysis', array['casual']),
    (demo_user, 'fashion', 'bottoms',   'navy',   null, 120, 'USD', current_date - 250, 'manual',   array['classic']),
    (demo_user, 'fashion', 'bottoms',   'black',  null,  95, 'USD', current_date - 180, 'manual',   array['minimal']),
    (demo_user, 'fashion', 'shoes',     'black',  null, 180, 'USD', current_date - 330, 'manual',   array['classic']),
    (demo_user, 'fashion', 'bags',      'brown',  null, 260, 'USD', current_date - 500, 'manual',   array['classic']),
    (demo_user, 'beauty',  'skincare',  null,     null,  42, 'USD', current_date - 30,  'manual',   array[]::text[]),
    (demo_user, 'beauty',  'makeup',    null,     null,  28, 'USD', current_date - 45,  'manual',   array[]::text[]);

  -- --------------------------------------------------------------------------
  -- History.
  --
  -- Three bought outerwear items, so medianCategorySpend() has the three data
  -- points it needs before it will return a number at all.
  -- --------------------------------------------------------------------------
  insert into public.analyses
    (id, user_id, status, input_type, score, verdict, suggested_action, confidence,
     positive_factors, negative_factors, key_risk, advice, applied_rules,
     prompt_version, score_algorithm_version, ai_provider, ai_model,
     created_at, completed_at)
  values
    ('10000000-0000-4000-8000-000000000001', demo_user, 'completed', 'photo', 88, 'BUY', 'BUY_IT', 0.84,
     array['Works with the trousers you already wear to work','No flat leather shoe in this colour family'],
     array['Sizing on this style runs inconsistent'],
     'Fit is the only real unknown here.', 'This fills a genuine gap.',
     array[]::text[], 'purchase_analysis_v1', 'score_v1', 'mock', 'mock-fixture-v1',
     now() - interval '22 days', now() - interval '22 days'),

    ('10000000-0000-4000-8000-000000000002', demo_user, 'completed', 'url', 78, 'WAIT', 'WAIT_48_HOURS', 0.74,
     array['Works with the neutrals that make up most of what you own'],
     array['You own a black jacket that covers a similar occasion'],
     'It overlaps with a jacket you already reach for.', 'Wait 48 hours.',
     array[]::text[], 'purchase_analysis_v1', 'score_v1', 'mock', 'mock-fixture-v1',
     now() - interval '9 days', now() - interval '9 days'),

    ('10000000-0000-4000-8000-000000000003', demo_user, 'completed', 'screenshot', 51, 'BYE', 'SKIP_IT', 0.86,
     array['Black knits are the thing you wear most'],
     array['You already own three black ribbed knits','Priced above what you usually pay for a basic top'],
     'This is the fourth version of something you already have.',
     'Skip it. You have better uses for the money.',
     array['duplication_dominant_bye'], 'purchase_analysis_v1', 'score_v1', 'mock', 'mock-fixture-v1',
     now() - interval '4 days', now() - interval '4 days');

  insert into public.analysis_products
    (analysis_id, user_id, name, category, subcategory, price, currency, fact_sources,
     price_confidence, identity_confidence, colors, style_tags)
  values
    ('10000000-0000-4000-8000-000000000001', demo_user, 'Leather loafers', 'fashion', 'shoes', 145, 'USD',
     '{"price":"confirmed","category":"confirmed"}'::jsonb, 0.92, 0.78, array['brown'], array['classic']),
    ('10000000-0000-4000-8000-000000000002', demo_user, 'Cropped leather jacket', 'fashion', 'outerwear', 198, 'USD',
     '{"price":"confirmed","category":"confirmed"}'::jsonb, 0.95, 0.60, array['black'], array['minimal','edgy']),
    ('10000000-0000-4000-8000-000000000003', demo_user, 'Ribbed knit top', 'fashion', 'tops', 89, 'USD',
     '{"price":"confirmed","category":"confirmed"}'::jsonb, 0.90, 0.70, array['black'], array['minimal']);

  -- Outcomes. The BYE was skipped, which is what makes "potential spend
  -- avoided" show a number on Home.
  insert into public.purchase_outcomes
    (analysis_id, user_id, action, purchase_date, actual_price, currency, satisfaction, created_at)
  values
    ('10000000-0000-4000-8000-000000000001', demo_user, 'bought', current_date - 22, 145, 'USD', 'love_it', now() - interval '22 days'),
    ('10000000-0000-4000-8000-000000000002', demo_user, 'still_thinking', null, null, null, null, now() - interval '9 days'),
    ('10000000-0000-4000-8000-000000000003', demo_user, 'skipped', null, null, null, null, now() - interval '4 days');

  insert into public.saved_items (user_id, analysis_id, bucket, created_at)
  values
    (demo_user, '10000000-0000-4000-8000-000000000002', 'maybe',  now() - interval '9 days'),
    (demo_user, '10000000-0000-4000-8000-000000000001', 'bought', now() - interval '22 days');

  -- Quota: two used this month, so the app shows "3 of 5 checks remaining".
  insert into public.usage_ledger (user_id, analysis_id, kind, counted_against_free_quota, created_at)
  values
    (demo_user, '10000000-0000-4000-8000-000000000002', 'analysis', true, now() - interval '9 days'),
    (demo_user, '10000000-0000-4000-8000-000000000003', 'analysis', true, now() - interval '4 days');

  raise notice 'BEFORE seed applied for demo user %', demo_user;
end $$;
