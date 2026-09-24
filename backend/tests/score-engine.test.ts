/**
 * PurchaseScoreEngine — fixture suite + invariants.
 *
 * Run: npm run test:score
 *
 * The fixture cases are shared with the Swift mirror. Expected values in the
 * JSON were derived by hand from scoring/weights.ts, so this suite fails if the
 * engine drifts rather than blessing whatever the engine happens to do.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { PurchaseScoreEngine, verdictForScore, clamp } from '../shared/scoring/engine.ts';
import type { ScoreEngineInput } from '../shared/scoring/engine.ts';
import { BASE_WEIGHTS, SCORE_ALGORITHM_VERSION, TOTAL_BASE_WEIGHT } from '../shared/scoring/weights.ts';
import { SIGNAL_KEYS, type SignalKey } from '../shared/types.ts';

const here = dirname(fileURLToPath(import.meta.url));

interface FixtureCase {
  name: string;
  description: string;
  input: ScoreEngineInput;
  expected: {
    score: number;
    verdict: string;
    suggestedAction: string;
    confidence: number;
    confidenceLabel: string;
    appliedRules: string[];
    excludedFactors?: string[];
  };
}

const suite = JSON.parse(
  readFileSync(join(here, '../shared/fixtures/score-cases.json'), 'utf8'),
) as { algorithmVersion: string; cases: FixtureCase[] };

// ---------------------------------------------------------------------------
// Structural guards on the weights themselves
// ---------------------------------------------------------------------------

test('base weights sum to exactly 100', () => {
  const total = SIGNAL_KEYS.reduce((sum, k) => sum + BASE_WEIGHTS[k], 0);
  assert.equal(total, TOTAL_BASE_WEIGHT);
});

test('every signal key has a weight', () => {
  for (const key of SIGNAL_KEYS) {
    assert.ok(typeof BASE_WEIGHTS[key] === 'number', `missing weight for ${key}`);
  }
});

test('fixture suite targets the current algorithm version', () => {
  assert.equal(
    suite.algorithmVersion,
    SCORE_ALGORITHM_VERSION,
    'weights changed without updating the fixture suite — bump the version and re-derive expectations',
  );
});

// ---------------------------------------------------------------------------
// The shared fixture cases
// ---------------------------------------------------------------------------

for (const fixture of suite.cases) {
  test(`fixture: ${fixture.name} — ${fixture.description}`, () => {
    const result = PurchaseScoreEngine.score(fixture.input);

    assert.equal(result.score, fixture.expected.score, 'score');
    assert.equal(result.verdict, fixture.expected.verdict, 'verdict');
    assert.equal(result.suggestedAction, fixture.expected.suggestedAction, 'suggestedAction');
    assert.equal(result.confidence, fixture.expected.confidence, 'confidence');
    assert.equal(result.confidenceLabel, fixture.expected.confidenceLabel, 'confidenceLabel');
    assert.equal(result.algorithmVersion, SCORE_ALGORITHM_VERSION, 'algorithmVersion');

    for (const rule of fixture.expected.appliedRules) {
      assert.ok(
        result.appliedRules.includes(rule),
        `expected rule "${rule}" to fire, got [${result.appliedRules.join(', ')}]`,
      );
    }

    if (fixture.expected.excludedFactors) {
      for (const key of fixture.expected.excludedFactors) {
        const factor = result.factors.find((f) => f.key === key);
        assert.ok(factor, `factor ${key} missing from output`);
        assert.equal(factor.included, false, `${key} should be excluded`);
        assert.ok(factor.excludedReason, `${key} must explain why it was excluded`);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Invariants that must hold for ANY input, not just the fixtures
// ---------------------------------------------------------------------------

function baseInput(overrides: Partial<ScoreEngineInput> = {}): ScoreEngineInput {
  const signals = Object.fromEntries(SIGNAL_KEYS.map((k) => [k, 50])) as Record<SignalKey, number>;
  const availability = Object.fromEntries(SIGNAL_KEYS.map((k) => [k, true])) as Record<SignalKey, boolean>;
  return {
    signals,
    availability,
    context: {
      hasWardrobeData: true,
      wardrobeItemCount: 10,
      priceKnown: true,
      price: 100,
      budgetSensitivity: 'medium',
      categoryAverageSpend: 100,
      identityConfidence: 0.9,
    },
    aiConfidence: 0.9,
    ...overrides,
  };
}

test('score is always within 0..100 across a wide sweep', () => {
  for (let v = -50; v <= 150; v += 7) {
    const signals = Object.fromEntries(SIGNAL_KEYS.map((k) => [k, v])) as Record<SignalKey, number>;
    const { score } = PurchaseScoreEngine.score(baseInput({ signals }));
    assert.ok(score >= 0 && score <= 100, `score ${score} out of range for signal value ${v}`);
    assert.ok(Number.isInteger(score), `score ${score} must be an integer`);
  }
});

test('all three verdicts remain reachable — BYE must not become impossible', () => {
  const seen = new Set<string>();
  for (let v = 0; v <= 100; v += 5) {
    const signals = Object.fromEntries(SIGNAL_KEYS.map((k) => [k, k === 'duplication_risk' ? 100 - v : v])) as Record<
      SignalKey,
      number
    >;
    seen.add(PurchaseScoreEngine.score(baseInput({ signals })).verdict);
  }
  assert.deepEqual([...seen].sort(), ['BUY', 'BYE', 'WAIT']);
});

test('duplication risk is inverse-scored: more duplication never raises the score', () => {
  let previous = Infinity;
  for (let dup = 0; dup <= 100; dup += 10) {
    const input = baseInput();
    input.signals.duplication_risk = dup;
    const { score } = PurchaseScoreEngine.score(input);
    assert.ok(score <= previous, `score rose from ${previous} to ${score} as duplication went to ${dup}`);
    previous = score;
  }
});

test('the engine is deterministic — identical input gives byte-identical output', () => {
  const input = baseInput();
  const a = PurchaseScoreEngine.score(input);
  const b = PurchaseScoreEngine.score(input);
  assert.deepEqual(a, b);
});

test('overrides only ever downgrade a verdict, never upgrade it', () => {
  const severity: Record<string, number> = { BUY: 2, WAIT: 1, BYE: 0 };
  for (let dup = 0; dup <= 100; dup += 5) {
    for (let gap = 0; gap <= 100; gap += 25) {
      const input = baseInput();
      input.signals.duplication_risk = dup;
      input.signals.wardrobe_gap = gap;
      const result = PurchaseScoreEngine.score(input);
      const band = verdictForScore(result.score);
      assert.ok(
        severity[result.verdict] <= severity[band],
        `override upgraded ${band} to ${result.verdict} at dup=${dup} gap=${gap}`,
      );
    }
  }
});

test('missing price never produces a lower score than known-good price with the same signals', () => {
  const withPrice = baseInput();
  withPrice.signals.value_for_money = 10;
  withPrice.signals.budget_fit = 10;

  const withoutPrice = baseInput();
  withoutPrice.signals.value_for_money = 10;
  withoutPrice.signals.budget_fit = 10;
  withoutPrice.context.priceKnown = false;
  withoutPrice.context.price = null;

  const a = PurchaseScoreEngine.score(withPrice);
  const b = PurchaseScoreEngine.score(withoutPrice);
  assert.ok(b.score >= a.score, 'unknown price must not be penalised harder than a known bad price');
});

test('no wardrobe data lowers confidence but still returns a usable verdict', () => {
  const known = PurchaseScoreEngine.score(baseInput());
  const input = baseInput();
  input.context.hasWardrobeData = false;
  input.context.wardrobeItemCount = 0;
  const unknown = PurchaseScoreEngine.score(input);

  assert.ok(unknown.confidence < known.confidence, 'confidence should drop without wardrobe data');
  assert.ok(['BUY', 'WAIT', 'BYE'].includes(unknown.verdict));
  assert.ok(unknown.appliedRules.includes('no_wardrobe_data'));
  for (const key of ['wardrobe_compatibility', 'duplication_risk', 'wardrobe_gap']) {
    const factor = unknown.factors.find((f) => f.key === key);
    assert.equal(factor?.included, false);
  }
});

test('every factor is reported, included or not, so the UI can explain gaps', () => {
  const input = baseInput();
  input.context.hasWardrobeData = false;
  input.context.priceKnown = false;
  const result = PurchaseScoreEngine.score(input);
  assert.equal(result.factors.length, SIGNAL_KEYS.length);
  for (const factor of result.factors) {
    if (!factor.included) assert.ok(factor.excludedReason, `${factor.key} excluded without a reason`);
  }
});

test('included factor weights renormalise to 1', () => {
  const input = baseInput();
  input.context.priceKnown = false;
  const result = PurchaseScoreEngine.score(input);
  const total = result.factors.filter((f) => f.included).reduce((s, f) => s + f.weight, 0);
  assert.ok(Math.abs(total - 1) < 0.005, `renormalised weights summed to ${total}`);
});

test('NaN signals are clamped rather than poisoning the score', () => {
  const input = baseInput();
  input.signals.style_match = Number.NaN;
  const { score } = PurchaseScoreEngine.score(input);
  assert.ok(Number.isFinite(score) && score >= 0 && score <= 100);
});

test('clamp helper handles NaN, below-range, above-range', () => {
  assert.equal(clamp(Number.NaN, 0, 100), 0);
  assert.equal(clamp(-5, 0, 100), 0);
  assert.equal(clamp(150, 0, 100), 100);
  assert.equal(clamp(42, 0, 100), 42);
});
