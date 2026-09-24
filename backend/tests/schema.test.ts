/**
 * AI response validation — the trust boundary between an untrusted model and
 * everything downstream.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  AiSafetyError,
  AiSchemaError,
  LIMITS,
  extractJson,
  parseAnalysis,
  validateAnalysis,
} from '../shared/ai/schema.ts';
import { SIGNAL_KEYS } from '../shared/types.ts';

function validResponse(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    product: {
      name: 'Cropped leather jacket',
      brand: null,
      category: 'fashion',
      subcategory: 'outerwear',
      price: 198,
      currency: 'usd',
      retailer: null,
      material: null,
      sources: { price: 'confirmed', category: 'confirmed' },
      price_confidence: 0.95,
      identity_confidence: 0.7,
    },
    visual_analysis: {
      colors: ['black'],
      style_tags: ['minimal'],
      occasion_tags: ['everyday'],
      versatility_estimate: 80,
      visual_quality_confidence: 0.7,
    },
    signals: Object.fromEntries(SIGNAL_KEYS.map((k) => [k, 70])),
    signal_availability: Object.fromEntries(SIGNAL_KEYS.map((k) => [k, true])),
    reasoning: {
      positive_factors: ['Works with your neutrals'],
      negative_factors: ['Above your usual spend'],
      key_risk: 'Overlaps with a jacket you own.',
      advice: 'Wait 48 hours.',
      uncertainties: ['Brand not confidently identified'],
    },
    recommendation: { suggested_action: 'WAIT', confidence: 0.82 },
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Happy path
// ---------------------------------------------------------------------------

test('a well-formed response validates', () => {
  const result = validateAnalysis(validResponse());
  assert.equal(result.product.name, 'Cropped leather jacket');
  assert.equal(result.product.price, 198);
  assert.equal(result.product.currency, 'USD', 'currency should be upper-cased');
  assert.equal(result.confidence, 0.82);
  assert.equal(result.reasoning.advice, 'Wait 48 hours.');
  assert.equal(result.warnings.length, 0);
});

test('every signal is present after validation', () => {
  const result = validateAnalysis(validResponse());
  for (const key of SIGNAL_KEYS) {
    assert.equal(typeof result.signals[key], 'number');
    assert.equal(typeof result.availability[key], 'boolean');
  }
});

// ---------------------------------------------------------------------------
// Structural rejection
// ---------------------------------------------------------------------------

test('a non-object response is rejected', () => {
  assert.throws(() => validateAnalysis('not an object'), AiSchemaError);
  assert.throws(() => validateAnalysis(null), AiSchemaError);
  assert.throws(() => validateAnalysis([1, 2, 3]), AiSchemaError);
});

test('a missing signals block is rejected', () => {
  const body = validResponse();
  delete body.signals;
  assert.throws(() => validateAnalysis(body), AiSchemaError);
});

test('a missing individual signal is rejected rather than defaulted', () => {
  const body = validResponse();
  const signals = { ...(body.signals as Record<string, number>) };
  delete signals.style_match;
  body.signals = signals;
  assert.throws(() => validateAnalysis(body), AiSchemaError);
});

test('invalid JSON is rejected', () => {
  assert.throws(() => extractJson('definitely not json'), AiSchemaError);
});

// ---------------------------------------------------------------------------
// Recoverable problems are corrected and recorded, not thrown
// ---------------------------------------------------------------------------

test('out-of-range signals are clamped with a warning', () => {
  const body = validResponse();
  body.signals = { ...(body.signals as object), style_match: 150, budget_fit: -10 };
  const result = validateAnalysis(body);
  assert.equal(result.signals.style_match, 100);
  assert.equal(result.signals.budget_fit, 0);
  assert.equal(result.warnings.filter((w) => w.includes('clamped')).length, 2);
});

test('an unknown category falls back to "other" with a warning', () => {
  const body = validResponse();
  body.product = { ...(body.product as object), category: 'spaceship' };
  const result = validateAnalysis(body);
  assert.equal(result.product.category, 'other');
  assert.ok(result.warnings.some((w) => w.includes('spaceship')));
});

test('over-long reasoning is truncated to stay readable', () => {
  const body = validResponse();
  body.reasoning = {
    ...(body.reasoning as object),
    positive_factors: ['x'.repeat(400)],
  };
  const result = validateAnalysis(body);
  assert.equal(result.reasoning.positiveFactors[0].length, LIMITS.positiveFactors.chars);
  assert.ok(result.warnings.some((w) => w.includes('truncated')));
});

test('too many reasoning bullets are dropped', () => {
  const body = validResponse();
  body.reasoning = {
    ...(body.reasoning as object),
    positive_factors: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
  };
  const result = validateAnalysis(body);
  assert.equal(result.reasoning.positiveFactors.length, LIMITS.positiveFactors.max);
});

test('a bogus currency is dropped rather than stored', () => {
  const body = validResponse();
  body.product = { ...(body.product as object), currency: '$' };
  const result = validateAnalysis(body);
  assert.equal(result.product.currency, null);
});

test('a zero or negative price becomes null, not a real price', () => {
  for (const price of [0, -5]) {
    const body = validResponse();
    body.product = { ...(body.product as object), price };
    assert.equal(validateAnalysis(body).product.price, null, `price ${price}`);
  }
});

test('"unknown" and "null" strings become real nulls', () => {
  const body = validResponse();
  body.product = { ...(body.product as object), brand: 'unknown', material: 'null' };
  const result = validateAnalysis(body);
  assert.equal(result.product.brand, null);
  assert.equal(result.product.material, null);
});

// ---------------------------------------------------------------------------
// Product rules
// ---------------------------------------------------------------------------

test('Rule 6: a model-supplied product URL is discarded', () => {
  const body = validResponse();
  body.product = { ...(body.product as object), product_url: 'https://shop.example/thing' };
  const result = validateAnalysis(body);
  assert.equal(result.product.productUrl, null);
  assert.ok(result.warnings.some((w) => w.includes('Rule 6')));
});

test('a price with no stated provenance is labelled, never left ambiguous', () => {
  const body = validResponse();
  body.product = { ...(body.product as object), sources: {}, price_confidence: 0.4 };
  assert.equal(validateAnalysis(body).product.sources.price, 'estimated');

  const confident = validResponse();
  confident.product = { ...(confident.product as object), sources: {}, price_confidence: 0.95 };
  assert.equal(validateAnalysis(confident).product.sources.price, 'confirmed');
});

test('the model suggestion is captured but kept separate from the verdict path', () => {
  const result = validateAnalysis(validResponse());
  assert.equal(result.modelSuggestedAction, 'WAIT_48_HOURS');
  // There is deliberately no `verdict` on a validated analysis — only the
  // score engine produces one.
  assert.equal((result as Record<string, unknown>).verdict, undefined);
});

// ---------------------------------------------------------------------------
// Safety
// ---------------------------------------------------------------------------

test('an appearance judgement blocks the whole analysis', () => {
  const body = validResponse();
  body.reasoning = {
    ...(body.reasoning as object),
    negative_factors: ['The cut makes you look heavier than the straight-leg ones'],
  };
  assert.throws(() => validateAnalysis(body), AiSafetyError);
});

test('a body-shape judgement blocks the analysis', () => {
  const body = validResponse();
  body.reasoning = {
    ...(body.reasoning as object),
    positive_factors: ['It flatters your figure nicely'],
  };
  assert.throws(() => validateAnalysis(body), AiSafetyError);
});

test('a fabricated-scarcity claim is stripped but the analysis survives', () => {
  const body = validResponse();
  body.reasoning = {
    ...(body.reasoning as object),
    positive_factors: ['Works with your neutrals', 'Only 2 left in your size'],
  };
  const result = validateAnalysis(body);
  assert.deepEqual(result.reasoning.positiveFactors, ['Works with your neutrals']);
  assert.equal(result.safetyFindings.length, 1);
  assert.equal(result.safetyFindings[0].kind, 'stripped');
});

test('ordinary fit and sizing language is not flagged', () => {
  const body = validResponse();
  body.reasoning = {
    ...(body.reasoning as object),
    positive_factors: ['The silhouette matches the trousers you already own'],
    negative_factors: ['Reviews say it runs small, so check the size chart'],
    key_risk: 'The oversized cut may not layer over your knits.',
  };
  const result = validateAnalysis(body);
  assert.equal(result.safetyFindings.length, 0, 'legitimate styling language must not be flagged');
  assert.equal(result.reasoning.positiveFactors.length, 1);
  assert.equal(result.reasoning.negativeFactors.length, 1);
});

// ---------------------------------------------------------------------------
// Tolerant parsing
// ---------------------------------------------------------------------------

test('JSON wrapped in a markdown fence is recovered', () => {
  const raw = '```json\n' + JSON.stringify(validResponse()) + '\n```';
  assert.equal(parseAnalysis(raw).product.price, 198);
});

test('JSON with leading prose is recovered', () => {
  const raw = "Here's the analysis you asked for:\n" + JSON.stringify(validResponse());
  assert.equal(parseAnalysis(raw).product.price, 198);
});

test('plain JSON is parsed', () => {
  assert.equal(parseAnalysis(JSON.stringify(validResponse())).product.price, 198);
});
