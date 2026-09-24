/**
 * BEFORE — mock provider.
 *
 * Returns deterministic fixtures so the whole pipeline (validation, scoring,
 * persistence, the iOS UI) can be exercised without spending money or waiting
 * on a model. Selection is stable per request id, so re-running the same
 * analysis gives the same answer while different analyses cycle through all
 * three verdicts — which is what you want when building the result screen.
 *
 * config.ts refuses to construct this provider when APP_ENV=production.
 */

import {
  type AnalysisRequest,
  type ProviderResponse,
  ProviderError,
  type ShoppingAnalysisProvider,
} from '../provider.ts';
import type { ValidatedAnalysis } from '../schema.ts';

export interface MockFixture {
  id: string;
  expectedScore: number;
  expectedVerdict: 'BUY' | 'WAIT' | 'BYE';
  response: Record<string, unknown>;
}

export interface MockProviderOptions {
  fixtures: MockFixture[];
  /** Pin every response to one fixture. Used by tests and by UI screenshots. */
  forceFixtureId?: string;
  /** Simulated latency so loading states are actually visible in development. */
  latencyMs?: number;
}

/** FNV-1a. Small, stable, and identical across runtimes — which matters here. */
export function stableHash(input: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

export class MockProvider implements ShoppingAnalysisProvider {
  readonly name = 'mock' as const;
  readonly model = 'mock-fixture-v1';

  private readonly fixtures: MockFixture[];
  private readonly forceFixtureId?: string;
  private readonly latencyMs: number;

  constructor(options: MockProviderOptions) {
    if (options.fixtures.length === 0) {
      throw new ProviderError('bad_request', 'mock provider needs at least one fixture');
    }
    this.fixtures = options.fixtures;
    this.forceFixtureId = options.forceFixtureId;
    this.latencyMs = options.latencyMs ?? 0;
  }

  /** Exposed so tests can assert the fixture that a given request will get. */
  select(requestId: string): MockFixture {
    if (this.forceFixtureId) {
      const pinned = this.fixtures.find((f) => f.id === this.forceFixtureId);
      if (!pinned) {
        throw new ProviderError('bad_request', `no mock fixture named "${this.forceFixtureId}"`);
      }
      return pinned;
    }
    return this.fixtures[stableHash(requestId) % this.fixtures.length];
  }

  async analyzePurchase(request: AnalysisRequest): Promise<ProviderResponse> {
    const started = Date.now();
    const fixture = this.select(request.requestId);

    if (this.latencyMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, this.latencyMs));
    }

    return {
      raw: JSON.stringify(fixture.response),
      usage: { inputTokens: null, outputTokens: null },
      latencyMs: Date.now() - started,
      model: this.model,
      provider: 'mock',
    };
  }

  async generateExplanation(_analysis: ValidatedAnalysis, _question: string): Promise<ProviderResponse> {
    return {
      raw: 'This is a mocked explanation. Set AI_MOCK_MODE=false to use a real provider.',
      usage: { inputTokens: null, outputTokens: null },
      latencyMs: 0,
      model: this.model,
      provider: 'mock',
    };
  }
}
