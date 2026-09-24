/**
 * BEFORE — cost estimation for internal logging only.
 *
 * Never shown to a user (spec §51). Used to answer "what is an analysis costing
 * us" and to spot a regression where the context has quietly doubled.
 *
 * These rates go stale. An unknown model returns null rather than a wrong
 * number, because a confidently wrong cost figure is worse than a missing one.
 * Update alongside a model change; see docs/AI.md.
 */

export interface TokenRate {
  /** USD per million input tokens. */
  inputPerMillion: number;
  /** USD per million output tokens. */
  outputPerMillion: number;
}

/** Rates as published 2026-06. Verify before relying on these for budgeting. */
export const MODEL_RATES: Record<string, TokenRate> = {
  'claude-opus-5': { inputPerMillion: 5, outputPerMillion: 25 },
  'claude-opus-5-5': { inputPerMillion: 4, outputPerMillion: 20 },
  'claude-opus-4-8': { inputPerMillion: 5, outputPerMillion: 25 },
  'claude-sonnet-5': { inputPerMillion: 2, outputPerMillion: 10 },
  'claude-haiku-4-5': { inputPerMillion: 1, outputPerMillion: 5 },
};

export function estimateCostUsd(
  model: string,
  inputTokens: number | null,
  outputTokens: number | null,
): number | null {
  const rate = MODEL_RATES[model];
  if (!rate || inputTokens === null || outputTokens === null) return null;

  const cost =
    (inputTokens / 1_000_000) * rate.inputPerMillion +
    (outputTokens / 1_000_000) * rate.outputPerMillion;

  return Math.round(cost * 1_000_000) / 1_000_000;
}
