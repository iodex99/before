/**
 * BEFORE — provider factory.
 *
 * The one place that knows which concrete provider exists. Everything else
 * depends on the ShoppingAnalysisProvider interface.
 *
 * Note the import shape: the Anthropic adapter pulls in the official SDK, so it
 * is imported lazily. That keeps `npm run test:backend` and the mock path free
 * of a dependency they never use, and keeps the edge function's cold start
 * proportional to what it actually runs.
 */

import type { AiConfig } from '../config.ts';
import type { ShoppingAnalysisProvider } from './provider.ts';
import { ProviderError } from './provider.ts';
import { MockProvider, type MockFixture } from './providers/mock.ts';

export interface FactoryOptions {
  /** Required when config.mockMode is true. */
  fixtures?: MockFixture[];
  forceFixtureId?: string;
  mockLatencyMs?: number;
}

export async function createProvider(
  config: AiConfig,
  options: FactoryOptions = {},
): Promise<ShoppingAnalysisProvider> {
  if (config.mockMode) {
    if (!options.fixtures || options.fixtures.length === 0) {
      throw new ProviderError('bad_request', 'mock mode is on but no fixtures were supplied');
    }
    return new MockProvider({
      fixtures: options.fixtures,
      forceFixtureId: options.forceFixtureId,
      latencyMs: options.mockLatencyMs,
    });
  }

  switch (config.provider) {
    case 'anthropic': {
      const { AnthropicProvider } = await import('./providers/anthropic.ts');
      return new AnthropicProvider({
        apiKey: config.apiKey,
        model: config.model,
        effort: config.effort,
        refusalFallbacks: config.refusalFallbacks,
      });
    }
    case 'openai': {
      const { OpenAiProvider } = await import('./providers/openai.ts');
      return new OpenAiProvider({ apiKey: config.apiKey, model: config.model });
    }
    case 'gemini': {
      const { GeminiProvider } = await import('./providers/gemini.ts');
      return new GeminiProvider({ apiKey: config.apiKey, model: config.model });
    }
    case 'mock':
      throw new ProviderError('bad_request', 'AI_PROVIDER=mock requires AI_MOCK_MODE fixtures');
    default: {
      const exhaustive: never = config.provider;
      throw new ProviderError('bad_request', `unknown provider: ${String(exhaustive)}`);
    }
  }
}
