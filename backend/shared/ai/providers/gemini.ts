/**
 * BEFORE — Gemini provider.
 *
 * Same status as the OpenAI adapter: present so the provider abstraction is
 * real, implemented against REST to keep cold starts small, and not exercised
 * against a live key. See DECISIONS.md.
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

interface GenerateContentResponse {
  candidates?: Array<{
    content?: { parts?: Array<{ text?: string }> };
    finishReason?: string;
  }>;
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
  promptFeedback?: { blockReason?: string };
}

export interface GeminiProviderOptions {
  apiKey: string;
  model: string;
}

export class GeminiProvider implements ShoppingAnalysisProvider {
  readonly name = 'gemini' as const;
  readonly model: string;
  private readonly apiKey: string;

  constructor(options: GeminiProviderOptions) {
    if (!options.apiKey) throw new ProviderError('auth', 'GEMINI_API_KEY is not set');
    this.apiKey = options.apiKey;
    this.model = options.model;
  }

  private endpoint(): string {
    return `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(this.model)}:generateContent`;
  }

  async analyzePurchase(request: AnalysisRequest): Promise<ProviderResponse> {
    const started = Date.now();

    const parts: unknown[] = [];
    if (request.image) {
      parts.push({ inline_data: { mime_type: request.image.mediaType, data: request.image.data } });
    }
    parts.push({ text: request.userPrompt });

    const body = await postJson(
      this.endpoint(),
      { 'x-goog-api-key': this.apiKey },
      {
        system_instruction: { parts: [{ text: request.systemPrompt }] },
        contents: [{ role: 'user', parts }],
        generationConfig: {
          maxOutputTokens: request.maxOutputTokens,
          responseMimeType: 'application/json',
          responseSchema: ANALYSIS_JSON_SCHEMA,
        },
      },
      request.timeoutMs,
    );

    const response = body as GenerateContentResponse;

    if (response.promptFeedback?.blockReason) {
      throw new ProviderError(
        'content_filtered',
        `request blocked: ${response.promptFeedback.blockReason}`,
      );
    }

    const candidate = response.candidates?.[0];
    if (candidate?.finishReason === 'SAFETY' || candidate?.finishReason === 'PROHIBITED_CONTENT') {
      throw new ProviderError('content_filtered', 'response blocked by the provider');
    }
    if (candidate?.finishReason === 'MAX_TOKENS') {
      throw new ProviderError('bad_request', 'model hit the output limit before finishing');
    }

    const raw = candidate?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
    if (!raw.trim()) throw new ProviderError('server_error', 'provider returned no content');

    return {
      raw,
      usage: {
        inputTokens: response.usageMetadata?.promptTokenCount ?? null,
        outputTokens: response.usageMetadata?.candidatesTokenCount ?? null,
      },
      latencyMs: Date.now() - started,
      model: this.model,
      provider: 'gemini',
    };
  }

  async generateExplanation(analysis: ValidatedAnalysis, question: string): Promise<ProviderResponse> {
    const started = Date.now();
    const body = await postJson(
      this.endpoint(),
      { 'x-goog-api-key': this.apiKey },
      {
        system_instruction: {
          parts: [
            {
              text: 'You are BEFORE. Answer follow-up questions about an analysis you already produced. Two sentences maximum. Never introduce facts not present in the analysis. Never comment on the person.',
            },
          ],
        },
        contents: [
          {
            role: 'user',
            parts: [
              {
                text: `Analysis:\n${JSON.stringify({
                  product: analysis.product,
                  signals: analysis.signals,
                  reasoning: analysis.reasoning,
                })}\n\nQuestion: ${question}`,
              },
            ],
          },
        ],
        generationConfig: { maxOutputTokens: 400 },
      },
      20_000,
    );

    const response = body as GenerateContentResponse;
    const raw = response.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
    if (!raw.trim()) throw new ProviderError('server_error', 'provider returned no content');

    return {
      raw,
      usage: {
        inputTokens: response.usageMetadata?.promptTokenCount ?? null,
        outputTokens: response.usageMetadata?.candidatesTokenCount ?? null,
      },
      latencyMs: Date.now() - started,
      model: this.model,
      provider: 'gemini',
    };
  }
}
