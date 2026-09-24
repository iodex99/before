/**
 * BEFORE — AI response schema and validator.
 *
 * Raw model output is untrusted input. It is parsed, structurally validated,
 * range-clamped, length-capped, and safety-scanned before any part of it is
 * allowed near a user or the score engine.
 *
 * The model's own `suggested_action` is parsed but NEVER used for the verdict.
 * It is retained only so we can measure model-vs-engine agreement offline.
 */

import {
  type AnalysisReasoning,
  type AnalysisSignals,
  type Category,
  type FactSource,
  type ProductFactField,
  type ProductFacts,
  type SignalAvailability,
  type SignalKey,
  type SuggestedAction,
  type VisualAnalysis,
  CATEGORIES,
  FACT_SOURCES,
  SIGNAL_KEYS,
  SUGGESTED_ACTIONS,
} from '../types.ts';
import { scanOptional, scanStrings, type SafetyFinding } from './safety.ts';

export const PROMPT_VERSION = 'purchase_analysis_v1';

/** Caps that keep reasoning readable in under ten seconds (spec §94, §95). */
export const LIMITS = {
  positiveFactors: { max: 4, chars: 140 },
  negativeFactors: { max: 3, chars: 140 },
  uncertainties: { max: 4, chars: 120 },
  keyRisk: { chars: 160 },
  advice: { chars: 180 },
  tags: { max: 8, chars: 32 },
  colors: { max: 6, chars: 32 },
  name: { chars: 120 },
  brand: { chars: 60 },
} as const;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export class AiSchemaError extends Error {
  readonly issues: string[];
  constructor(issues: string[]) {
    super(`AI response failed validation: ${issues.join('; ')}`);
    this.name = 'AiSchemaError';
    this.issues = issues;
  }
}

export class AiSafetyError extends Error {
  readonly findings: SafetyFinding[];
  constructor(findings: SafetyFinding[]) {
    super(`AI response blocked by safety scan: ${findings.map((f) => f.rule).join(', ')}`);
    this.name = 'AiSafetyError';
    this.findings = findings;
  }
}

// ---------------------------------------------------------------------------
// Validated shape
// ---------------------------------------------------------------------------

export interface ValidatedAnalysis {
  product: ProductFacts;
  visual: VisualAnalysis;
  signals: AnalysisSignals;
  availability: SignalAvailability;
  reasoning: AnalysisReasoning;
  confidence: number;
  /** Advisory only. Never reaches the verdict. Kept for offline evaluation. */
  modelSuggestedAction: SuggestedAction | null;
  /** Non-fatal problems: clamped ranges, truncated strings, stripped lines. */
  warnings: string[];
  safetyFindings: SafetyFinding[];
}

// ---------------------------------------------------------------------------
// Primitive coercion helpers. Every one records a warning rather than throwing,
// except where the field is structural.
// ---------------------------------------------------------------------------

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

function num(
  value: unknown,
  field: string,
  min: number,
  max: number,
  fallback: number,
  warnings: string[],
): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    warnings.push(`${field}: not a finite number, defaulted to ${fallback}`);
    return fallback;
  }
  if (value < min || value > max) {
    warnings.push(`${field}: ${value} outside ${min}..${max}, clamped`);
    return Math.min(max, Math.max(min, value));
  }
  return value;
}

function str(value: unknown, field: string, maxChars: number, warnings: string[]): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed === '' || trimmed.toLowerCase() === 'null' || trimmed.toLowerCase() === 'unknown') {
    return null;
  }
  if (trimmed.length > maxChars) {
    warnings.push(`${field}: truncated from ${trimmed.length} to ${maxChars} chars`);
    return trimmed.slice(0, maxChars).trimEnd();
  }
  return trimmed;
}

function strArray(
  value: unknown,
  field: string,
  maxItems: number,
  maxChars: number,
  warnings: string[],
): string[] {
  if (!Array.isArray(value)) return [];
  const out: string[] = [];
  for (const entry of value) {
    if (out.length >= maxItems) {
      warnings.push(`${field}: dropped extra entries beyond ${maxItems}`);
      break;
    }
    const s = str(entry, field, maxChars, warnings);
    if (s) out.push(s);
  }
  return out;
}

function enumOr<T extends string>(
  value: unknown,
  allowed: readonly T[],
  fallback: T,
  field: string,
  warnings: string[],
): T {
  if (typeof value === 'string' && (allowed as readonly string[]).includes(value)) {
    return value as T;
  }
  if (value !== null && value !== undefined) {
    warnings.push(`${field}: "${String(value)}" is not a known value, defaulted to "${fallback}"`);
  }
  return fallback;
}

/**
 * ISO-4217-ish check. We do not maintain a currency table server-side; we only
 * reject anything that clearly is not a currency code so a symbol or a sentence
 * never ends up stored as one.
 */
function currencyCode(value: unknown, warnings: string[]): string | null {
  if (typeof value !== 'string') return null;
  const code = value.trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(code)) {
    if (code !== '') warnings.push(`product.currency: "${value}" is not a 3-letter code, dropped`);
    return null;
  }
  return code;
}

/** Single source of truth for the fields that carry provenance. */
export const PRODUCT_FACT_FIELDS: readonly ProductFactField[] = [
  'name',
  'brand',
  'category',
  'subcategory',
  'price',
  'currency',
  'retailer',
  'material',
  'productUrl',
] as const;

function factSources(value: unknown, warnings: string[]): Partial<Record<ProductFactField, FactSource>> {
  const out: Partial<Record<ProductFactField, FactSource>> = {};
  if (!isObject(value)) return out;
  for (const field of PRODUCT_FACT_FIELDS) {
    const raw = value[field] ?? value[field.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`)];
    if (raw === undefined) continue;
    out[field] = enumOr(raw, FACT_SOURCES, 'unknown', `product.sources.${field}`, warnings);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/**
 * Models sometimes wrap JSON in prose or a fenced block despite instructions.
 * Recover the object rather than failing the user's analysis over formatting.
 */
export function extractJson(raw: string): unknown {
  const trimmed = raw.trim();
  const candidates: string[] = [trimmed];

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced?.[1]) candidates.push(fenced[1].trim());

  const first = trimmed.indexOf('{');
  const last = trimmed.lastIndexOf('}');
  if (first !== -1 && last > first) candidates.push(trimmed.slice(first, last + 1));

  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate);
    } catch {
      // try the next shape
    }
  }
  throw new AiSchemaError(['response was not valid JSON']);
}

/**
 * Validate a parsed AI response.
 *
 * Structural problems throw. Recoverable problems (out-of-range numbers, long
 * strings, unknown enum members) are corrected and recorded in `warnings`.
 * Safety violations either strip a line or throw AiSafetyError.
 */
export function validateAnalysis(input: unknown): ValidatedAnalysis {
  const issues: string[] = [];
  const warnings: string[] = [];

  if (!isObject(input)) throw new AiSchemaError(['response was not a JSON object']);

  const rawProduct = isObject(input.product) ? input.product : null;
  const rawVisual = isObject(input.visual_analysis) ? input.visual_analysis : null;
  const rawSignals = isObject(input.signals) ? input.signals : null;
  const rawReasoning = isObject(input.reasoning) ? input.reasoning : null;
  const rawRecommendation = isObject(input.recommendation) ? input.recommendation : null;

  if (!rawProduct) issues.push('missing "product" object');
  if (!rawSignals) issues.push('missing "signals" object');
  if (!rawReasoning) issues.push('missing "reasoning" object');
  if (issues.length > 0) throw new AiSchemaError(issues);

  // -- signals ---------------------------------------------------------------
  const signals = {} as AnalysisSignals;
  const availability = {} as SignalAvailability;
  const rawAvailability = isObject(input.signal_availability) ? input.signal_availability : {};

  for (const key of SIGNAL_KEYS) {
    const raw = rawSignals![key as string];
    if (raw === undefined || raw === null) {
      issues.push(`signals.${key} is missing`);
      signals[key as SignalKey] = 0;
      availability[key as SignalKey] = false;
      continue;
    }
    signals[key as SignalKey] = num(raw, `signals.${key}`, 0, 100, 50, warnings);
    // Default to available. The model must opt OUT of a signal explicitly,
    // which keeps an older model that omits the field working correctly.
    const flag = rawAvailability[key as string];
    availability[key as SignalKey] = flag === undefined ? true : flag !== false;
  }
  if (issues.length > 0) throw new AiSchemaError(issues);

  // -- product ---------------------------------------------------------------
  const product: ProductFacts = {
    name: str(rawProduct!.name, 'product.name', LIMITS.name.chars, warnings),
    brand: str(rawProduct!.brand, 'product.brand', LIMITS.brand.chars, warnings),
    category: enumOr<Category>(rawProduct!.category, CATEGORIES, 'other', 'product.category', warnings),
    subcategory: str(rawProduct!.subcategory, 'product.subcategory', 40, warnings),
    price:
      typeof rawProduct!.price === 'number' && Number.isFinite(rawProduct!.price) && rawProduct!.price > 0
        ? num(rawProduct!.price, 'product.price', 0, 1_000_000, 0, warnings)
        : null,
    currency: currencyCode(rawProduct!.currency, warnings),
    retailer: str(rawProduct!.retailer, 'product.retailer', 60, warnings),
    material: str(rawProduct!.material, 'product.material', 80, warnings),
    // Rule 6: a product URL is only ever echoed back from what the user gave us.
    // The model is never permitted to supply one, so it is dropped here.
    productUrl: null,
    sources: factSources(rawProduct!.sources, warnings),
    priceConfidence: num(rawProduct!.price_confidence, 'product.price_confidence', 0, 1, 0, warnings),
    identityConfidence: num(
      rawProduct!.identity_confidence,
      'product.identity_confidence',
      0,
      1,
      0.5,
      warnings,
    ),
  };

  if (rawProduct!.product_url !== undefined && rawProduct!.product_url !== null) {
    warnings.push('product.product_url: model-supplied URLs are discarded (Rule 6)');
  }

  // A price with no provenance is an estimate, never a confirmed fact.
  if (product.price !== null && product.sources.price === undefined) {
    product.sources.price = product.priceConfidence >= 0.9 ? 'confirmed' : 'estimated';
  }

  // -- visual ----------------------------------------------------------------
  const visual: VisualAnalysis = {
    colors: strArray(rawVisual?.colors, 'visual.colors', LIMITS.colors.max, LIMITS.colors.chars, warnings),
    styleTags: strArray(rawVisual?.style_tags, 'visual.style_tags', LIMITS.tags.max, LIMITS.tags.chars, warnings),
    occasionTags: strArray(
      rawVisual?.occasion_tags,
      'visual.occasion_tags',
      LIMITS.tags.max,
      LIMITS.tags.chars,
      warnings,
    ),
    versatilityEstimate: num(rawVisual?.versatility_estimate, 'visual.versatility_estimate', 0, 100, 50, warnings),
    visualQualityConfidence: num(
      rawVisual?.visual_quality_confidence,
      'visual.visual_quality_confidence',
      0,
      1,
      0.5,
      warnings,
    ),
  };

  // -- reasoning, with the safety scan --------------------------------------
  const positiveRaw = strArray(
    rawReasoning!.positive_factors,
    'reasoning.positive_factors',
    LIMITS.positiveFactors.max,
    LIMITS.positiveFactors.chars,
    warnings,
  );
  const negativeRaw = strArray(
    rawReasoning!.negative_factors,
    'reasoning.negative_factors',
    LIMITS.negativeFactors.max,
    LIMITS.negativeFactors.chars,
    warnings,
  );
  const uncertaintiesRaw = strArray(
    rawReasoning!.uncertainties,
    'reasoning.uncertainties',
    LIMITS.uncertainties.max,
    LIMITS.uncertainties.chars,
    warnings,
  );

  const positive = scanStrings(positiveRaw);
  const negative = scanStrings(negativeRaw);
  const uncertainties = scanStrings(uncertaintiesRaw);
  const keyRisk = scanOptional(str(rawReasoning!.key_risk, 'reasoning.key_risk', LIMITS.keyRisk.chars, warnings));
  const advice = scanOptional(str(rawReasoning!.advice, 'reasoning.advice', LIMITS.advice.chars, warnings));

  const safetyFindings: SafetyFinding[] = [
    ...positive.findings,
    ...negative.findings,
    ...uncertainties.findings,
    ...keyRisk.findings,
    ...advice.findings,
  ];

  if (
    positive.blocked ||
    negative.blocked ||
    uncertainties.blocked ||
    keyRisk.blocked ||
    advice.blocked
  ) {
    throw new AiSafetyError(safetyFindings);
  }

  if (safetyFindings.length > 0) {
    warnings.push(`safety: stripped ${safetyFindings.length} line(s)`);
  }

  const reasoning: AnalysisReasoning = {
    positiveFactors: positive.value,
    negativeFactors: negative.value,
    keyRisk: keyRisk.value,
    advice: advice.value ?? '',
    uncertainties: uncertainties.value,
  };

  // -- confidence and the advisory suggestion -------------------------------
  const confidence = num(rawRecommendation?.confidence, 'recommendation.confidence', 0, 1, 0.5, warnings);

  let modelSuggestedAction: SuggestedAction | null = null;
  const rawAction = rawRecommendation?.suggested_action;
  if (typeof rawAction === 'string') {
    const normalised = rawAction.trim().toUpperCase();
    // Accept both the verdict vocabulary and the action vocabulary; the model is
    // told to emit a verdict, and either is only ever advisory.
    const asAction = (SUGGESTED_ACTIONS as readonly string[]).includes(normalised)
      ? (normalised as SuggestedAction)
      : normalised === 'BUY'
        ? 'BUY_IT'
        : normalised === 'WAIT'
          ? 'WAIT_48_HOURS'
          : normalised === 'BYE'
            ? 'SKIP_IT'
            : null;
    modelSuggestedAction = asAction;
  }

  return {
    product,
    visual,
    signals,
    availability,
    reasoning,
    confidence,
    modelSuggestedAction,
    warnings,
    safetyFindings,
  };
}

/** Parse-and-validate in one step. */
export function parseAnalysis(raw: string): ValidatedAnalysis {
  return validateAnalysis(extractJson(raw));
}

/**
 * The JSON Schema handed to providers that support structured output.
 * Kept in this file so it cannot drift from the validator above.
 */
export const ANALYSIS_JSON_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['product', 'visual_analysis', 'signals', 'signal_availability', 'reasoning', 'recommendation'],
  properties: {
    product: {
      type: 'object',
      additionalProperties: false,
      required: ['name', 'brand', 'category', 'price', 'price_confidence', 'identity_confidence'],
      properties: {
        name: { type: ['string', 'null'] },
        brand: { type: ['string', 'null'] },
        category: { type: 'string', enum: [...CATEGORIES] },
        subcategory: { type: ['string', 'null'] },
        price: { type: ['number', 'null'] },
        currency: { type: ['string', 'null'] },
        retailer: { type: ['string', 'null'] },
        material: { type: ['string', 'null'] },
        // Explicit properties rather than additionalProperties, so the schema
        // stays valid under strict tool use.
        sources: {
          type: 'object',
          additionalProperties: false,
          properties: Object.fromEntries(
            PRODUCT_FACT_FIELDS.map((f) => [f, { type: 'string', enum: [...FACT_SOURCES] }]),
          ),
        },
        price_confidence: { type: 'number', minimum: 0, maximum: 1 },
        identity_confidence: { type: 'number', minimum: 0, maximum: 1 },
      },
    },
    visual_analysis: {
      type: 'object',
      additionalProperties: false,
      required: ['colors', 'style_tags', 'occasion_tags', 'versatility_estimate', 'visual_quality_confidence'],
      properties: {
        colors: { type: 'array', items: { type: 'string' }, maxItems: LIMITS.colors.max },
        style_tags: { type: 'array', items: { type: 'string' }, maxItems: LIMITS.tags.max },
        occasion_tags: { type: 'array', items: { type: 'string' }, maxItems: LIMITS.tags.max },
        versatility_estimate: { type: 'number', minimum: 0, maximum: 100 },
        visual_quality_confidence: { type: 'number', minimum: 0, maximum: 1 },
      },
    },
    signals: {
      type: 'object',
      additionalProperties: false,
      required: [...SIGNAL_KEYS],
      properties: Object.fromEntries(
        SIGNAL_KEYS.map((k) => [k, { type: 'number', minimum: 0, maximum: 100 }]),
      ),
    },
    signal_availability: {
      type: 'object',
      additionalProperties: false,
      required: [...SIGNAL_KEYS],
      properties: Object.fromEntries(SIGNAL_KEYS.map((k) => [k, { type: 'boolean' }])),
    },
    reasoning: {
      type: 'object',
      additionalProperties: false,
      required: ['positive_factors', 'negative_factors', 'key_risk', 'advice', 'uncertainties'],
      properties: {
        positive_factors: {
          type: 'array',
          items: { type: 'string', maxLength: LIMITS.positiveFactors.chars },
          maxItems: LIMITS.positiveFactors.max,
        },
        negative_factors: {
          type: 'array',
          items: { type: 'string', maxLength: LIMITS.negativeFactors.chars },
          maxItems: LIMITS.negativeFactors.max,
        },
        key_risk: { type: ['string', 'null'], maxLength: LIMITS.keyRisk.chars },
        advice: { type: 'string', maxLength: LIMITS.advice.chars },
        uncertainties: {
          type: 'array',
          items: { type: 'string', maxLength: LIMITS.uncertainties.chars },
          maxItems: LIMITS.uncertainties.max,
        },
      },
    },
    recommendation: {
      type: 'object',
      additionalProperties: false,
      required: ['suggested_action', 'confidence'],
      properties: {
        suggested_action: { type: 'string', enum: ['BUY', 'WAIT', 'BYE'] },
        confidence: { type: 'number', minimum: 0, maximum: 1 },
      },
    },
  },
} as const;
