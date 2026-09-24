/**
 * End-to-end through the pipeline the way production runs it:
 *
 *   fixture JSON -> validateAnalysis -> PurchaseScoreEngine -> score + verdict
 *
 * This is what stops a fixture from quietly claiming "WAIT 78" in the docs
 * while actually scoring 62 in the app, and it exercises the validator and the
 * engine together rather than in isolation.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { validateAnalysis } from '../shared/ai/schema.ts';
import { PurchaseScoreEngine } from '../shared/scoring/engine.ts';
import { MockProvider, stableHash, type MockFixture } from '../shared/ai/providers/mock.ts';
import { ProviderError } from '../shared/ai/provider.ts';

const here = dirname(fileURLToPath(import.meta.url));
const { fixtures } = JSON.parse(
  readFileSync(join(here, '../shared/fixtures/ai-responses.json'), 'utf8'),
) as { fixtures: MockFixture[] };

/** The context the fixtures were designed against. */
function contextFor(fixture: MockFixture) {
  const hasWardrobe = fixture.id !== 'demo_no_wardrobe_first_time';
  return {
    hasWardrobeData: hasWardrobe,
    wardrobeItemCount: hasWardrobe ? 18 : 0,
    priceKnown: true,
    price: (fixture.response.product as { price: number }).price,
    budgetSensitivity: 'medium' as const,
    categoryAverageSpend: null,
    identityConfidence: (fixture.response.product as { identity_confidence: number })
      .identity_confidence,
  };
}

test('every fixture is a valid AI response', () => {
  for (const fixture of fixtures) {
    assert.doesNotThrow(() => validateAnalysis(fixture.response), `fixture ${fixture.id}`);
  }
});

test('every fixture produces exactly the score and verdict it documents', () => {
  for (const fixture of fixtures) {
    const validated = validateAnalysis(fixture.response);
    const result = PurchaseScoreEngine.score({
      signals: validated.signals,
      availability: validated.availability,
      context: contextFor(fixture),
      aiConfidence: validated.confidence,
    });

    assert.equal(
      result.score,
      fixture.expectedScore,
      `${fixture.id}: documented score ${fixture.expectedScore}, engine produced ${result.score}`,
    );
    assert.equal(
      result.verdict,
      fixture.expectedVerdict,
      `${fixture.id}: documented verdict ${fixture.expectedVerdict}, engine produced ${result.verdict}`,
    );
  }
});

test('the fixture set covers all three verdicts', () => {
  const verdicts = new Set(fixtures.map((f) => f.expectedVerdict));
  assert.deepEqual([...verdicts].sort(), ['BUY', 'BYE', 'WAIT']);
});

test('no fixture is safety-flagged — they are the copy we ship in development', () => {
  for (const fixture of fixtures) {
    const validated = validateAnalysis(fixture.response);
    assert.equal(validated.safetyFindings.length, 0, `fixture ${fixture.id} trips the safety scan`);
  }
});

test('the wardrobe-less fixture marks its wardrobe signals unavailable', () => {
  const fixture = fixtures.find((f) => f.id === 'demo_no_wardrobe_first_time');
  assert.ok(fixture, 'expected a no-wardrobe fixture');
  const validated = validateAnalysis(fixture.response);
  for (const key of ['wardrobe_compatibility', 'duplication_risk', 'wardrobe_gap'] as const) {
    assert.equal(validated.availability[key], false, `${key} should be unavailable`);
  }
});

// ---------------------------------------------------------------------------
// Provider behaviour
// ---------------------------------------------------------------------------

test('fixture selection is stable for a given request id', async () => {
  const provider = new MockProvider({ fixtures });
  const first = await provider.analyzePurchase(request('analysis-abc'));
  const second = await provider.analyzePurchase(request('analysis-abc'));
  assert.equal(first.raw, second.raw);
});

test('different request ids reach different fixtures', () => {
  const provider = new MockProvider({ fixtures });
  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) seen.add(provider.select(`analysis-${i}`).id);
  assert.ok(seen.size > 1, 'mock mode should exercise more than one verdict during UI work');
});

test('a pinned fixture id overrides selection', async () => {
  const provider = new MockProvider({ fixtures, forceFixtureId: 'demo_bye_duplicate_knit' });
  const response = await provider.analyzePurchase(request('anything'));
  assert.equal(JSON.parse(response.raw).product.name, 'Ribbed knit top');
});

test('an unknown pinned fixture id fails loudly', () => {
  const provider = new MockProvider({ fixtures, forceFixtureId: 'nope' });
  assert.throws(() => provider.select('x'), ProviderError);
});

test('constructing a mock provider with no fixtures fails', () => {
  assert.throws(() => new MockProvider({ fixtures: [] }), ProviderError);
});

test('stableHash is deterministic and unsigned', () => {
  assert.equal(stableHash('abc'), stableHash('abc'));
  assert.notEqual(stableHash('abc'), stableHash('abd'));
  for (const input of ['', 'a', 'a much longer string with symbols !@#$%^&*()']) {
    const hash = stableHash(input);
    assert.ok(Number.isInteger(hash) && hash >= 0, `hash of "${input}" was ${hash}`);
  }
});

function request(requestId: string) {
  return {
    systemPrompt: 'system',
    userPrompt: 'user',
    image: null,
    maxOutputTokens: 1000,
    timeoutMs: 1000,
    requestId,
  };
}
