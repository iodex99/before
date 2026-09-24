/**
 * BEFORE — OpenAI provider.
 *
 * Not the default path. It exists because the spec requires the architecture to
 * support swapping providers, and an abstraction with exactly one implementation
 * is not an abstraction. Implemented against the REST API rather than the SDK to
 * keep the edge function's cold start small — this adapter is a fallback, not
 * the hot path. It has not been exercised against a live key; see DECISIONS.md.
 */

import {
  type AnalysisRequest,
  type ProviderResponse,
  ProviderError,
  type ShoppingAnalysisProvider,
  postJson,
} from '../provider.ts';
import { ANALYSIS_JSON_SCHEMA } from '../schema.ts';
import type { ValidatedAnalysis } from '../schema.ts';

const ENDPOINT = 'https://api.openai.com/v1/chat/completions';

interface ChatCompletion {
  choices?: Array<{ message?: { content?: string | null }; finish_reason?: string }>;
  usage?: { prompt_tokens?: number; completion_tokens?: number };
  model?: string;
}

export interface OpenAiProviderOptions {
  apiKey: string;
  model: string;
}

export class OpenAiProvider implements ShoppingAnalysisProvider {
  readonly name = 'openai' as const;
  readonly model: string;
  private readonly apiKey: string;

  constructor(options: OpenAiProviderOptions) {
    if (!options.apiKey) throw new ProviderError('auth', 'OPENAI_API_KEY is not set');
    this.apiKey = options.apiKey;
    this.model = options.model;
  }

  async analyzePurchase(request: AnalysisRequest): Promise<ProviderResponse> {
    const started = Date.now();

    const content: unknown[] = [];
    if (request.image) {
      content.push({
        type: 'image_url',
        image_url: { url: `data:${request.image.mediaType};base64,${request.image.data}` },
      });
    }
    content.push({ type: 'text', text: request.userPrompt });

    const body = await postJson(
      ENDPOINT,
      { authorization: `Bearer ${this.apiKey}` },
      {
        model: this.model,
        max_completion_tokens: request.maxOutputTokens,
        messages: [
          { role: 'system', content: request.systemPrompt },
          { role: 'user', content },
        ],
        response_format: {
          type: 'json_schema',
          json_schema: { name: 'purchase_analysis', strict: true, schema: ANALYSIS_JSON_SCHEMA },
        },
      },
      request.timeoutMs,
    );

    const completion = body as ChatCompletion;
    const choice = completion.choices?.[0];

    if (choice?.finish_reason === 'content_filter') {
      throw new ProviderError('content_filtered', 'the request was filtered by the provider');
    }
    if (choice?.finish_reason === 'length') {
      throw new ProviderError('bad_request', 'model hit the output limit before finishing');
    }

    const raw = choice?.message?.content;
    if (!raw) throw new ProviderError('server_error', 'provider returned no content');

    return {
      raw,
      usage: {
        inputTokens: completion.usage?.prompt_tokens ?? null,
        outputTokens: completion.usage?.completion_tokens ?? null,
      },
      latencyMs: Date.now() - started,
      model: completion.model ?? this.model,
      provider: 'openai',
    };
  }

  async generateExplanation(analysis: ValidatedAnalysis, question: string): Promise<ProviderResponse> {
    const started = Date.now();
    const body = await postJson(
      ENDPOINT,
      { authorization: `Bearer ${this.apiKey}` },
      {
        model: this.model,
        max_completion_tokens: 400,
        messages: [
          {
            role: 'system',
            content:
              'You are BEFORE. Answer follow-up questions about an analysis you already produced. Two sentences maximum. Never introduce facts not present in the analysis. Never comment on the person.',
          },
          {
            role: 'user',
            content: `Analysis:\n${JSON.stringify({
              product: analysis.product,
              signals: analysis.signals,
              reasoning: analysis.reasoning,
            })}\n\nQuestion: ${question}`,
          },
        ],
      },
      20_000,
    );

    const completion = body as ChatCompletion;
    const raw = completion.choices?.[0]?.message?.content;
    if (!raw) throw new ProviderError('server_error', 'provider returned no content');

    return {
      raw,
      usage: {
        inputTokens: completion.usage?.prompt_tokens ?? null,
        outputTokens: completion.usage?.completion_tokens ?? null,
      },
      latencyMs: Date.now() - started,
      model: completion.model ?? this.model,
      provider: 'openai',
    };
  }
}
