/**
 * BEFORE — output safety scan.
 *
 * The system prompt tells the model not to judge the person. This file assumes
 * the prompt will eventually fail to hold, because prompts do. Every string the
 * model produces is scanned before it can reach a user.
 *
 * Two classes of finding:
 *   - `blocked`   the analysis is rejected outright and retried/failed.
 *   - `stripped`  the offending line is dropped, the rest of the analysis stands.
 *
 * This is a backstop, not a substitute for the prompt. Deliberately blunt: a
 * false positive costs one dropped bullet point, a false negative costs trust.
 */

export type SafetyFindingKind = 'blocked' | 'stripped';

export interface SafetyFinding {
  kind: SafetyFindingKind;
  rule: string;
  /** The offending text, truncated. Safe to log — it is model output, not user data. */
  sample: string;
}

interface SafetyRule {
  id: string;
  kind: SafetyFindingKind;
  pattern: RegExp;
}

/**
 * Appearance and protected-attribute judgements. These evaluate the person,
 * which BEFORE never does — it evaluates the purchase.
 */
const RULES: SafetyRule[] = [
  {
    /**
     * Structural, not a word list. "makes you look ___" evaluates the person
     * whatever fills the blank, and an adjective list will always be missing
     * the next word someone thinks of. BEFORE judges the purchase, so the whole
     * construction is blocked — which is the phrasing the spec calls out by name.
     */
    id: 'appearance_judgement',
    kind: 'blocked',
    pattern: /\b(?:makes?|making)\s+(?:you|her|him|them)\s+(?:look|seem|appear)\b/i,
  },
  {
    id: 'attractiveness_scoring',
    kind: 'blocked',
    pattern:
      /\b(?:attractiveness|sex appeal|how (?:attractive|hot|sexy)|flatter(?:s|ing)? your (?:figure|body|shape|curves))\b/i,
  },
  {
    id: 'body_judgement',
    kind: 'blocked',
    pattern:
      /\b(?:your|her|his|their)\s+(?:body\s*(?:type|shape)|figure|curves|waistline|thighs|bust|hips)\b(?![^.]*\b(?:measurement|size chart|fit guide)\b)/i,
  },
  {
    id: 'weight_commentary',
    kind: 'blocked',
    pattern:
      /\b(?:overweight|underweight|too (?:fat|skinny|thin|heavy)|lose weight|your weight|slimming|widening) (?:effect|on you)?\b|\b(?:overweight|underweight|lose weight|your weight)\b/i,
  },
  {
    id: 'protected_attribute',
    kind: 'blocked',
    pattern:
      /\b(?:for (?:a|an) (?:\w+\s+)?(?:woman|man|person) (?:of|with) (?:your|her|his) (?:age|race|ethnicity|skin tone|religion))\b/i,
  },
  {
    id: 'age_judgement',
    kind: 'stripped',
    pattern: /\b(?:too (?:old|young) for (?:you|her|him|them)|age[- ]appropriate for (?:you|her|him|them))\b/i,
  },
  /**
   * Rule 5 backstop: the model claiming certainty it was told it does not have.
   * Stripped rather than blocked — one overconfident bullet should not throw away
   * an otherwise sound analysis.
   */
  {
    id: 'fabricated_certainty',
    kind: 'stripped',
    pattern:
      /\b(?:definitely (?:costs|retails|is made of)|guaranteed to (?:sell out|save)|only \d+ left|certainly (?:authentic|genuine))\b/i,
  },
];

/** Scan one string. Returns the findings it triggered. */
export function scanText(text: string): SafetyFinding[] {
  const findings: SafetyFinding[] = [];
  for (const rule of RULES) {
    if (rule.pattern.test(text)) {
      findings.push({ kind: rule.kind, rule: rule.id, sample: text.slice(0, 120) });
    }
  }
  return findings;
}

export interface SafetyScanResult<T> {
  /** The input with `stripped` strings removed. */
  value: T;
  findings: SafetyFinding[];
  /** True when any `blocked` rule fired — the caller must not use `value`. */
  blocked: boolean;
}

/**
 * Scan a list of user-facing strings, dropping the ones that only warrant
 * stripping and reporting whether anything warrants blocking the whole analysis.
 */
export function scanStrings(values: string[]): SafetyScanResult<string[]> {
  const findings: SafetyFinding[] = [];
  const kept: string[] = [];
  let blocked = false;

  for (const value of values) {
    const hits = scanText(value);
    if (hits.length === 0) {
      kept.push(value);
      continue;
    }
    findings.push(...hits);
    if (hits.some((h) => h.kind === 'blocked')) {
      blocked = true;
    }
    // Anything that triggered a rule is dropped from the user-facing output,
    // whether or not it also blocks.
  }

  return { value: kept, findings, blocked };
}

/** Scan a single optional string. Returns null when it must not be shown. */
export function scanOptional(value: string | null): SafetyScanResult<string | null> {
  if (value === null || value.trim() === '') {
    return { value: null, findings: [], blocked: false };
  }
  const findings = scanText(value);
  const blocked = findings.some((f) => f.kind === 'blocked');
  return { value: findings.length === 0 ? value : null, findings, blocked };
}
