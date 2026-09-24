/**
 * Cross-language contract checks between the TypeScript source of truth and the
 * Swift mirror.
 *
 * WHY THIS EXISTS: the real parity test is ScoreParityTests.swift, which runs
 * the same fixtures through the Swift engine. That needs a Swift toolchain,
 * which CI on a non-Mac runner (and a Windows dev machine) does not have. These
 * checks are text-level, so they run everywhere, and they catch the failure mode
 * that actually happens in practice: someone edits one language and forgets the
 * other. A renamed enum case or a changed weight fails here immediately.
 *
 * They do NOT replace the Swift test. They narrow what it can catch to genuine
 * logic differences rather than typos.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  CATEGORIES,
  SHOPPING_PRIORITIES,
  SIGNAL_KEYS,
  STYLE_PREFERENCES,
  SUGGESTED_ACTIONS,
  VERDICTS,
  SAVED_BUCKETS,
  OUTCOME_ACTIONS,
  SATISFACTIONS,
} from '../shared/types.ts';
import { BASE_WEIGHTS, OVERRIDE, SCORE_ALGORITHM_VERSION, VERDICT_THRESHOLDS } from '../shared/scoring/weights.ts';

const here = dirname(fileURLToPath(import.meta.url));
const iosRoot = join(here, '../../ios/BeforeKit/Sources/BeforeKit');

const domain = readFileSync(join(iosRoot, 'Models/Domain.swift'), 'utf8');
const weights = readFileSync(join(iosRoot, 'Scoring/ScoreWeights.swift'), 'utf8');
const engine = readFileSync(join(iosRoot, 'Scoring/PurchaseScoreEngine.swift'), 'utf8');

/**
 * Raw values of a Swift enum. Handles both explicit (`case buy = "BUY"`) and
 * implicit (`case fashion, beauty`) forms, which is how the two files are
 * genuinely written.
 */
function swiftEnumRawValues(source: string, enumName: string): string[] {
  const start = source.indexOf(`enum ${enumName}`);
  assert.notEqual(start, -1, `Swift enum ${enumName} not found`);

  // Walk braces from the enum's opening brace to its matching close.
  const open = source.indexOf('{', start);
  let depth = 1;
  let index = open + 1;
  while (index < source.length && depth > 0) {
    if (source[index] === '{') depth++;
    else if (source[index] === '}') depth--;
    index++;
  }
  const body = source.slice(open + 1, index - 1);

  const values: string[] = [];
  for (const line of body.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('case ')) continue;
    // Stop at the first computed property or nested type.
    const declaration = trimmed.slice(5).split('//')[0].trim();

    for (const part of declaration.split(',')) {
      const entry = part.trim();
      if (!entry) continue;
      const explicit = entry.match(/^\w+\s*=\s*"([^"]+)"$/);
      if (explicit) {
        values.push(explicit[1]);
        continue;
      }
      const implicit = entry.match(/^(\w+)$/);
      if (implicit) values.push(implicit[1]);
    }
  }
  return values;
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

const ENUM_CASES: Array<[string, readonly string[]]> = [
  ['Verdict', VERDICTS],
  ['SuggestedAction', SUGGESTED_ACTIONS],
  ['ProductCategory', CATEGORIES],
  ['SignalKey', SIGNAL_KEYS],
  ['ShoppingPriority', SHOPPING_PRIORITIES],
  ['StylePreference', STYLE_PREFERENCES],
  ['SavedBucket', SAVED_BUCKETS],
  ['OutcomeAction', OUTCOME_ACTIONS],
  ['Satisfaction', SATISFACTIONS],
];

for (const [enumName, expected] of ENUM_CASES) {
  test(`Swift ${enumName} has the same wire values as TypeScript`, () => {
    const actual = swiftEnumRawValues(domain, enumName);
    assert.deepEqual(
      actual,
      [...expected],
      `${enumName} differs. TypeScript: [${expected.join(', ')}] Swift: [${actual.join(', ')}]`,
    );
  });
}

test('Swift SignalKey labels match the backend display labels', () => {
  // The labels appear in the result screen and on the share card, so a
  // mismatch is visible to a user comparing the app with a shared image.
  const labels = [...domain.matchAll(/case \.(\w+): "([^"]+)"/g)].map((m) => m[2]);
  for (const expected of ['Wardrobe fit', 'Duplication', 'Versatility', 'Style match', 'Value', 'Budget fit', 'Fills a gap']) {
    assert.ok(labels.includes(expected), `Swift is missing the label "${expected}"`);
  }
});

// ---------------------------------------------------------------------------
// Weights, thresholds, and overrides
// ---------------------------------------------------------------------------

test('Swift base weights match the TypeScript weights exactly', () => {
  for (const [key, weight] of Object.entries(BASE_WEIGHTS)) {
    const camel = key.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
    const pattern = new RegExp(`\\.${camel}:\\s*([\\d.]+)`);
    const match = weights.match(pattern);
    assert.ok(match, `Swift has no weight for ${key} (looked for .${camel})`);
    assert.equal(
      Number(match[1]),
      weight,
      `weight for ${key}: TypeScript ${weight}, Swift ${match[1]}`,
    );
  }
});

test('Swift verdict thresholds match', () => {
  const buy = weights.match(/buy:\s*Int\s*=\s*(\d+)/);
  const wait = weights.match(/wait:\s*Int\s*=\s*(\d+)/);
  assert.ok(buy && wait, 'Swift thresholds not found');

  const tsBuy = VERDICT_THRESHOLDS.find((t) => t.verdict === 'BUY')?.min;
  const tsWait = VERDICT_THRESHOLDS.find((t) => t.verdict === 'WAIT')?.min;
  assert.equal(Number(buy[1]), tsBuy);
  assert.equal(Number(wait[1]), tsWait);
});

test('Swift override thresholds match', () => {
  const checks: Array<[RegExp, number]> = [
    [/duplicationByeRisk:\s*Double\s*=\s*([\d.]+)/, OVERRIDE.duplicationBye.duplicationRisk],
    [/duplicationByeGap:\s*Double\s*=\s*([\d.]+)/, OVERRIDE.duplicationBye.wardrobeGap],
    [/duplicationWaitRisk:\s*Double\s*=\s*([\d.]+)/, OVERRIDE.duplicationWait.duplicationRisk],
    [/duplicationWaitGap:\s*Double\s*=\s*([\d.]+)/, OVERRIDE.duplicationWait.wardrobeGap],
    [/expensiveForBudgetMultiple:\s*Double\s*=\s*([\d.]+)/, OVERRIDE.expensiveForBudgetMultiple],
    [/minConfidenceForBuy:\s*Double\s*=\s*([\d.]+)/, OVERRIDE.minConfidenceForBuy],
  ];
  for (const [pattern, expected] of checks) {
    const match = weights.match(pattern);
    assert.ok(match, `Swift value not found for ${pattern}`);
    assert.equal(Number(match[1]), expected, `${pattern} differs`);
  }
});

test('the algorithm version string matches in both languages', () => {
  const match = weights.match(/algorithmVersion\s*=\s*"([^"]+)"/);
  assert.ok(match, 'Swift algorithmVersion not found');
  assert.equal(match[1], SCORE_ALGORITHM_VERSION);
});

test('Swift inverse-signal set matches the TypeScript one', () => {
  const match = weights.match(/inverseSignals:\s*Set<SignalKey>\s*=\s*\[([^\]]*)\]/);
  assert.ok(match, 'Swift inverseSignals not found');
  assert.ok(
    match[1].includes('duplicationRisk'),
    'duplication_risk must be inverse-scored in Swift too',
  );
  // Exactly one, matching INVERSE_SIGNALS.
  assert.equal(match[1].split(',').filter((s) => s.trim()).length, 1);
});

// ---------------------------------------------------------------------------
// Rule identifiers — these travel in appliedRules and are asserted by both suites
// ---------------------------------------------------------------------------

test('both engines emit the same rule identifiers', () => {
  const tsEngine = readFileSync(join(here, '../shared/scoring/engine.ts'), 'utf8');
  const extract = (source: string) =>
    new Set(
      [...source.matchAll(/appliedRules\.(?:push|append)\('([a-z_]+)'\)|appliedRules\.append\("([a-z_]+)"\)/g)]
        .map((m) => m[1] ?? m[2])
        .filter(Boolean),
    );

  const tsRules = extract(tsEngine);
  const swiftRules = extract(engine);

  assert.ok(tsRules.size >= 6, `expected several rules, found ${[...tsRules].join(', ')}`);
  assert.deepEqual(
    [...swiftRules].sort(),
    [...tsRules].sort(),
    'the two engines emit different rule identifiers',
  );
});

test('the Swift exclusion reasons match the TypeScript ones verbatim', () => {
  const tsEngine = readFileSync(join(here, '../shared/scoring/engine.ts'), 'utf8');
  for (const marker of ['noWardrobe', 'noPrice', 'notAssessable']) {
    const tsMatch = tsEngine.match(new RegExp(`${marker}:\\s*'([^']+)'`));
    const swiftMatch = engine.match(new RegExp(`${marker}\\s*=\\s*"([^"]+)"`));
    assert.ok(tsMatch, `TypeScript reason ${marker} not found`);
    assert.ok(swiftMatch, `Swift reason ${marker} not found`);
    assert.equal(swiftMatch[1], tsMatch[1], `exclusion reason "${marker}" differs between languages`);
  }
});

// ---------------------------------------------------------------------------
// Fixture decoding contract
// ---------------------------------------------------------------------------

test('the Swift fixture decoder expects keys that the fixture file actually has', () => {
  const suite = JSON.parse(
    readFileSync(join(here, '../shared/fixtures/score-cases.json'), 'utf8'),
  ) as { cases: Array<Record<string, unknown>> };

  const swiftTest = readFileSync(
    join(here, '../../ios/BeforeKit/Tests/BeforeKitTests/ScoreParityTests.swift'),
    'utf8',
  );

  /**
   * Non-optional `let` properties in the per-case Swift structs must be present
   * on every case, or decoding throws at runtime on a Mac.
   *
   * Scoped to the per-case structs only: `Suite` holds the file-level fields
   * (algorithmVersion, cases), which are correctly absent from an individual case.
   */
  const perCaseStructs = ['Case', 'Input', 'Context', 'Expected'];
  const required: string[] = [];

  for (const structName of perCaseStructs) {
    const start = swiftTest.indexOf(`struct ${structName}: Decodable`);
    assert.notEqual(start, -1, `Swift struct ${structName} not found in the parity test`);
    const open = swiftTest.indexOf('{', start);
    const close = swiftTest.indexOf('}', open);
    const body = swiftTest.slice(open + 1, close);

    for (const match of body.matchAll(/let (\w+):\s*([^\n]+)/g)) {
      const [, field, type] = match;
      if (type.trim().endsWith('?')) continue; // optional — absence is fine
      required.push(field);
    }
  }

  assert.ok(required.length > 5, `expected several required fixture fields, got ${required.length}`);

  const flatten = (record: Record<string, unknown>): Set<string> => {
    const keys = new Set<string>();
    for (const [key, value] of Object.entries(record)) {
      keys.add(key);
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        for (const nested of flatten(value as Record<string, unknown>)) keys.add(nested);
      }
    }
    return keys;
  };

  for (const testCase of suite.cases) {
    const keys = flatten(testCase);
    for (const field of required) {
      assert.ok(
        keys.has(field),
        `fixture "${testCase.name}" has no "${field}", which the Swift decoder requires`,
      );
    }
  }
});
