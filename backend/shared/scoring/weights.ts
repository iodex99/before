/**
 * BEFORE — scoring weights and thresholds.
 *
 * Changing anything in this file changes the meaning of a score. Bump
 * SCORE_ALGORITHM_VERSION when you do, so historical scores keep their meaning
 * (every analysis row stores the version it was computed under).
 */

import type { SignalKey, Verdict } from '../types.ts';

export const SCORE_ALGORITHM_VERSION = 'score_v1';

/** Base weights in percentage points. Must sum to 100. */
export const BASE_WEIGHTS: Record<SignalKey, number> = {
  wardrobe_compatibility: 25,
  duplication_risk: 15,
  expected_usage: 15,
  style_match: 15,
  value_for_money: 15,
  budget_fit: 10,
  wardrobe_gap: 5,
};

export const TOTAL_BASE_WEIGHT = 100;

/**
 * Signals where a HIGH raw value is BAD. Their contribution is inverted
 * (100 - value) before weighting: high duplication risk must drag the score
 * down, not push it up.
 */
export const INVERSE_SIGNALS: ReadonlySet<SignalKey> = new Set<SignalKey>([
  'duplication_risk',
]);

/** Display labels. Kept beside the weights so the two never drift apart. */
export const SIGNAL_LABELS: Record<SignalKey, string> = {
  wardrobe_compatibility: 'Wardrobe fit',
  duplication_risk: 'Duplication',
  expected_usage: 'Versatility',
  style_match: 'Style match',
  value_for_money: 'Value',
  budget_fit: 'Budget fit',
  wardrobe_gap: 'Fills a gap',
};

/** Score bands. Inclusive lower bounds, evaluated highest first. */
export const VERDICT_THRESHOLDS: ReadonlyArray<{ min: number; verdict: Verdict }> = [
  { min: 80, verdict: 'BUY' },
  { min: 60, verdict: 'WAIT' },
  { min: 0, verdict: 'BYE' },
];

/**
 * Override thresholds. Overrides may only make a verdict MORE conservative,
 * never less — see engine.ts. That invariant is what keeps the product honest
 * when a signal is extreme but the weighted average is bland.
 */
export const OVERRIDE = {
  /** Owning near-duplicates with no gap to fill. */
  duplicationBye: { duplicationRisk: 90, wardrobeGap: 20 },
  duplicationWait: { duplicationRisk: 75, wardrobeGap: 35 },
  /** Multiple of the user's own median spend in this category. */
  expensiveForBudgetMultiple: 2.0,
  /** Below this, BEFORE will not tell someone to spend money. */
  minConfidenceForBuy: 0.45,
} as const;

export const CONFIDENCE_BANDS = {
  high: 0.75,
  medium: 0.5,
} as const;
