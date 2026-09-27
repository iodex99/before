/**
 * GET /v1/usage — how many checks are left this month.
 *
 * The app shows "4 of 5 checks remaining" from this response. It is also the
 * server's own answer, so the two can never disagree: the client counter is a
 * display, this is the limit (spec §33).
 */

import { withContext, type RequestContext } from '../_shared/context.ts';
import { isPlus, loadUsageCounts, loadUserProfile } from '../_shared/repository.ts';
import { jsonResponse } from '@shared/http/errors.ts';
import { evaluateQuota, monthWindow } from '@shared/http/quota.ts';
import type { UsageResponse } from '@shared/types.ts';

async function handler(_request: Request, ctx: RequestContext): Promise<Response> {
  const now = new Date();
  const profile = await loadUserProfile(ctx.db, ctx.userId);
  const plus = await isPlus(ctx.admin, ctx.userId);
  const counts = await loadUsageCounts(ctx.admin, ctx.userId, profile.timezone, now);
  const quota = evaluateQuota(counts, plus, ctx.config.quota);

  // The month boundary is the user's own, not UTC's — otherwise someone in
  // Los Angeles loses most of the last day of every month.
  const { start, end } = monthWindow(now, profile.timezone);

  const payload: UsageResponse = {
    periodStart: start.toISOString(),
    periodEnd: end.toISOString(),
    used: counts.monthUsed,
    limit: quota.limit,
    remaining: quota.remaining,
    isPlus: plus,
    fairUseLimit: plus ? ctx.config.quota.plusMonthlyAnalyses : null,
    fairUseRemaining: plus
      ? Math.max(0, ctx.config.quota.plusMonthlyAnalyses - counts.monthUsed)
      : null,
  };

  ctx.log.info('usage.read', { isPlus: plus, quotaRemaining: quota.remaining });
  return jsonResponse(payload, 200);
}

Deno.serve(withContext({ endpoint: '/v1/usage', methods: ['GET'] }, handler));
