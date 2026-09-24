/**
 * GET  /v1/analyses/:id          — reopen an analysis
 * POST /v1/analyses/:id/outcome  — record what the user actually did
 *
 * The outcome endpoint is the one that matters long term. "BEFORE said WAIT,
 * you bought it, you regret it" is the only ground truth this product ever
 * gets, and it is what a future personalisation model would learn from.
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import { OUTCOME_ACTIONS, SATISFACTIONS, type OutcomeAction, type Satisfaction } from '@shared/types.ts';

interface OutcomeBody {
  action?: OutcomeAction;
  purchaseDate?: string;
  actualPrice?: number;
  currency?: string;
  returned?: boolean;
  satisfaction?: Satisfaction;
  notes?: string;
}

/** `/v1/analyses/<uuid>` or `/v1/analyses/<uuid>/outcome`. */
function parsePath(url: URL): { analysisId: string; isOutcome: boolean } {
  const segments = url.pathname.split('/').filter(Boolean);
  const index = segments.findIndex((s) => s === 'analyses' || s === 'analysis');
  const analysisId = index >= 0 ? segments[index + 1] : undefined;

  if (!analysisId || !/^[0-9a-f-]{36}$/i.test(analysisId)) {
    throw new ApiError('invalid_request', 'an analysis id is required in the path');
  }
  return { analysisId, isOutcome: segments[index + 2] === 'outcome' };
}

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const { analysisId, isOutcome } = parsePath(new URL(request.url));

  // RLS means this returns nothing for someone else's analysis; the explicit
  // check turns that into a clean 404 rather than a confusing empty success.
  const { data: analysis } = await ctx.db
    .from('analyses')
    .select('id, verdict, status')
    .eq('id', analysisId)
    .maybeSingle();

  if (!analysis) throw new ApiError('not_found', 'no such analysis');

  if (request.method === 'GET') {
    const { data, error } = await ctx.db
      .from('analyses')
      .select('*, analysis_products(*), analysis_factors(*), saved_items(bucket), purchase_outcomes(*)')
      .eq('id', analysisId)
      .single();

    if (error) throw new ApiError('internal_error', error.message);

    const imagePath = data.image_path as string | null;
    const imageUrl = imagePath
      ? (await ctx.admin.storage.from('analyses').createSignedUrl(imagePath, 3600)).data?.signedUrl ?? null
      : null;

    return jsonResponse({ ...data, imageUrl }, 200);
  }

  if (!isOutcome) throw new ApiError('invalid_request', 'unsupported route');

  const body = await readJson<OutcomeBody>(request, 32 * 1024);

  if (!body.action || !(OUTCOME_ACTIONS as readonly string[]).includes(body.action)) {
    throw new ApiError('invalid_request', 'action must be bought, skipped, or still_thinking');
  }
  if (body.satisfaction && !(SATISFACTIONS as readonly string[]).includes(body.satisfaction)) {
    throw new ApiError('invalid_request', 'unknown satisfaction value');
  }
  // The database enforces these too; failing here gives a readable message.
  if (body.satisfaction && body.action !== 'bought') {
    throw new ApiError('invalid_request', 'only a purchase can be rated');
  }
  if (body.returned && body.action !== 'bought') {
    throw new ApiError('invalid_request', 'only a purchase can be returned');
  }

  // Ask "how's it going?" a fortnight after a purchase — long enough to have an
  // opinion. Only ever delivered if notification permission was granted (§64).
  const followupDueAt =
    body.action === 'bought' && !body.satisfaction
      ? new Date(Date.now() + 14 * 86_400_000).toISOString()
      : null;

  const { error } = await ctx.db.from('purchase_outcomes').upsert(
    {
      analysis_id: analysisId,
      user_id: ctx.userId,
      action: body.action,
      purchase_date: body.purchaseDate ?? null,
      actual_price: body.actualPrice ?? null,
      currency: body.currency?.toUpperCase() ?? null,
      returned: body.returned ?? false,
      satisfaction: body.satisfaction ?? null,
      notes: body.notes?.slice(0, 500) ?? null,
      followup_due_at: followupDueAt,
    },
    { onConflict: 'analysis_id' },
  );

  if (error) throw new ApiError('internal_error', `outcome save failed: ${error.message}`);

  // Keep the saved bucket in step with reality, if the item is saved at all.
  if (body.action === 'bought') {
    await ctx.db
      .from('saved_items')
      .update({ bucket: 'bought' })
      .eq('analysis_id', analysisId)
      .eq('user_id', ctx.userId);
  }

  ctx.log.info('outcome.recorded', { verdict: analysis.verdict, note: body.action });

  return jsonResponse({ recorded: true, action: body.action }, 200);
}

Deno.serve(withContext({ endpoint: '/v1/analyses/:id', methods: ['GET', 'POST'] }, handler));
