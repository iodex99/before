-- =============================================================================
-- BEFORE — 0008: account deletion and maintenance
--
-- Deletion has to actually delete. A "deleted" account that leaves a bucket
-- full of someone's wardrobe photos is the kind of thing this whole product is
-- supposed to be trusted not to do.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Account deletion (spec §77)
--
-- Order matters and is documented in docs/PRIVACY.md:
--   1. Mark intent, so an interrupted run is visible.
--   2. Remove storage objects — the only things a row cascade cannot reach.
--   3. Detach operational logs from the user (kept for cost history, unlinked).
--   4. Delete the auth user; every public row cascades from there.
--
-- What this deliberately does NOT do: touch the App Store subscription. We
-- cannot cancel it and must not pretend to. The app tells the user to manage it
-- through Apple.
-- -----------------------------------------------------------------------------

create or replace function public.delete_user_account(target_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  storage_removed integer := 0;
  analyses_removed integer := 0;
  wardrobe_removed integer := 0;
begin
  if target_user is null then
    raise exception 'delete_user_account requires a user id';
  end if;

  -- 1. Intent first.
  update public.users set deleted_at = now() where id = target_user;

  -- 2. Storage. Row cascades cannot reach object storage, so it goes first:
  -- if the run dies after this point, what is left behind is rows, not photos.
  with removed as (
    delete from storage.objects
    where bucket_id in ('analyses', 'wardrobe')
      and (storage.foldername(name))[1] = target_user::text
    returning 1
  )
  select count(*) into storage_removed from removed;

  select count(*) into analyses_removed from public.analyses where user_id = target_user;
  select count(*) into wardrobe_removed from public.wardrobe_items where user_id = target_user;

  -- 3. Operational logs are unlinked rather than deleted: aggregate cost
  -- history survives, the association with a person does not.
  update public.ai_call_log set user_id = null where user_id = target_user;
  update public.analytics_events set user_id = null where user_id = target_user;

  -- 4. Everything in public.* cascades from auth.users.
  delete from auth.users where id = target_user;

  return jsonb_build_object(
    'deleted_at', now(),
    'storage_objects_removed', storage_removed,
    'analyses_removed', analyses_removed,
    'wardrobe_items_removed', wardrobe_removed
  );
end;
$$;

revoke all on function public.delete_user_account(uuid) from public, anon, authenticated;

comment on function public.delete_user_account(uuid) is
  'Permanently deletes a user. Service role only, called from the account-delete edge function. Does not and cannot cancel an App Store subscription.';

-- -----------------------------------------------------------------------------
-- Maintenance
--
-- Schedule with pg_cron or an external scheduler. See docs/SETUP.md.
-- -----------------------------------------------------------------------------

/**
 * Images for analyses the user never saved.
 *
 * Spec §42: process the image, keep it only if the analysis is saved, otherwise
 * delete it. The grace period exists so a user who saves the result a minute
 * later still has a thumbnail.
 */
create or replace function public.cleanup_unsaved_analysis_images(grace interval default interval '24 hours')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  removed integer := 0;
begin
  with orphaned as (
    select a.id, a.user_id, a.image_path
    from public.analyses a
    left join public.saved_items s on s.analysis_id = a.id
    where a.image_path is not null
      and s.id is null
      and a.created_at < now() - grace
  ),
  deleted_objects as (
    delete from storage.objects o
    using orphaned
    where o.bucket_id = 'analyses' and o.name = orphaned.image_path
    returning 1
  )
  select count(*) into removed from deleted_objects;

  -- Clear the pointer so the app shows a placeholder rather than a broken link.
  update public.analyses a
  set image_path = null
  from (
    select a2.id
    from public.analyses a2
    left join public.saved_items s on s.analysis_id = a2.id
    where a2.image_path is not null and s.id is null and a2.created_at < now() - grace
  ) stale
  where a.id = stale.id;

  return removed;
end;
$$;

create or replace function public.cleanup_expired_cache()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  removed integer := 0;
begin
  with deleted as (
    delete from public.product_metadata_cache where expires_at < now() returning 1
  )
  select count(*) into removed from deleted;

  -- Idempotency keys only need to outlive a retrying client.
  delete from public.idempotency_keys where created_at < now() - interval '48 hours';

  -- Raw App Store payloads are kept only long enough to replay a failure.
  delete from public.app_store_notifications
  where processed_at is not null and received_at < now() - interval '30 days';

  return removed;
end;
$$;

revoke all on function public.cleanup_unsaved_analysis_images(interval) from public, anon, authenticated;
revoke all on function public.cleanup_expired_cache() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Data export (spec §43)
--
-- Everything BEFORE holds about a user, in one JSON document. Runs as the
-- invoker so it can only ever return the caller's own data.
-- -----------------------------------------------------------------------------

create or replace function public.export_user_data()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(u) from public.users u where u.id = auth.uid()),
    'preferences', (select to_jsonb(p) from public.user_preferences p where p.user_id = auth.uid()),
    'analyses', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.created_at desc)
      from public.analyses a where a.user_id = auth.uid()
    ), '[]'::jsonb),
    'analysis_products', coalesce((
      select jsonb_agg(to_jsonb(p)) from public.analysis_products p where p.user_id = auth.uid()
    ), '[]'::jsonb),
    'analysis_factors', coalesce((
      select jsonb_agg(to_jsonb(f)) from public.analysis_factors f where f.user_id = auth.uid()
    ), '[]'::jsonb),
    'wardrobe_items', coalesce((
      select jsonb_agg(to_jsonb(w)) from public.wardrobe_items w where w.user_id = auth.uid()
    ), '[]'::jsonb),
    'saved_items', coalesce((
      select jsonb_agg(to_jsonb(s)) from public.saved_items s where s.user_id = auth.uid()
    ), '[]'::jsonb),
    'purchase_outcomes', coalesce((
      select jsonb_agg(to_jsonb(o)) from public.purchase_outcomes o where o.user_id = auth.uid()
    ), '[]'::jsonb),
    'usage', coalesce((
      select jsonb_agg(to_jsonb(l)) from public.usage_ledger l where l.user_id = auth.uid()
    ), '[]'::jsonb),
    'subscriptions', coalesce((
      select jsonb_agg(to_jsonb(sub)) from public.subscriptions sub where sub.user_id = auth.uid()
    ), '[]'::jsonb)
  );
$$;

comment on function public.export_user_data() is
  'Everything BEFORE holds about the calling user. security_invoker, so RLS applies.';
