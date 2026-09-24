/**
 * BEFORE — provider abstraction.
 *
 * The app never talks to a model. This is the only layer that does, and it is
 * deliberately thin: build a request, get raw text back, hand it to the
 * validator. Swapping providers must not require touching the prompt, the
 * validator, the score engine, or a single line of Swift.
 */

import type { ValidatedAnalysis } from './schema.ts';

export const AI_PROVIDERS = ['anthropic', 'openai', 'gemini', 'mock'] as const;
export type AiProviderName = (typeof AI_PROVIDERS)[number];

export interface ImageAttachment {
  /** Base64, without a data: prefix. */
  data: string;
  mediaType: 'image/jpeg' | 'image/png' | 'image/webp';
}

export interface AnalysisRequest {
  systemPrompt: string;
  userPrompt: string;
  image: ImageAttachment | null;
  maxOutputTokens: number;
  timeoutMs: number;
  /** Stable per-analysis id, forwarded for provider-side tracing. */
  requestId: string;
}

export interface ProviderUsage {
  inputTokens: number | null;
  outputTokens: number | null;
}

export interface ProviderResponse {
  /** Raw model text. Always passed through the validator, never used directly. */
  raw: string;
  usage: ProviderUsage;
  latencyMs: number;
  model: string;
  provider: AiProviderName;
}

/** Error categories, used for logging and for deciding whether to retry. */
export type ProviderErrorKind =
  | 'timeout'
  | 'rate_limited'
  | 'auth'
  | 'bad_request'
  | 'server_error'
  | 'content_filtered'
  | 'network'
  | 'unknown';

export class ProviderError extends Error {
  readonly kind: ProviderErrorKind;
  readonly status: number | null;
  readonly retryable: boolean;

  constructor(kind: ProviderErrorKind, message: string, status: number | null = null) {
    super(message);
    this.name = 'ProviderError';
    this.kind = kind;
    this.status = status;
    this.retryable = kind === 'timeout' || kind === 'rate_limited' || kind === 'server_error' || kind === 'network';
  }
}

/**
 * The interface every provider implements.
 *
 * `generateExplanation` exists now because the alternative is discovering later
 * that explanation generation was wired straight into the analysis path.
 * `compareProducts` and `generateAlternatives` are deliberately absent until
 * they are actually built — see TODO.md.
 */
export interface ShoppingAnalysisProvider {
  readonly name: AiProviderName;
  readonly model: string;
  analyzePurchase(request: AnalysisRequest): Promise<ProviderResponse>;
  generateExplanation(analysis: ValidatedAnalysis, question: string): Promise<ProviderResponse>;
}

export interface ProviderConfig {
  provider: AiProviderName;
  model: string;
  apiKey: string;
  maxOutputTokens: number;
  timeoutMs: number;
}

/** Shared fetch wrapper: timeout handling and error classification in one place. */
export async function postJson(
  url: string,
  headers: Record<string, string>,
  body: unknown,
  timeoutMs: number,
): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new ProviderError('timeout', `provider did not respond within ${timeoutMs}ms`);
    }
    throw new ProviderError('network', error instanceof Error ? error.message : 'network failure');
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    const text = await response.text().catch(() => '');
    // Truncated: provider error bodies can echo the request, which may include
    // the prompt. Enough to debug, not enough to leak context into logs.
    const detail = text.slice(0, 300);
    throw new ProviderError(classifyStatus(response.status), detail || response.statusText, response.status);
  }

  return response.json();
}

export function classifyStatus(status: number): ProviderErrorKind {
  if (status === 401 || status === 403) return 'auth';
  if (status === 429) return 'rate_limited';
  if (status === 400 || status === 422) return 'bad_request';
  if (status >= 500) return 'server_error';
  return 'unknown';
}
