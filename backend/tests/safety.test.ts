/**
 * Safety scan — the backstop for Rule 4 (BEFORE evaluates the purchase, never
 * the person) and Rule 5 (never fabricate).
 *
 * Two failure modes are tested with equal weight: letting a judgement through,
 * and flagging ordinary styling language. The second one is what makes a
 * blunt filter unusable in a fashion product.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { scanOptional, scanStrings, scanText } from '../shared/ai/safety.ts';

const MUST_BLOCK = [
  'This cut makes you look heavier than the straight-leg ones',
  'The colour makes you look older',
  'It makes you look fantastic',
  'Honestly it makes you seem frumpy',
  'A great pick for your attractiveness',
  'This really flatters your figure',
  'Not the best for your body type',
  'It will accentuate your hips in a bad way',
  'You are a little overweight for this silhouette',
  'This is cut for a woman of your age',
];

const MUST_NOT_FLAG = [
  'Works with eight things you already own',
  'The silhouette matches the trousers you wear most',
  'Reviews consistently say it runs small — check the size chart',
  'Cropped jackets layer badly over your longer knits',
  'This is 2.5x your usual outerwear spend',
  'You already own two similar black jackets',
  'The wool blend should hold shape better than the acrylic one you returned',
  'A structured shape like this reads more formal than the rest of your wardrobe',
  'Expected wears: 10 to 15 based on similar items in your history',
  'Colour coordination with your existing palette is strong',
  'The fit guide suggests sizing up for a relaxed look',
];

test('appearance and protected-attribute judgements are blocked', () => {
  for (const line of MUST_BLOCK) {
    const findings = scanText(line);
    assert.ok(findings.length > 0, `should have been flagged: "${line}"`);
    assert.ok(
      findings.some((f) => f.kind === 'blocked'),
      `should have BLOCKED, not merely stripped: "${line}"`,
    );
  }
});

test('ordinary styling, fit, and value language passes cleanly', () => {
  for (const line of MUST_NOT_FLAG) {
    const findings = scanText(line);
    assert.equal(findings.length, 0, `false positive on: "${line}" -> ${JSON.stringify(findings)}`);
  }
});

test('regression: "makes you look ___" is blocked for any adjective', () => {
  // The first version of this rule enumerated adjectives and missed "heavier".
  // The rule now matches the construction, so new adjectives cannot slip past.
  for (const word of ['heavier', 'wider', 'shorter', 'expensive', 'professional', 'tired']) {
    const findings = scanText(`This makes you look ${word}`);
    assert.ok(
      findings.some((f) => f.kind === 'blocked'),
      `"makes you look ${word}" should be blocked`,
    );
  }
});

test('fabricated scarcity and certainty are stripped, not blocked', () => {
  for (const line of [
    'Only 2 left in your size',
    'This definitely costs around 400 dollars',
    'It is certainly authentic',
  ]) {
    const findings = scanText(line);
    assert.ok(findings.length > 0, `should have been flagged: "${line}"`);
    assert.ok(
      findings.every((f) => f.kind === 'stripped'),
      `should be stripped rather than blocked: "${line}"`,
    );
  }
});

test('scanStrings drops offending lines and keeps the rest', () => {
  const result = scanStrings([
    'Works with your existing neutrals',
    'Only 2 left in your size',
    'High expected usage',
  ]);
  assert.deepEqual(result.value, ['Works with your existing neutrals', 'High expected usage']);
  assert.equal(result.blocked, false);
  assert.equal(result.findings.length, 1);
});

test('scanStrings reports blocked when any line warrants it', () => {
  const result = scanStrings(['Fine line', 'It makes you look older']);
  assert.equal(result.blocked, true);
  assert.ok(!result.value.includes('It makes you look older'), 'offending line must not survive');
});

test('scanOptional handles null and empty input', () => {
  assert.deepEqual(scanOptional(null), { value: null, findings: [], blocked: false });
  assert.deepEqual(scanOptional('   '), { value: null, findings: [], blocked: false });
});

test('scanOptional nulls a value it had to flag', () => {
  const result = scanOptional('It makes you look slimmer');
  assert.equal(result.value, null);
  assert.equal(result.blocked, true);
});

test('the scan is case-insensitive', () => {
  assert.ok(scanText('IT MAKES YOU LOOK OLDER').some((f) => f.kind === 'blocked'));
});

test('findings carry a truncated sample safe to log', () => {
  const findings = scanText(`It makes you look older. ${'x'.repeat(400)}`);
  assert.ok(findings[0].sample.length <= 120);
});
