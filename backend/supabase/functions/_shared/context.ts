/**
 * BEFORE — per-request context for edge functions.
 *
 * Establishes: a request id, the authenticated user, a Supabase client bound to
 * the caller's JWT (so RLS applies to everything the handler does), and a
 * separate service-role client for the few operations that must bypass it.
 *
 * The two clients are named so the distinction is impossible to miss at a call
 * site: `db` is the user, `admin` is not.
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { loadConfig, type AppConfig } from '@shared/config.ts';
import { ApiError, CORS_HEADERS, errorResponse } from '@shared/http/errors.ts';
import { Logger, durationBucket } from './log.ts';

export interface RequestContext {
  requestId: string;
  userId: string;
  /** Scoped to the caller. RLS applies. Use this by default. */
  db: SupabaseClient;
  /** Bypasses RLS. Only for quota ledgers, cost logs, and deletion. */
  admin: SupabaseClient;
  config: AppConfig;
  log: Logger;
  startedAt: number;
}

function newRequestId(): string {
  return crypto.randomUUID();
}

/**
 * Resolve the caller from the Authorization header.
 *
 * The JWT is verified by asking Supabase who it belongs to, rather than by
 * decoding it here. Decoding a JWT is not verifying it, and the difference is
 * the whole security model.
 */
async function authenticate(
  request: Request,
  config: AppConfig,
): Promise<{ userId: string; db: SupabaseClient }> {
  const header = request.headers.get('authorization') ?? '';
  const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : '';
  if (!token) throw new ApiError('unauthorized', 'missing bearer token');

  const db = createClient(config.supabaseUrl, token, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: header } },
  });

  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) throw new ApiError('unauthorized', 'token could not be verified');

  return { userId: data.user.id, db };
}

export type Handler = (request: Request, context: RequestContext) => Promise<Response>;

export interface HandlerOptions {
  endpoint: string;
  methods: string[];
}

/**
 * Wrap a handler with the things every endpoint needs and none of them should
 * re-implement: CORS preflight, method checking, auth, logging, and turning a
 * thrown error into a client-safe response.
 */
export function withContext(options: HandlerOptions, handler: Handler): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    const requestId = newRequestId();
    const startedAt = Date.now();
    const log = new Logger({ requestId, endpoint: options.endpoint, method: request.method });

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    try {
      if (!options.methods.includes(request.method)) {
        throw new ApiError('invalid_request', `${request.method} not allowed`);
      }

      const config = loadConfig(Deno.env.toObject());
      const { userId, db } = await authenticate(request, config);

      const admin = createClient(config.supabaseUrl, config.serviceRoleKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const context: RequestContext = {
        requestId,
        userId,
        db,
        admin,
        config,
        log: log.child({ userId }),
        startedAt,
      };

      const response = await handler(request, context);
      const latencyMs = Date.now() - startedAt;
      context.log.info('request.completed', {
        status: response.status,
        latencyMs,
        durationBucket: durationBucket(latencyMs),
      });
      return response;
    } catch (error) {
      const latencyMs = Date.now() - startedAt;
      if (error instanceof ApiError) {
        log.warn('request.failed', {
          status: error.status,
          errorCode: error.code,
          latencyMs,
          note: error.detail?.slice(0, 200),
        });
      } else {
        // Message deliberately not logged: an unexpected exception may carry a
        // URL, a key fragment, or a row of user data.
        log.error('request.errored', {
          status: 500,
          latencyMs,
          errorKind: error instanceof Error ? error.name : 'unknown',
        });
      }
      return errorResponse(error, requestId);
    }
  };
}

/**
 * Context for an endpoint Apple calls, which carries no user session.
 *
 * Deliberately a separate function rather than a flag on `withContext`: an
 * `requiresAuth: false` option is one typo away from opening a user endpoint to
 * the world, whereas an unauthenticated handler has to be written as one.
 *
 * There is no caller-scoped client here, because there is no caller. Everything
 * such a handler does runs with the service role, and its own verification is
 * the only thing standing in front of it.
 */
export interface PublicRequestContext {
  requestId: string;
  admin: SupabaseClient;
  config: AppConfig;
  log: Logger;
}

export function withPublicContext(
  options: HandlerOptions,
  handler: (request: Request, context: PublicRequestContext) => Promise<Response>,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    const requestId = crypto.randomUUID();
    const startedAt = Date.now();
    const log = new Logger({ requestId, endpoint: options.endpoint, method: request.method });

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    try {
      if (!options.methods.includes(request.method)) {
        throw new ApiError('invalid_request', `${request.method} not allowed`);
      }

      const config = loadConfig(Deno.env.toObject());
      const admin = createClient(config.supabaseUrl, config.serviceRoleKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const response = await handler(request, { requestId, admin, config, log });
      log.info('request.completed', {
        status: response.status,
        latencyMs: Date.now() - startedAt,
      });
      return response;
    } catch (error) {
      if (error instanceof ApiError) {
        log.warn('request.failed', {
          status: error.status,
          errorCode: error.code,
          latencyMs: Date.now() - startedAt,
          note: error.detail?.slice(0, 200),
        });
      } else {
        log.error('request.errored', {
          status: 500,
          latencyMs: Date.now() - startedAt,
          errorKind: error instanceof Error ? error.name : 'unknown',
        });
      }
      return errorResponse(error, requestId);
    }
  };
}

/** Parse a JSON body, with a size ceiling and a readable failure. */
export async function readJson<T>(request: Request, maxBytes = 12 * 1024 * 1024): Promise<T> {
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > maxBytes) throw new ApiError('image_too_large', `body declared ${declared} bytes`);

  let text: string;
  try {
    text = await request.text();
  } catch {
    throw new ApiError('invalid_request', 'body could not be read');
  }
  if (text.length > maxBytes) throw new ApiError('image_too_large', 'body exceeded the limit');

  try {
    return JSON.parse(text) as T;
  } catch {
    throw new ApiError('invalid_request', 'body was not valid JSON');
  }
}
