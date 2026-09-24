#!/usr/bin/env node
/**
 * Prints the shared score fixtures that BOTH engines must agree on.
 *
 * Useful when you are implementing or debugging the Swift mirror and want to
 * see, in one place, exactly what it has to produce.
 *
 * Run: npm run parity
 */

import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const suite = JSON.parse(readFileSync(join(here, '../shared/fixtures/score-cases.json'), 'utf8'));

const pad = (value, width) => String(value).padEnd(width);

console.log(`\nPurchaseScoreEngine parity suite — ${suite.algorithmVersion}`);
console.log(`${suite.cases.length} cases, run by both backend/tests/score-engine.test.ts (Node)`);
console.log('and ios/BeforeKit/Tests/BeforeKitTests/ScoreParityTests.swift (Swift).\n');

console.log(
  `  ${pad('CASE', 42)}${pad('SCORE', 7)}${pad('VERDICT', 9)}${pad('CONF', 7)}RULES`,
);
console.log(`  ${'-'.repeat(100)}`);

for (const testCase of suite.cases) {
  const expected = testCase.expected;
  console.log(
    `  ${pad(testCase.name, 42)}${pad(expected.score, 7)}${pad(expected.verdict, 9)}` +
      `${pad(expected.confidence, 7)}${expected.appliedRules.join(', ') || '—'}`,
  );
}

const verdicts = new Set(suite.cases.map((c) => c.expected.verdict));
console.log(`\n  verdict coverage: ${[...verdicts].sort().join(', ')}`);
if (!verdicts.has('BYE')) {
  console.error('\n  WARNING: no BYE case. BEFORE loses its credibility if BYE is unreachable.\n');
  process.exit(1);
}
console.log('');
