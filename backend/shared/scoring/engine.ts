/**
 * BEFORE — PurchaseScoreEngine.
 *
 * The model produces SIGNALS. This file produces the SCORE. That separation is
 * the product: a language model is good at "this jacket is cropped, black, and
 * looks like three things you own", and bad at being consistent about whether
 * that is a 71 or an 83. Everything below is deterministic and pure — same
 * input, same output, on every runtime.
 *
 * Mirrored in Swift at
 * ios/BeforeKit/Sources/BeforeKit/Scoring/PurchaseScoreEngine.swift.
 * Both implementations run the same fixture suite (fixtures/score-cases.json),
 * so a drift between them fails the build rather than reaching a user.
 */

import {
  type AnalysisSignals,
  type BudgetSensitivity,
  type ConfidenceLabel,
  type FactorScore,
  type ScoreResult,
  type SignalAvailability,
  type SignalKey,
  type SuggestedAction,
  type Verdict,
  SIGNAL_KEYS,
} from '../types.ts';
import {
  BASE_WEIGHTS,
  CONFIDENCE_BANDS,
  INVERSE_SIGNALS,
  OVERRIDE,
  SCORE_ALGORITHM_VERSION,
  SIGNAL_LABELS,
  TOTAL_BASE_WEIGHT,
  VERDICT_THRESHOLDS,
} from './weights.ts';

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

export interface ScoreContext {
  /** False when the user has not told BEFORE anything about what they own. */
  hasWardrobeData: boolean;
  wardrobeItemCount: number;
  /** False when neither the page nor the image established a price. */
  priceKnown: boolean;
  price: number | null;
  budgetSensitivity: BudgetSensitivity;
  /** The user's own median spend in this category. null until enough history. */
  categoryAverageSpend: number | null;
  /** How sure the model is it identified the product at all, 0..1. */
  identityConfidence: number;
}

export interface ScoreEngineInput {
  signals: AnalysisSignals;
  /** The model's own view of which signals it could judge. */
  availability: SignalAvailability;
  context: ScoreContext;
  /** The model's confidence in its analysis, 0..1. */
  aiConfidence: number;
}

// ---------------------------------------------------------------------------
// Small numeric helpers. Defined explicitly so the Swift mirror can match them
// exactly — rounding is where two implementations usually start to disagree.
// ---------------------------------------------------------------------------

export function clamp(value: number, min: number, max: number): number {
  if (Number.isNaN(value)) return min;
  return Math.min(max, Math.max(min, value));
}

const clamp01 = (v: number) => clamp(v, 0, 1);
const clamp100 = (v: number) => clamp(v, 0, 100);
const round1 = (v: number) => Math.round(v * 10) / 10;
const round2 = (v: number) => Math.round(v * 100) / 100;
const round3 = (v: number) => Math.round(v * 1000) / 1000;

/** Verdict severity, used to enforce "overrides may only downgrade". */
const SEVERITY: Record<Verdict, number> = { BUY: 2, WAIT: 1, BYE: 0 };

function capVerdict(current: Verdict, ceiling: Verdict): Verdict {
  return SEVERITY[ceiling] < SEVERITY[current] ? ceiling : current;
}

export function verdictForScore(score: number): Verdict {
  for (const band of VERDICT_THRESHOLDS) {
    if (score >= band.min) return band.verdict;
  }
  return 'BYE';
}

export function confidenceLabelFor(confidence: number): ConfidenceLabel {
  if (confidence >= CONFIDENCE_BANDS.high) return 'high';
  if (confidence >= CONFIDENCE_BANDS.medium) return 'medium';
  return 'low';
}

// ---------------------------------------------------------------------------
// Availability gating
// ---------------------------------------------------------------------------

const WARDROBE_DEPENDENT: SignalKey[] = [
  'wardrobe_compatibility',
  'duplication_risk',
  'wardrobe_gap',
];

const PRICE_DEPENDENT: SignalKey[] = ['value_for_money', 'budget_fit'];

const EXCLUSION_REASONS = {
  noWardrobe: 'BEFORE does not know your wardrobe well enough yet',
  noPrice: 'Price was not confidently identified',
  notAssessable: 'Not enough information in the image to judge this',
} as const;

/**
 * Resolve which signals actually count.
 *
 * A signal the data cannot support is REMOVED from the weighted average and its
 * weight is redistributed across the rest. It is never scored as zero — that
 * would invent a penalty out of missing information, which is exactly the
 * failure mode that makes purchase advice untrustworthy.
 */
function resolveAvailability(
  input: ScoreEngineInput,
  appliedRules: string[],
): { available: SignalAvailability; reasons: Partial<Record<SignalKey, string>> } {
  const available = { ...input.availability };
  const reasons: Partial<Record<SignalKey, string>> = {};

  for (const key of SIGNAL_KEYS) {
    if (!available[key]) reasons[key] = EXCLUSION_REASONS.notAssessable;
  }

  if (!input.context.hasWardrobeData) {
    appliedRules.push('no_wardrobe_data');
    for (const key of WARDROBE_DEPENDENT) {
      available[key] = false;
      reasons[key] = EXCLUSION_REASONS.noWardrobe;
    }
  }

  if (!input.context.priceKnown) {
    appliedRules.push('price_unknown_no_price_penalty');
    for (const key of PRICE_DEPENDENT) {
      available[key] = false;
      reasons[key] = EXCLUSION_REASONS.noPrice;
    }
  }

  return { available, reasons };
}

// ---------------------------------------------------------------------------
// Override rules. Ordered, auditable, downgrade-only.
// ---------------------------------------------------------------------------

function applyOverrides(
  verdict: Verdict,
  input: ScoreEngineInput,
  available: SignalAvailability,
  confidence: number,
  appliedRules: string[],
): Verdict {
  let result = verdict;
  const s = input.signals;
  const ctx = input.context;

  // R1 — you already own this. The weighted average can be bland when one
  // extreme signal is the whole story; this is that story.
  if (ctx.hasWardrobeData && available.duplication_risk && available.wardrobe_gap) {
    const dup = clamp100(s.duplication_risk);
    const gap = clamp100(s.wardrobe_gap);
    if (dup >= OVERRIDE.duplicationBye.duplicationRisk && gap <= OVERRIDE.duplicationBye.wardrobeGap) {
      result = capVerdict(result, 'BYE');
      appliedRules.push('duplication_dominant_bye');
    } else if (
      dup >= OVERRIDE.duplicationWait.duplicationRisk &&
      gap <= OVERRIDE.duplicationWait.wardrobeGap
    ) {
      result = capVerdict(result, 'WAIT');
      appliedRules.push('duplication_dominant_wait');
    }
  }

  // R2 — well above what this user normally spends in this category.
  // Only fires with a real price AND enough history to know their normal.
  if (
    ctx.priceKnown &&
    ctx.price !== null &&
    ctx.categoryAverageSpend !== null &&
    ctx.categoryAverageSpend > 0 &&
    ctx.budgetSensitivity === 'high' &&
    ctx.price > ctx.categoryAverageSpend * OVERRIDE.expensiveForBudgetMultiple
  ) {
    result = capVerdict(result, 'WAIT');
    appliedRules.push('expensive_for_budget');
  }

  // R3 — BEFORE does not tell someone to spend money it is not sure about.
  if (result === 'BUY' && confidence < OVERRIDE.minConfidenceForBuy) {
    result = capVerdict(result, 'WAIT');
    appliedRules.push('low_confidence_demotes_buy');
  }

  return result;
}

function suggestedActionFor(verdict: Verdict, appliedRules: string[]): SuggestedAction {
  if (verdict === 'BUY') return 'BUY_IT';
  if (verdict === 'BYE') return 'SKIP_IT';
  if (appliedRules.includes('duplication_dominant_wait')) return 'CHECK_WARDROBE_FIRST';
  if (appliedRules.includes('expensive_for_budget')) return 'WAIT_FOR_SALE';
  return 'WAIT_48_HOURS';
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

export class PurchaseScoreEngine {
  static readonly version = SCORE_ALGORITHM_VERSION;

  static score(input: ScoreEngineInput): ScoreResult {
    const appliedRules: string[] = [];
    const { available, reasons } = resolveAvailability(input, appliedRules);

    // 1. Effective weights: included signals only, renormalised to sum to 1.
    let includedWeight = 0;
    for (const key of SIGNAL_KEYS) {
      if (available[key]) includedWeight += BASE_WEIGHTS[key];
    }

    // Degenerate case: nothing is knowable. Refuse to produce a verdict that
    // pretends otherwise rather than emitting a confident-looking number.
    if (includedWeight === 0) {
      appliedRules.push('no_assessable_signals');
      return {
        score: 0,
        verdict: 'WAIT',
        suggestedAction: 'WAIT_48_HOURS',
        confidence: 0,
        confidenceLabel: 'low',
        factors: SIGNAL_KEYS.map((key) => ({
          key,
          label: SIGNAL_LABELS[key],
          value: 0,
          weight: 0,
          included: false,
          excludedReason: reasons[key] ?? EXCLUSION_REASONS.notAssessable,
        })),
        appliedRules,
        algorithmVersion: SCORE_ALGORITHM_VERSION,
      };
    }

    // 2. Weighted sum. Inverse signals contribute (100 - value).
    let raw = 0;
    const factors: FactorScore[] = [];

    for (const key of SIGNAL_KEYS) {
      const rawValue = clamp100(input.signals[key]);
      const contribution = INVERSE_SIGNALS.has(key) ? 100 - rawValue : rawValue;
      const included = available[key];
      const effectiveWeight = included ? BASE_WEIGHTS[key] / includedWeight : 0;

      if (included) raw += contribution * effectiveWeight;

      factors.push({
        key,
        label: SIGNAL_LABELS[key],
        // Displayed as x/10. Inverse signals display their CONTRIBUTION, so a
        // high "Duplication" number always reads as good, like every other row.
        value: round1(contribution / 10),
        weight: round3(effectiveWeight),
        included,
        excludedReason: included ? null : (reasons[key] ?? EXCLUSION_REASONS.notAssessable),
      });
    }

    const score = Math.round(clamp100(raw));

    // 3. Confidence: the model's own confidence, discounted by how much of the
    //    picture we actually had and how sure we are what the product even is.
    const coverage = includedWeight / TOTAL_BASE_WEIGHT;
    const identity = clamp01(input.context.identityConfidence);
    const confidence = round2(
      clamp01(clamp01(input.aiConfidence) * (0.55 + 0.45 * coverage) * (0.75 + 0.25 * identity)),
    );

    // 4. Verdict, then deterministic overrides (downgrade-only).
    const bandVerdict = verdictForScore(score);
    const verdict = applyOverrides(bandVerdict, input, available, confidence, appliedRules);

    return {
      score,
      verdict,
      suggestedAction: suggestedActionFor(verdict, appliedRules),
      confidence,
      confidenceLabel: confidenceLabelFor(confidence),
      factors,
      appliedRules,
      algorithmVersion: SCORE_ALGORITHM_VERSION,
    };
  }
}

/** Convenience wrapper matching the Swift call site. */
export function scorePurchase(input: ScoreEngineInput): ScoreResult {
  return PurchaseScoreEngine.score(input);
}
