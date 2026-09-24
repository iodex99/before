/**
 * BEFORE — Anthropic provider (the default).
 *
 * Uses the official @anthropic-ai/sdk. Three decisions worth knowing:
 *
 * 1. STRUCTURED OUTPUT VIA STRICT TOOL USE. The analysis schema is handed over
 *    as a `strict: true` tool with `tool_choice: auto`, plus an instruction
 *    naming the tool. Forced tool choice returns a 400 on several current
 *    models, so `auto` keeps this provider working across whatever AI_MODEL is
 *    set to. If the model answers in prose anyway, we fall back to parsing the
 *    text — the validator is the real trust boundary either way.
 *
 * 2. PROMPT CACHING ON THE SYSTEM PROMPT. It is byte-identical for every user,
 *    so it is marked cacheable. Nothing volatile (no timestamp, no request id)
 *    may ever be added to it or the cache silently stops hitting.
 *
 * 3. REFUSAL HANDLING. A fashion photo containing a person can trip a safety
 *    classifier. `stop_reason: "refusal"` arrives as HTTP 200, so it is checked
 *    explicitly before the content is read, and server-side fallbacks are on by
 *    default so a decline is retried on another model inside the same call.
 */

import Anthropic from '@anthropic-ai/sdk';

import {
  type AnalysisRequest,
  type ProviderResponse,
  ProviderError,
  type ShoppingAnalysisProvider,
} from '../provider.ts';
import { ANALYSIS_JSON_SCHEMA } from '../schema.ts';
import type { ValidatedAnalysis } from '../schema.ts';

const TOOL_NAME = 'submit_analysis';

export interface AnthropicProviderOptions {
  apiKey: string;
  model: string;
  /** low | medium | high | xhigh | max. Default medium: this is a latency-
   *  sensitive consumer path, not a long-horizon agentic task. */
  effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  /** Server-side refusal fallbacks. On by default. */
  refusalFallbacks?: boolean;
  maxRetries?: number;
}

export class AnthropicProvider implements ShoppingAnalysisProvider {
  readonly name = 'anthropic' as const;
  readonly model: string;

  private readonly client: Anthropic;
  private readonly effort: NonNullable<AnthropicProviderOptions['effort']>;
  private readonly refusalFallbacks: boolean;

  constructor(options: AnthropicProviderOptions) {
    if (!options.apiKey) {
      throw new ProviderError('auth', 'ANTHROPIC_API_KEY is not set');
    }
    this.model = options.model;
    this.effort = options.effort ?? 'medium';
    this.refusalFallbacks = options.refusalFallbacks ?? true;
    this.client = new Anthropic({
      apiKey: options.apiKey,
      // The SDK retries 429/5xx itself. One retry, because a user is waiting.
      maxRetries: options.maxRetries ?? 1,
    });
  }

  async analyzePurchase(request: AnalysisRequest): Promise<ProviderResponse> {
    const started = Date.now();

    const content: Anthropic.ContentBlockParam[] = [];
    if (request.image) {
      content.push({
        type: 'image',
        source: {
          type: 'base64',
          media_type: request.image.mediaType,
          data: request.image.data,
        },
      });
    }
    content.push({ type: 'text', text: request.userPrompt });

    let response: Anthropic.Beta.BetaMessage;
    try {
      response = await this.client.beta.messages.create(
        {
          model: this.model,
          max_tokens: request.maxOutputTokens,
          system: [
            {
              type: 'text',
              // Invariant: this text must not vary per request, or the cache dies.
              text: request.systemPrompt,
              cache_control: { type: 'ephemeral' },
            },
          ],
          output_config: { effort: this.effort },
          tools: [
            {
              name: TOOL_NAME,
              description:
                'Submit the completed purchase analysis. Call this exactly once with the full result.',
              strict: true,
              input_schema: ANALYSIS_JSON_SCHEMA as unknown as Anthropic.Beta.BetaTool['input_schema'],
            },
          ],
          tool_choice: { type: 'auto' },
          messages: [{ role: 'user', content }],
          ...(this.refusalFallbacks
            ? { betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' as const }
            : {}),
        },
        { timeout: request.timeoutMs },
      );
    } catch (error) {
      throw translateError(error);
    }

    // A refusal is an HTTP 200. Check it before touching content.
    if (response.stop_reason === 'refusal') {
      const category = response.stop_details?.category ?? 'unspecified';
      throw new ProviderError('content_filtered', `model declined the request (${category})`);
    }

    if (response.stop_reason === 'max_tokens') {
      throw new ProviderError(
        'bad_request',
        'model hit the output limit before finishing — raise AI_MAX_OUTPUT_TOKENS',
      );
    }

    return {
      raw: extractPayload(response),
      usage: {
        inputTokens: response.usage?.input_tokens ?? null,
        outputTokens: response.usage?.output_tokens ?? null,
      },
      latencyMs: Date.now() - started,
      model: response.model ?? this.model,
      provider: 'anthropic',
    };
  }

  async generateExplanation(analysis: ValidatedAnalysis, question: string): Promise<ProviderResponse> {
    const started = Date.now();
    const summary = JSON.stringify({
      product: analysis.product,
      signals: analysis.signals,
      reasoning: analysis.reasoning,
    });

    let response: Anthropic.Message;
    try {
      response = await this.client.messages.create(
        {
          model: this.model,
          max_tokens: 600,
          output_config: { effort: 'low' },
          system: [
            {
              type: 'text',
              text: 'You are BEFORE. Answer follow-up questions about an analysis you already produced. Two sentences maximum. Never introduce facts that are not in the analysis. Never comment on the person, only the product and the styling.',
              cache_control: { type: 'ephemeral' },
            },
          ],
          messages: [{ role: 'user', content: `Analysis:\n${summary}\n\nQuestion: ${question}` }],
        },
        { timeout: 20_000 },
      );
    } catch (error) {
      throw translateError(error);
    }

    if (response.stop_reason === 'refusal') {
      throw new ProviderError('content_filtered', 'model declined the follow-up question');
    }

    const text = response.content
      .filter((block): block is Anthropic.TextBlock => block.type === 'text')
      .map((block) => block.text)
      .join('\n')
      .trim();

    return {
      raw: text,
      usage: {
        inputTokens: response.usage?.input_tokens ?? null,
        outputTokens: response.usage?.output_tokens ?? null,
      },
      latencyMs: Date.now() - started,
      model: response.model ?? this.model,
      provider: 'anthropic',
    };
  }
}

/**
 * Prefer the tool call. Fall back to any text the model produced, which the
 * validator will then try to parse — a prose answer is recoverable, a dropped
 * analysis is not.
 */
function extractPayload(response: Anthropic.Beta.BetaMessage): string {
  for (const block of response.content) {
    if (block.type === 'tool_use' && block.name === TOOL_NAME) {
      return JSON.stringify(block.input);
    }
  }

  const text = response.content
    .filter((block): block is Anthropic.Beta.BetaTextBlock => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
    .trim();

  if (!text) {
    throw new ProviderError('server_error', 'model returned neither a tool call nor any text');
  }
  return text;
}

/** SDK exceptions to our transport-neutral error kinds. Most specific first. */
function translateError(error: unknown): ProviderError {
  if (error instanceof ProviderError) return error;

  if (error instanceof Anthropic.APIConnectionTimeoutError) {
    return new ProviderError('timeout', error.message);
  }
  if (error instanceof Anthropic.AuthenticationError) {
    return new ProviderError('auth', 'Anthropic rejected the API key', error.status);
  }
  if (error instanceof Anthropic.PermissionDeniedError) {
    return new ProviderError('auth', error.message, error.status);
  }
  if (error instanceof Anthropic.RateLimitError) {
    return new ProviderError('rate_limited', 'Anthropic rate limit reached', error.status);
  }
  if (error instanceof Anthropic.BadRequestError) {
    return new ProviderError('bad_request', error.message, error.status);
  }
  if (error instanceof Anthropic.InternalServerError) {
    return new ProviderError('server_error', error.message, error.status);
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return new ProviderError('network', error.message);
  }
  if (error instanceof Anthropic.APIError) {
    return new ProviderError('unknown', error.message, error.status ?? null);
  }
  return new ProviderError('unknown', error instanceof Error ? error.message : String(error));
}
