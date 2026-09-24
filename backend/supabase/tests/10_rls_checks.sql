-- =============================================================================
-- BEFORE — functional Row Level Security checks.
--
-- The static lint in backend/tests/migrations.test.ts proves a policy EXISTS.
-- This proves it WORKS: two real users, real inserts, and assertions that
-- neither can see or touch the other's rows.
--
-- Those are different claims. A policy of `using (user_id = user_id)` would
-- pass the lint and leak every row in the table.
--
-- Any failure raises, so psql exits non-zero under ON_ERROR_STOP.
-- =============================================================================

\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on

-- Each assertion emits a NOTICE and returns void; with tuples_only the result
-- rows collapse to blank lines. Two hundred lines of "(1 row)" would hide the
-- one line that matters.
create function pg_temp.check(condition boolean, description text)
returns void
language plpgsql
as $$
begin
  if condition then
    raise notice '  ok    %', description;
  else
    raise exception 'FAILED: %', description;
  end if;
end;
$$;

/**
 * Assert that a statement is REFUSED.
 *
 * Takes SQL as text and expects it to raise. A test that "passes" because the
 * statement silently did nothing would be worthless, so a successful execution
 * is an explicit failure here.
 */
create function pg_temp.check_refused(statement text, description text)
returns void
language plpgsql
as $$
begin
  execute statement;
  raise exception 'FAILED: % (the statement was allowed)', description;
exception
  when insufficient_privilege or check_violation or unique_violation
       or foreign_key_violation or not_null_violation then
    raise notice '  ok    %', description;
end;
$$;

-- ---------------------------------------------------------------------------
-- Two users. The trigger on auth.users should create both profiles.
-- ---------------------------------------------------------------------------

\set alice '11111111-1111-4111-8111-111111111111'
\set bob   '22222222-2222-4222-8222-222222222222'

insert into auth.users (id, email, raw_user_meta_data)
values
  (:'alice', 'alice@example.invalid', '{"full_name": "Alice Test"}'::jsonb),
  (:'bob',   'bob@example.invalid',   '{}'::jsonb);

select pg_temp.check(
  (select count(*) from public.users where id in (:'alice', :'bob')) = 2,
  'on_auth_user_created creates a profile for each new user');

select pg_temp.check(
  (select count(*) from public.user_preferences where user_id in (:'alice', :'bob')) = 2,
  'on_auth_user_created creates preferences for each new user');

select pg_temp.check(
  (select display_name from public.users where id = :'alice') = 'Alice Test',
  'the display name Apple supplied on first authorisation is captured');

select pg_temp.check(
  (select display_name from public.users where id = :'bob') is null,
  'a user who withheld their name is stored with a null display name');

-- ---------------------------------------------------------------------------
-- Alice writes, as an unprivileged role carrying her own JWT claims.
-- ---------------------------------------------------------------------------

begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "11111111-1111-4111-8111-111111111111"}';

select pg_temp.check(auth.uid() = :'alice', 'auth.uid() reflects the request claims');

insert into public.analyses
  (id, user_id, status, input_type, score, verdict, suggested_action, confidence,
   prompt_version, score_algorithm_version)
values
  ('aaaaaaaa-0000-4000-8000-000000000001', :'alice', 'completed', 'photo', 51, 'BYE', 'SKIP_IT', 0.9,
   'purchase_analysis_v1', 'score_v1');

insert into public.analysis_products (analysis_id, user_id, name, category, price, currency)
values ('aaaaaaaa-0000-4000-8000-000000000001', :'alice', 'Ribbed knit top', 'fashion', 89, 'USD');

insert into public.analysis_factors (analysis_id, user_id, signal, value, weight, included)
values ('aaaaaaaa-0000-4000-8000-000000000001', :'alice', 'duplication_risk', 2.8, 0.15, true);

insert into public.wardrobe_items (user_id, category, subcategory, color)
values (:'alice', 'fashion', 'tops', 'black');

insert into public.saved_items (user_id, analysis_id, bucket)
values (:'alice', 'aaaaaaaa-0000-4000-8000-000000000001', 'maybe');

insert into public.purchase_outcomes (analysis_id, user_id, action)
values ('aaaaaaaa-0000-4000-8000-000000000001', :'alice', 'skipped');

select pg_temp.check((select count(*) from public.analyses) = 1,
  'Alice can read back her own analysis');

-- Forging a user_id must be refused by the WITH CHECK clause.
select pg_temp.check_refused(
  'insert into public.wardrobe_items (user_id, category) values (''22222222-2222-4222-8222-222222222222'', ''fashion'')',
  'RLS: Alice cannot insert a row owned by Bob');
commit;

-- ---------------------------------------------------------------------------
-- Bob sees nothing. This is the test the whole privacy model rests on.
-- ---------------------------------------------------------------------------

begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "22222222-2222-4222-8222-222222222222"}';

select pg_temp.check((select count(*) from public.analyses) = 0,
  'RLS: Bob cannot see Alice''s analyses');
select pg_temp.check((select count(*) from public.analysis_products) = 0,
  'RLS: Bob cannot see Alice''s product details');
select pg_temp.check((select count(*) from public.analysis_factors) = 0,
  'RLS: Bob cannot see Alice''s factor breakdown');
select pg_temp.check((select count(*) from public.wardrobe_items) = 0,
  'RLS: Bob cannot see Alice''s wardrobe');
select pg_temp.check((select count(*) from public.saved_items) = 0,
  'RLS: Bob cannot see Alice''s saved items');
select pg_temp.check((select count(*) from public.purchase_outcomes) = 0,
  'RLS: Bob cannot see Alice''s purchase outcomes');
select pg_temp.check((select count(*) from public.users) = 1,
  'RLS: Bob sees only his own profile');
select pg_temp.check((select count(*) from public.potential_spend_avoided) = 0,
  'RLS: the spend-avoided view is scoped by security_invoker');

-- A read-only policy that still permits UPDATE or DELETE is a distinct and
-- easily-missed hole, so both are exercised.
update public.analyses set score = 100;
delete from public.wardrobe_items;
commit;

begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "11111111-1111-4111-8111-111111111111"}';

select pg_temp.check((select score from public.analyses limit 1) = 51,
  'RLS: Bob''s UPDATE did not alter Alice''s score');
select pg_temp.check((select count(*) from public.wardrobe_items) = 1,
  'RLS: Bob''s DELETE did not remove Alice''s wardrobe item');
commit;

-- ---------------------------------------------------------------------------
-- Storage policies scope on the <user-id>/ prefix.
-- ---------------------------------------------------------------------------

select pg_temp.check(
  (storage.foldername('11111111-1111-4111-8111-111111111111/photo.jpg'))[1]
    = '11111111-1111-4111-8111-111111111111',
  'storage.foldername extracts the owning user prefix');

insert into storage.objects (bucket_id, name)
values
  ('analyses', '11111111-1111-4111-8111-111111111111/a.jpg'),
  ('analyses', '22222222-2222-4222-8222-222222222222/b.jpg'),
  ('wardrobe', '11111111-1111-4111-8111-111111111111/w.jpg');

begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "11111111-1111-4111-8111-111111111111"}';
select pg_temp.check((select count(*) from storage.objects) = 2,
  'RLS: Alice sees only objects under her own prefix');
commit;

select pg_temp.check((select count(*) from storage.buckets where public) = 0,
  'every storage bucket is private');

select pg_temp.check(
  (select count(*) from storage.buckets where id in ('analyses', 'wardrobe')) = 2,
  'both storage buckets were created');

-- ---------------------------------------------------------------------------
-- Entitlement. Must agree with grantsEntitlement() in appstore.ts.
-- ---------------------------------------------------------------------------

select pg_temp.check(public.is_plus(:'alice') = false,
  'is_plus is false with no subscription');

insert into public.subscriptions
  (user_id, product_id, original_transaction_id, status, expiration_date, environment)
values (:'alice', 'before.plus.yearly', 'txn-1', 'active', now() + interval '30 days', 'production');
select pg_temp.check(public.is_plus(:'alice') = true,
  'is_plus is true for an active subscription');

update public.subscriptions set expiration_date = now() - interval '1 day'
where original_transaction_id = 'txn-1';
select pg_temp.check(public.is_plus(:'alice') = false,
  'is_plus is false once the subscription has expired');

update public.subscriptions
set status = 'in_grace_period', expiration_date = now() + interval '5 days'
where original_transaction_id = 'txn-1';
select pg_temp.check(public.is_plus(:'alice') = true,
  'a grace period still grants entitlement');

update public.subscriptions set status = 'in_billing_retry'
where original_transaction_id = 'txn-1';
select pg_temp.check(public.is_plus(:'alice') = true,
  'a billing retry still grants entitlement');

update public.subscriptions set status = 'revoked', revocation_date = now()
where original_transaction_id = 'txn-1';
select pg_temp.check(public.is_plus(:'alice') = false,
  'a revoked subscription grants nothing');

-- A subscription belonging to someone else must never leak entitlement.
select pg_temp.check(public.is_plus(:'bob') = false,
  'Bob is not made Plus by Alice''s subscription');

-- ---------------------------------------------------------------------------
-- Constraints that protect the data model
-- ---------------------------------------------------------------------------

select pg_temp.check_refused(
  'insert into public.analyses (user_id, status, input_type, prompt_version, score_algorithm_version)
   values (''11111111-1111-4111-8111-111111111111'', ''completed'', ''photo'', ''v1'', ''v1'')',
  'a completed analysis must carry a score, verdict and confidence');

select pg_temp.check_refused(
  'insert into public.wardrobe_items (user_id, category, price)
   values (''11111111-1111-4111-8111-111111111111'', ''fashion'', 40)',
  'a price without a currency is refused');

select pg_temp.check_refused(
  'update public.purchase_outcomes set satisfaction = ''love_it''
   where analysis_id = ''aaaaaaaa-0000-4000-8000-000000000001''',
  'only a purchase can be rated');

select pg_temp.check_refused(
  'update public.user_preferences
   set shopping_priorities = array[''style'',''price'',''quality'',''trend'']::public.shopping_priority[]
   where user_id = ''22222222-2222-4222-8222-222222222222''',
  'at most three shopping priorities (spec §7)');

select pg_temp.check_refused(
  'insert into public.users (id, currency) values (gen_random_uuid(), ''DOLLARS'')',
  'currency must be an ISO-4217 code');

select pg_temp.check_refused(
  'update public.analyses set score = 150
   where id = ''aaaaaaaa-0000-4000-8000-000000000001''',
  'a score outside 0..100 is refused');

-- ---------------------------------------------------------------------------
-- Potential spend avoided — the number shown on Home
-- ---------------------------------------------------------------------------

select pg_temp.check(
  (select amount from public.potential_spend_avoided where user_id = :'alice') = 89,
  'a BYE the user then skipped counts toward potential spend avoided');

-- ---------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------

select pg_temp.check(public.cleanup_expired_cache() >= 0,
  'cleanup_expired_cache runs');

select pg_temp.check(
  public.cleanup_unsaved_analysis_images(interval '0 seconds') >= 0,
  'cleanup_unsaved_analysis_images runs');

-- Alice's analysis is saved, so its image must survive the sweep.
select pg_temp.check(
  (select count(*) from storage.objects
    where name = '11111111-1111-4111-8111-111111111111/a.jpg') = 1,
  'a saved analysis keeps its image');

-- ---------------------------------------------------------------------------
-- Deletion actually deletes
-- ---------------------------------------------------------------------------

select pg_temp.check(
  (public.delete_user_account(:'alice') ->> 'storage_objects_removed')::int = 2,
  'delete_user_account removes the user''s storage objects from both buckets');

select pg_temp.check((select count(*) from public.users where id = :'alice') = 0,
  'deletion removes the profile');
select pg_temp.check((select count(*) from public.analyses where user_id = :'alice') = 0,
  'deletion cascades to analyses');
select pg_temp.check((select count(*) from public.analysis_products where user_id = :'alice') = 0,
  'deletion cascades to product details');
select pg_temp.check((select count(*) from public.wardrobe_items where user_id = :'alice') = 0,
  'deletion cascades to the wardrobe');
select pg_temp.check((select count(*) from public.purchase_outcomes where user_id = :'alice') = 0,
  'deletion cascades to outcomes');
select pg_temp.check((select count(*) from public.subscriptions where user_id = :'alice') = 0,
  'deletion cascades to subscription records');
select pg_temp.check((select count(*) from auth.users where id = :'alice') = 0,
  'deletion removes the auth user');
select pg_temp.check(
  (select count(*) from storage.objects
    where (storage.foldername(name))[1] = '11111111-1111-4111-8111-111111111111') = 0,
  'deletion removes storage objects, which a row cascade cannot reach');
select pg_temp.check((select count(*) from public.users where id = :'bob') = 1,
  'deleting Alice left Bob untouched');
select pg_temp.check(
  (select count(*) from storage.objects
    where (storage.foldername(name))[1] = '22222222-2222-4222-8222-222222222222') = 1,
  'deleting Alice left Bob''s storage objects untouched');
