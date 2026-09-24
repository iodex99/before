/**
 * GET  /v1/me — profile + entitlement
 * PATCH /v1/me — update preferences and locale settings
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { isPlus, loadUserProfile } from '../_shared/repository.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import { safeTimezone } from '@shared/http/quota.ts';
import {
  BUDGET_SENSITIVITIES,
  SHOPPING_FOCUSES,
  SHOPPING_PRIORITIES,
  STYLE_PREFERENCES,
  type MeResponse,
} from '@shared/types.ts';

interface UpdateBody {
  preferredName?: string | null;
  locale?: string;
  currency?: string;
  timezone?: string;
  shoppingPriorities?: string[];
  favoriteStyles?: string[];
  budgetSensitivity?: string;
  shoppingFocus?: string;
  onboardingCompleted?: boolean;
}

function filterEnum<T extends string>(values: unknown, allowed: readonly T[], max: number): T[] {
  if (!Array.isArray(values)) return [];
  const seen = new Set<T>();
  for (const value of values) {
    if (typeof value === 'string' && (allowed as readonly string[]).includes(value)) {
      seen.add(value as T);
    }
    if (seen.size >= max) break;
  }
  return [...seen];
}

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  if (request.method === 'PATCH') {
    const body = await readJson<UpdateBody>(request, 64 * 1024);

    const profileUpdate: Record<string, unknown> = {};
    if (body.preferredName !== undefined) {
      profileUpdate.preferred_name = body.preferredName?.slice(0, 60) || null;
    }
    if (body.locale) profileUpdate.locale = body.locale.slice(0, 20);
    if (body.currency) {
      const code = body.currency.trim().toUpperCase();
      if (!/^[A-Z]{3}$/.test(code)) throw new ApiError('invalid_request', 'currency must be ISO-4217');
      profileUpdate.currency = code;
    }
    if (body.timezone) profileUpdate.timezone = safeTimezone(body.timezone);
    if (body.onboardingCompleted) profileUpdate.onboarding_completed_at = new Date().toISOString();

    if (Object.keys(profileUpdate).length > 0) {
      const { error } = await ctx.db.from('users').update(profileUpdate).eq('id', ctx.userId);
      if (error) throw new ApiError('internal_error', error.message);
    }

    const prefsUpdate: Record<string, unknown> = {};
    if (body.shoppingPriorities !== undefined) {
      // Spec §7: up to three. Enforced here and again by a check constraint.
      prefsUpdate.shopping_priorities = filterEnum(body.shoppingPriorities, SHOPPING_PRIORITIES, 3);
    }
    if (body.favoriteStyles !== undefined) {
      prefsUpdate.favorite_styles = filterEnum(body.favoriteStyles, STYLE_PREFERENCES, 5);
    }
    if (body.budgetSensitivity && (BUDGET_SENSITIVITIES as readonly string[]).includes(body.budgetSensitivity)) {
      prefsUpdate.budget_sensitivity = body.budgetSensitivity;
    }
    if (body.shoppingFocus && (SHOPPING_FOCUSES as readonly string[]).includes(body.shoppingFocus)) {
      prefsUpdate.shopping_focus = body.shoppingFocus;
    }

    if (Object.keys(prefsUpdate).length > 0) {
      const { error } = await ctx.db
        .from('user_preferences')
        .upsert({ user_id: ctx.userId, ...prefsUpdate }, { onConflict: 'user_id' });
      if (error) throw new ApiError('internal_error', error.message);
    }
  }

  const profile = await loadUserProfile(ctx.db, ctx.userId);
  const plus = await isPlus(ctx.admin, ctx.userId);

  const payload: MeResponse = {
    userId: profile.id,
    displayName: profile.displayName,
    preferredName: profile.preferredName,
    locale: profile.locale,
    currency: profile.currency,
    timezone: profile.timezone,
    preferences: profile.preferences,
    isPlus: plus,
    createdAt: profile.createdAt,
  };

  return jsonResponse(payload, 200);
}

Deno.serve(withContext({ endpoint: '/v1/me', methods: ['GET', 'PATCH'] }, handler));
