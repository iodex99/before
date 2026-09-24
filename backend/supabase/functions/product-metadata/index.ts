/**
 * POST /v1/product-metadata — read what a product page says about itself.
 *
 * Used by the paste-a-link flow so the user sees a title and a price before
 * committing a check. Cached across users, because two people pasting the same
 * product link should cost one fetch.
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { readMetadataCache, writeMetadataCache } from '../_shared/repository.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import {
  UrlUnreadableError,
  fetchProductMetadata,
  normaliseProductUrl,
} from '@shared/product/metadata.ts';

interface Body {
  url?: string;
}

/**
 * Simple per-user, per-minute limiter for this endpoint.
 *
 * In-memory, so it is per-isolate rather than global — which is a real
 * limitation, not a subtlety to gloss over. It stops a runaway client; it does
 * not stop a distributed one. The durable limit lives on the analysis path,
 * which is where the cost actually is.
 */
const recentCalls = new Map<string, number[]>();

function checkRate(userId: string, perMinute: number): void {
  const now = Date.now();
  const window = (recentCalls.get(userId) ?? []).filter((at) => now - at < 60_000);
  if (window.length >= perMinute) {
    throw new ApiError('rate_limited', 'metadata fetch limit reached', 60);
  }
  window.push(now);
  recentCalls.set(userId, window);

  if (recentCalls.size > 5000) recentCalls.clear();
}

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const body = await readJson<Body>(request, 8192);
  if (!body.url) throw new ApiError('invalid_request', 'url is required');

  checkRate(ctx.userId, ctx.config.quota.metadataPerMinute);

  let normalised: string;
  try {
    normalised = normaliseProductUrl(body.url).toString();
  } catch (error) {
    throw new ApiError('url_unreadable', error instanceof UrlUnreadableError ? error.reason : 'bad url');
  }

  const cached = await readMetadataCache(ctx.admin, normalised);
  if (cached) {
    ctx.log.info('metadata.cache_hit', { cacheHit: true });
    return jsonResponse({ url: normalised, metadata: cached, cached: true }, 200);
  }

  try {
    const { metadata } = await fetchProductMetadata(normalised);
    await writeMetadataCache(ctx.admin, normalised, metadata);
    ctx.log.info('metadata.fetched', { cacheHit: false });
    return jsonResponse({ url: normalised, metadata, cached: false }, 200);
  } catch (error) {
    // A page that will not identify itself is an expected outcome. The client
    // falls back to a screenshot; we do not try to defeat the page.
    ctx.log.info('metadata.unreadable', {
      note: error instanceof UrlUnreadableError ? error.reason : 'fetch failed',
    });
    throw new ApiError(
      'url_unreadable',
      error instanceof UrlUnreadableError ? error.reason : 'fetch failed',
    );
  }
}

Deno.serve(withContext({ endpoint: '/v1/product-metadata', methods: ['POST'] }, handler));
