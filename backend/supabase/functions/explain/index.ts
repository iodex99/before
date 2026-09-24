/**
 * POST /v1/analyses/:id/explain — deeper explanation (BEFORE Plus, spec §35).
 *
 * Deliberately NOT a chat. The request carries an `angle` from a fixed set, not
 * a free-text question: Rule 1 says BEFORE is not a general AI assistant, and
 * §8 rules out a chat tab. A free-text field here would quietly turn the result
 * screen into one.
 *
 * It also cannot introduce new facts. The model is given the analysis it
 * already produced and told to expand on it — it is not shown the image again
 * and cannot look anything up, so it has nothing to invent from.
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import { isPlus, loadUsageCounts, loadUserProfile } from '../_shared/repository.ts';
import { createProvider } from '@shared/ai/factory.ts';
import { ProviderError } from '@shared/ai/provider.ts';
import { scanStrings } from '@shared/ai/safety.ts';
import { estimateCostUsd } from '@shared/ai/pricing.ts';
import mockFixtures from '@shared/fixtures/ai-responses.json' with { type: 'json' };

/** The only questions that can be asked. */
const ANGLES = {
  why_this_verdict: 'Explain in more depth why this came out as it did.',
  what_would_change_it: 'What would have to be different for this to be a clear yes?',
  how_it_fits: 'How would this actually fit with what they already own?',
} as const;

type Angle = keyof typeof ANGLES;

interface ExplainBody {
  angle?: string;
}

function analysisId(url: URL): string {
  const segments = url.pathname.split('/').filter(Boolean);
  const index = segments.findIndex((segment) => segment === 'explain');
  // /v1/analyses/<id>/explain  or  /explain/<id>
  const candidate = index > 0 ? segments[index - 1] : segments[segments.length - 1];

  if (!candidate || !/^[0-9a-f-]{36}$/i.test(candidate)) {
    throw new ApiError('invalid_request', 'an analysis id is required in the path');
  }
  return candidate;
}

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const id = analysisId(new URL(request.url));
  const body = await readJson<ExplainBody>(request, 4096);

  const angle = (body.angle ?? 'why_this_verdict') as Angle;
  if (!(angle in ANGLES)) {
    throw new ApiError('invalid_request', `unknown angle: ${body.angle}`);
  }

  // Premium, per §35. Not a paywall on result quality: the verdict, the score,
  // and the full reasoning are all free — this is extra depth on top.
  const plus = await isPlus(ctx.admin, ctx.userId);
  if (!plus) throw new ApiError('forbidden', 'deeper explanations are part of BEFORE Plus');

  // Plus is uncapped, but not unbounded. This costs a model call.
  const profile = await loadUserProfile(ctx.db, ctx.userId);
  const counts = await loadUsageCounts(ctx.admin, ctx.userId, profile.timezone, new Date());
  if (counts.lastMinuteUsed >= ctx.config.quota.analysesPerMinute) {
    throw new ApiError('rate_limited', 'too many requests', 60);
  }

  const { data, error } = await ctx.db
    .from('analyses')
    .select(
      'id, verdict, score, confidence, positive_factors, negative_factors, key_risk, advice, applied_rules, analysis_products(*)',
    )
    .eq('id', id)
    .maybeSingle();

  if (error) throw new ApiError('internal_error', error.message);
  if (!data) throw new ApiError('not_found', 'no such analysis');

  const product = Array.isArray(data.analysis_products)
    ? data.analysis_products[0]
    : data.analysis_products;

  // Only what BEFORE already concluded. No image, no new context, nothing to
  // invent a fact from.
  const summary = {
    product: {
      name: product?.name ?? null,
      brand: product?.brand ?? null,
      category: product?.category ?? 'other',
      subcategory: product?.subcategory ?? null,
      price: product?.price == null ? null : Number(product.price),
      currency: product?.currency ?? null,
      material: product?.material ?? null,
      sources: product?.fact_sources ?? {},
      productUrl: null,
      retailer: null,
      priceConfidence: Number(product?.price_confidence ?? 0),
      identityConfidence: Number(product?.identity_confidence ?? 0),
    },
    signals: {
      verdict: data.verdict,
      score: data.score,
      confidence: Number(data.confidence),
      appliedRules: data.applied_rules ?? [],
    },
    reasoning: {
      positiveFactors: data.positive_factors ?? [],
      negativeFactors: data.negative_factors ?? [],
      keyRisk: data.key_risk,
      advice: data.advice ?? '',
      uncertainties: [],
    },
  };

  const provider = await createProvider(ctx.config.ai, {
    fixtures: mockFixtures.fixtures as never,
  });

  let response;
  try {
    response = await provider.generateExplanation(summary as never, ANGLES[angle]);
  } catch (error) {
    if (error instanceof ProviderError && error.kind === 'content_filtered') {
      throw new ApiError('content_unsupported', 'that could not be explained further');
    }
    throw new ApiError('provider_unavailable', 'we could not get a deeper explanation');
  }

  // The same safety scan as the main analysis. A follow-up is not a loophole.
  const scan = scanStrings([response.raw.trim()]);
  if (scan.blocked || scan.value.length === 0) {
    ctx.log.warn('explain.blocked', { safetyFindings: scan.findings.length });
    throw new ApiError('content_unsupported', 'that could not be explained further');
  }

  await ctx.admin.from('ai_call_log').insert({
    analysis_id: id,
    user_id: ctx.userId,
    request_id: ctx.requestId,
    provider: response.provider,
    model: response.model,
    prompt_version: `explain_${angle}`,
    input_tokens: response.usage.inputTokens,
    output_tokens: response.usage.outputTokens,
    estimated_cost_usd: estimateCostUsd(
      response.model,
      response.usage.inputTokens,
      response.usage.outputTokens,
    ),
    latency_ms: response.latencyMs,
    success: true,
    safety_findings: scan.findings.length,
  });

  ctx.log.info('explain.completed', {
    verdict: data.verdict,
    model: response.model,
    latencyMs: response.latencyMs,
    note: angle,
  });

  return jsonResponse({ angle, explanation: scan.value[0] }, 200);
}

Deno.serve(withContext({ endpoint: '/v1/analyses/:id/explain', methods: ['POST'] }, handler));
