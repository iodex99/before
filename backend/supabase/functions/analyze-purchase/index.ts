/**
 * POST /v1/analyses — the core endpoint.
 *
 * Order of operations matters and is deliberate:
 *
 *   idempotency -> entitlement -> rate limits -> quota -> context -> model
 *   -> validate -> SCORE -> persist -> respond
 *
 * The verdict is computed from validated signals by the deterministic engine
 * before anything else looks at the result. There is no branch in this file
 * where a commercial consideration could reach it (Rule 7).
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import {
  buildUserContext,
  isPlus,
  loadHistory,
  loadImageForModel,
  loadUsageCounts,
  loadUserProfile,
  loadWardrobe,
  readMetadataCache,
  writeMetadataCache,
} from '../_shared/repository.ts';
import { durationBucket } from '../_shared/log.ts';

import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import { assertWithinRateLimits, evaluateQuota, monthWindow } from '@shared/http/quota.ts';
import {
  selectRelevantHistory,
  selectRelevantWardrobe,
  medianCategorySpend,
  type ProductHint,
} from '@shared/context/relevance.ts';
import { buildAnalysisPrompt, estimateTokens, type ProductInput } from '@shared/prompt/builder.ts';
import { SYSTEM_PROMPT, repairInstruction } from '@shared/prompt/system.ts';
import {
  AiSafetyError,
  AiSchemaError,
  PROMPT_VERSION,
  parseAnalysis,
  type ValidatedAnalysis,
} from '@shared/ai/schema.ts';
import { createProvider } from '@shared/ai/factory.ts';
import { ProviderError, type ShoppingAnalysisProvider } from '@shared/ai/provider.ts';
import { estimateCostUsd } from '@shared/ai/pricing.ts';
import { PurchaseScoreEngine } from '@shared/scoring/engine.ts';
import { SCORE_ALGORITHM_VERSION } from '@shared/scoring/weights.ts';
import {
  EMPTY_METADATA,
  UrlUnreadableError,
  fetchProductMetadata,
  normaliseProductUrl,
  type ProductMetadata,
} from '@shared/product/metadata.ts';
import type { AnalysisResponse, Category, InputType } from '@shared/types.ts';
import { CATEGORIES, INPUT_TYPES } from '@shared/types.ts';

import mockFixtures from '@shared/fixtures/ai-responses.json' with { type: 'json' };

interface AnalyzeRequestBody {
  /** Storage path inside the caller's own prefix. Uploaded before this call. */
  imagePath?: string;
  productUrl?: string;
  userNote?: string;
  inputType?: InputType;
  /** Lets the relevance filter narrow the wardrobe before the model has run. */
  categoryHint?: Category;
  subcategoryHint?: string;
}

// ---------------------------------------------------------------------------

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const body = await readJson<AnalyzeRequestBody>(request);

  if (!body.imagePath && !body.productUrl) {
    throw new ApiError('invalid_request', 'an image or a product URL is required');
  }
  const inputType: InputType =
    body.inputType && (INPUT_TYPES as readonly string[]).includes(body.inputType)
      ? body.inputType
      : body.imagePath
        ? 'photo'
        : 'url';

  // 1. Idempotency (spec §50). A double-tap must not cost a quota unit.
  const idempotencyKey = request.headers.get('idempotency-key');
  const requestHash = await hashRequest(body);
  if (idempotencyKey) {
    const existing = await resolveIdempotent(ctx, idempotencyKey, requestHash);
    if (existing) return existing;
  }

  // 2. Who is this, and what are they entitled to.
  const profile = await loadUserProfile(ctx.db, ctx.userId);
  const plus = await isPlus(ctx.admin, ctx.userId);
  const counts = await loadUsageCounts(ctx.admin, ctx.userId, profile.timezone, new Date());

  // Anti-abuse limits apply to everyone, Plus included (spec §52).
  assertWithinRateLimits(counts, ctx.config.quota);

  const quota = evaluateQuota(counts, plus, ctx.config.quota);
  if (!quota.allowed) {
    // A free user out of checks gets an upgrade offer. A Plus subscriber past
    // the fair-use ceiling already pays us, so they get a different answer.
    if (quota.fairUseExceeded) {
      const { end } = monthWindow(new Date(), profile.timezone);
      const secondsUntilReset = Math.max(60, Math.ceil((end.getTime() - Date.now()) / 1000));
      ctx.log.warn('analysis.fair_use_exceeded', { isPlus: true, note: `${counts.monthUsed} this month` });
      throw new ApiError('fair_use_exceeded', `${counts.monthUsed} used this month`, secondsUntilReset);
    }
    throw new ApiError('quota_exceeded', `${counts.monthUsed} used this month`);
  }

  // 3. Open the analysis row so concurrency accounting sees it immediately.
  const { data: created, error: createError } = await ctx.db
    .from('analyses')
    .insert({
      user_id: ctx.userId,
      status: 'processing',
      input_type: inputType,
      image_path: body.imagePath ?? null,
      source_url: body.productUrl ?? null,
      user_note: body.userNote?.slice(0, 500) ?? null,
      prompt_version: PROMPT_VERSION,
      score_algorithm_version: SCORE_ALGORITHM_VERSION,
    })
    .select('id, created_at')
    .single();

  if (createError || !created) {
    throw new ApiError('internal_error', `could not open analysis: ${createError?.message}`);
  }

  const analysisId: string = created.id;
  const log = ctx.log.child({ inputType });

  try {
    const response = await runAnalysis(ctx, {
      analysisId,
      createdAt: created.created_at,
      body,
      inputType,
      profile,
      plus,
      log,
    });

    if (idempotencyKey) {
      await ctx.admin.from('idempotency_keys').upsert(
        { user_id: ctx.userId, key: idempotencyKey, analysis_id: analysisId, request_hash: requestHash },
        { onConflict: 'user_id,key' },
      );
    }

    return response;
  } catch (error) {
    await ctx.db
      .from('analyses')
      .update({
        status: 'failed',
        failure_code: error instanceof ApiError ? error.code : 'analysis_failed',
      })
      .eq('id', analysisId);
    throw error;
  }
}

// ---------------------------------------------------------------------------

interface RunArgs {
  analysisId: string;
  createdAt: string;
  body: AnalyzeRequestBody;
  inputType: InputType;
  profile: Awaited<ReturnType<typeof loadUserProfile>>;
  plus: boolean;
  log: RequestContext['log'];
}

async function runAnalysis(ctx: RequestContext, args: RunArgs): Promise<Response> {
  const { analysisId, body, profile, log } = args;

  // 4. What the product page says about itself, if anything.
  let metadata: ProductMetadata = { ...EMPTY_METADATA };
  let normalisedUrl: string | null = null;

  if (body.productUrl) {
    try {
      const url = normaliseProductUrl(body.productUrl);
      normalisedUrl = url.toString();
      const cached = await readMetadataCache(ctx.admin, normalisedUrl);
      if (cached) {
        metadata = cached;
        log.info('metadata.cache_hit', { cacheHit: true });
      } else {
        const fetched = await fetchProductMetadata(normalisedUrl);
        metadata = fetched.metadata;
        await writeMetadataCache(ctx.admin, normalisedUrl, metadata);
        log.info('metadata.fetched', { cacheHit: false });
      }
    } catch (error) {
      // A page we cannot read is a normal outcome, not a failure — as long as
      // there is an image to fall back to (spec §19, §45).
      if (!body.imagePath) {
        throw new ApiError(
          'url_unreadable',
          error instanceof UrlUnreadableError ? error.reason : 'metadata fetch failed',
        );
      }
      log.warn('metadata.unreadable', {
        note: error instanceof UrlUnreadableError ? error.reason : 'fetch failed',
      });
    }
  }

  // 5. The image.
  const image = body.imagePath
    ? await loadImageForModel(ctx.admin, body.imagePath, ctx.config.quota.maxUploadBytes)
    : null;

  // 6. The relevant slice of what this user owns and has decided before.
  const hint: ProductHint = {
    category: body.categoryHint && (CATEGORIES as readonly string[]).includes(body.categoryHint)
      ? body.categoryHint
      : null,
    subcategory: body.subcategoryHint ?? null,
    colors: [],
    styleTags: profile.preferences.favoriteStyles,
  };

  const [wardrobe, history] = await Promise.all([
    loadWardrobe(ctx.db, ctx.userId),
    loadHistory(ctx.db, ctx.userId),
  ]);

  const relevantWardrobe = selectRelevantWardrobe(wardrobe, hint);
  const relevantHistory = selectRelevantHistory(history, hint);
  const categoryAverageSpend = hint.category
    ? medianCategorySpend(history, hint.category, hint.subcategory)
    : null;

  const productInput: ProductInput = {
    title: metadata.title,
    brand: metadata.brand,
    price: metadata.price,
    currency: metadata.currency,
    retailer: metadata.retailer,
    availability: metadata.availability,
    url: normalisedUrl,
    fromStructuredMetadata: metadata.structured,
    hasImage: image !== null,
    userNote: body.userNote?.slice(0, 500) ?? null,
  };

  const userPrompt = buildAnalysisPrompt({
    product: productInput,
    user: buildUserContext(profile, history.length, {}),
    wardrobe: relevantWardrobe,
    history: relevantHistory,
    categoryAverageSpend,
  });

  // 7. The model.
  const provider = await createProvider(ctx.config.ai, {
    fixtures: mockFixtures.fixtures as never,
    mockLatencyMs: ctx.config.appEnv === 'development' ? 600 : 0,
  });

  const { validated, providerMeta, retried } = await callWithOneRepair(provider, {
    systemPrompt: SYSTEM_PROMPT,
    userPrompt,
    image,
    maxOutputTokens: ctx.config.ai.maxOutputTokens,
    timeoutMs: ctx.config.ai.timeoutMs,
    requestId: analysisId,
  });

  // 8. THE SCORE. Deterministic, from validated signals only.
  const priceKnown = metadata.price !== null || validated.product.price !== null;
  const price = metadata.price ?? validated.product.price;

  const scored = PurchaseScoreEngine.score({
    signals: validated.signals,
    availability: validated.availability,
    context: {
      hasWardrobeData: wardrobe.length > 0,
      wardrobeItemCount: wardrobe.length,
      priceKnown,
      price,
      budgetSensitivity: profile.preferences.budgetSensitivity,
      categoryAverageSpend:
        categoryAverageSpend ??
        medianCategorySpend(history, validated.product.category, validated.product.subcategory),
      identityConfidence: validated.product.identityConfidence,
    },
    aiConfidence: validated.confidence,
  });

  // 9. Persist. The product page is the stronger source when it disagrees with
  // the image, so metadata wins and is marked confirmed.
  const resolvedPrice = metadata.price ?? validated.product.price;
  const factSources = {
    ...validated.product.sources,
    ...(metadata.structured && metadata.price !== null ? { price: 'confirmed' as const } : {}),
    ...(metadata.structured && metadata.brand ? { brand: 'confirmed' as const } : {}),
    ...(normalisedUrl ? { productUrl: 'confirmed' as const } : {}),
  };

  const completedAt = new Date().toISOString();

  await ctx.db
    .from('analyses')
    .update({
      status: 'completed',
      score: scored.score,
      verdict: scored.verdict,
      suggested_action: scored.suggestedAction,
      confidence: scored.confidence,
      positive_factors: validated.reasoning.positiveFactors,
      negative_factors: validated.reasoning.negativeFactors,
      key_risk: validated.reasoning.keyRisk,
      advice: validated.reasoning.advice,
      uncertainties: validated.reasoning.uncertainties,
      applied_rules: scored.appliedRules,
      ai_provider: providerMeta.provider,
      ai_model: providerMeta.model,
      completed_at: completedAt,
    })
    .eq('id', analysisId);

  await ctx.db.from('analysis_products').upsert({
    analysis_id: analysisId,
    user_id: ctx.userId,
    name: metadata.title ?? validated.product.name,
    brand: metadata.brand ?? validated.product.brand,
    category: validated.product.category,
    subcategory: validated.product.subcategory,
    material: validated.product.material,
    retailer: metadata.retailer ?? validated.product.retailer,
    price: resolvedPrice,
    currency: metadata.currency ?? validated.product.currency ?? (resolvedPrice !== null ? profile.currency : null),
    product_url: normalisedUrl,
    fact_sources: factSources,
    price_confidence: metadata.structured && metadata.price !== null ? 1 : validated.product.priceConfidence,
    identity_confidence: validated.product.identityConfidence,
    colors: validated.visual.colors,
    style_tags: validated.visual.styleTags,
    occasion_tags: validated.visual.occasionTags,
    versatility_estimate: Math.round(validated.visual.versatilityEstimate),
  });

  await ctx.db.from('analysis_factors').insert(
    scored.factors.map((factor) => ({
      analysis_id: analysisId,
      user_id: ctx.userId,
      signal: factor.key,
      value: factor.value,
      weight: factor.weight,
      included: factor.included,
      excluded_reason: factor.excludedReason,
      raw_signal: Math.round(validated.signals[factor.key]),
    })),
  );

  // 10. Consume quota. Only after a successful analysis — a failure must not
  // cost someone one of their five.
  await ctx.admin.from('usage_ledger').insert({
    user_id: ctx.userId,
    analysis_id: analysisId,
    kind: 'analysis',
    counted_against_free_quota: !args.plus,
  });

  // 11. Cost and observability. Never surfaced to the user.
  const estimatedCost = estimateCostUsd(
    providerMeta.model,
    providerMeta.usage.inputTokens,
    providerMeta.usage.outputTokens,
  );

  await ctx.admin.from('ai_call_log').insert({
    analysis_id: analysisId,
    user_id: ctx.userId,
    request_id: ctx.requestId,
    provider: providerMeta.provider,
    model: providerMeta.model,
    prompt_version: PROMPT_VERSION,
    input_tokens: providerMeta.usage.inputTokens,
    output_tokens: providerMeta.usage.outputTokens,
    estimated_cost_usd: estimatedCost,
    latency_ms: providerMeta.latencyMs,
    success: true,
    safety_findings: validated.safetyFindings.length,
    schema_warnings: validated.warnings.length,
    retried,
  });

  log.info('analysis.completed', {
    verdict: scored.verdict,
    score: scored.score,
    provider: providerMeta.provider,
    model: providerMeta.model,
    promptVersion: PROMPT_VERSION,
    scoreVersion: SCORE_ALGORITHM_VERSION,
    // The provider reports null for "not supplied"; the logger omits a field by
    // leaving it undefined. Converting here keeps "unknown" out of the log as a
    // literal null.
    inputTokens: providerMeta.usage.inputTokens ?? undefined,
    outputTokens: providerMeta.usage.outputTokens ?? undefined,
    estimatedCostUsd: estimatedCost ?? undefined,
    latencyMs: providerMeta.latencyMs,
    durationBucket: durationBucket(providerMeta.latencyMs),
    safetyFindings: validated.safetyFindings.length,
    schemaWarnings: validated.warnings.length,
    retried,
    isPlus: args.plus,
    note: `prompt≈${estimateTokens(userPrompt)}tok`,
  });

  const payload: AnalysisResponse = {
    analysisId,
    status: 'completed',
    createdAt: args.createdAt,
    product: {
      name: metadata.title ?? validated.product.name,
      brand: metadata.brand ?? validated.product.brand,
      category: validated.product.category,
      subcategory: validated.product.subcategory,
      price: resolvedPrice,
      currency: metadata.currency ?? validated.product.currency,
      retailer: metadata.retailer ?? validated.product.retailer,
      material: validated.product.material,
      productUrl: normalisedUrl,
      sources: factSources,
      priceConfidence: validated.product.priceConfidence,
      identityConfidence: validated.product.identityConfidence,
    },
    visual: validated.visual,
    score: scored.score,
    verdict: scored.verdict,
    confidence: scored.confidence,
    confidenceLabel: scored.confidenceLabel,
    factors: scored.factors,
    reasons: {
      positive: validated.reasoning.positiveFactors,
      negative: validated.reasoning.negativeFactors,
      keyRisk: validated.reasoning.keyRisk,
      advice: validated.reasoning.advice,
      uncertainties: validated.reasoning.uncertainties,
    },
    suggestedAction: scored.suggestedAction,
    imageUrl: await signedImageUrl(ctx, body.imagePath ?? null),
    promptVersion: PROMPT_VERSION,
    scoreAlgorithmVersion: SCORE_ALGORITHM_VERSION,
  };

  return jsonResponse(payload, 200);
}

// ---------------------------------------------------------------------------
// Model call with a single repair attempt
// ---------------------------------------------------------------------------

interface CallArgs {
  systemPrompt: string;
  userPrompt: string;
  image: { data: string; mediaType: 'image/jpeg' | 'image/png' | 'image/webp' } | null;
  maxOutputTokens: number;
  timeoutMs: number;
  requestId: string;
}

/**
 * One retry, and only for a malformed response.
 *
 * A safety block is never retried — asking the same model the same question
 * again is not a fix, and it doubles the cost of a request that is going to
 * fail. A transport error is not retried here either; the SDK already did.
 */
async function callWithOneRepair(
  provider: ShoppingAnalysisProvider,
  args: CallArgs,
): Promise<{
  validated: ValidatedAnalysis;
  providerMeta: Awaited<ReturnType<ShoppingAnalysisProvider['analyzePurchase']>>;
  retried: boolean;
}> {
  let lastIssues: string[] = [];

  for (let attempt = 0; attempt < 2; attempt++) {
    const userPrompt =
      attempt === 0 ? args.userPrompt : `${args.userPrompt}\n\n${repairInstruction(lastIssues)}`;

    let providerMeta;
    try {
      providerMeta = await provider.analyzePurchase({ ...args, userPrompt });
    } catch (error) {
      throw toApiError(error);
    }

    try {
      return { validated: parseAnalysis(providerMeta.raw), providerMeta, retried: attempt > 0 };
    } catch (error) {
      if (error instanceof AiSafetyError) {
        // Deliberately terminal. See the note above.
        throw new ApiError('content_unsupported', `safety: ${error.findings.map((f) => f.rule).join(',')}`);
      }
      if (error instanceof AiSchemaError && attempt === 0) {
        lastIssues = error.issues;
        continue;
      }
      throw new ApiError('analysis_failed', error instanceof Error ? error.message : 'invalid model output');
    }
  }

  throw new ApiError('analysis_failed', 'model output failed validation twice');
}

function toApiError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;
  if (error instanceof ProviderError) {
    switch (error.kind) {
      case 'content_filtered':
        return new ApiError('content_unsupported', error.message);
      case 'rate_limited':
        return new ApiError('rate_limited', 'provider rate limit', 30);
      case 'auth':
      case 'bad_request':
        return new ApiError('analysis_failed', error.message);
      case 'timeout':
      case 'network':
      case 'server_error':
        return new ApiError('provider_unavailable', error.message);
      default:
        return new ApiError('analysis_failed', error.message);
    }
  }
  return new ApiError('analysis_failed', 'unexpected failure');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function hashRequest(body: AnalyzeRequestBody): Promise<string> {
  const canonical = JSON.stringify({
    imagePath: body.imagePath ?? null,
    productUrl: body.productUrl ?? null,
    userNote: body.userNote ?? null,
  });
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Return the existing analysis for a repeated Idempotency-Key.
 *
 * A repeat with a DIFFERENT body is a client bug, and answering it with the
 * wrong analysis would be worse than failing, so it gets a 409.
 */
async function resolveIdempotent(
  ctx: RequestContext,
  key: string,
  requestHash: string,
): Promise<Response | null> {
  const { data } = await ctx.admin
    .from('idempotency_keys')
    .select('analysis_id, request_hash')
    .eq('user_id', ctx.userId)
    .eq('key', key)
    .maybeSingle();

  if (!data) return null;
  if (data.request_hash !== requestHash) {
    throw new ApiError('conflict', 'idempotency key reused with a different body');
  }
  if (!data.analysis_id) return null;

  const existing = await loadAnalysisResponse(ctx, data.analysis_id);
  if (!existing) return null;

  ctx.log.info('analysis.idempotent_replay', { note: 'returned existing analysis' });
  return jsonResponse(existing, 200, { 'idempotent-replay': 'true' });
}

async function loadAnalysisResponse(
  ctx: RequestContext,
  analysisId: string,
): Promise<AnalysisResponse | null> {
  const { data } = await ctx.db
    .from('analyses')
    .select('*, analysis_products(*), analysis_factors(*)')
    .eq('id', analysisId)
    .maybeSingle();

  if (!data || data.status !== 'completed') return null;

  const product = Array.isArray(data.analysis_products)
    ? data.analysis_products[0]
    : data.analysis_products;
  const factors = (data.analysis_factors ?? []) as Array<Record<string, unknown>>;

  return {
    analysisId: data.id,
    status: 'completed',
    createdAt: data.created_at,
    product: {
      name: product?.name ?? null,
      brand: product?.brand ?? null,
      category: product?.category ?? 'other',
      subcategory: product?.subcategory ?? null,
      price: product?.price == null ? null : Number(product.price),
      currency: product?.currency ?? null,
      retailer: product?.retailer ?? null,
      material: product?.material ?? null,
      productUrl: product?.product_url ?? null,
      sources: product?.fact_sources ?? {},
      priceConfidence: Number(product?.price_confidence ?? 0),
      identityConfidence: Number(product?.identity_confidence ?? 0),
    },
    visual: {
      colors: product?.colors ?? [],
      styleTags: product?.style_tags ?? [],
      occasionTags: product?.occasion_tags ?? [],
      versatilityEstimate: Number(product?.versatility_estimate ?? 0),
      visualQualityConfidence: 0,
    },
    score: data.score,
    verdict: data.verdict,
    confidence: Number(data.confidence),
    confidenceLabel: data.confidence >= 0.75 ? 'high' : data.confidence >= 0.5 ? 'medium' : 'low',
    factors: factors.map((f) => ({
      key: f.signal as never,
      label: String(f.signal),
      value: Number(f.value),
      weight: Number(f.weight),
      included: Boolean(f.included),
      excludedReason: (f.excluded_reason as string | null) ?? null,
    })),
    reasons: {
      positive: data.positive_factors ?? [],
      negative: data.negative_factors ?? [],
      keyRisk: data.key_risk,
      advice: data.advice ?? '',
      uncertainties: data.uncertainties ?? [],
    },
    suggestedAction: data.suggested_action,
    imageUrl: await signedImageUrl(ctx, data.image_path),
    promptVersion: data.prompt_version,
    scoreAlgorithmVersion: data.score_algorithm_version,
  };
}

/** Short-lived signed URL. Buckets are private; there is no public fallback. */
async function signedImageUrl(ctx: RequestContext, path: string | null): Promise<string | null> {
  if (!path) return null;
  const { data } = await ctx.admin.storage.from('analyses').createSignedUrl(path, 3600);
  return data?.signedUrl ?? null;
}

Deno.serve(withContext({ endpoint: '/v1/analyses', methods: ['POST'] }, handler));
