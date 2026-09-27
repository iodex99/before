/**
 * BEFORE — API errors.
 *
 * Every error the client can see has a stable code and a message written for a
 * person, not a stack trace. "Error 2" is not a thing this app is allowed to
 * show (spec §45).
 */

import type { ApiErrorBody, ApiErrorCode } from '../types.ts';

interface ErrorSpec {
  status: number;
  /** Shown to the user verbatim. Keep it short, specific, and non-blaming. */
  message: string;
}

export const ERROR_SPECS: Record<ApiErrorCode, ErrorSpec> = {
  unauthorized: { status: 401, message: 'Please sign in again.' },
  forbidden: { status: 403, message: "You don't have access to that." },
  quota_exceeded: {
    status: 402,
    message: "You've used all your checks this month.",
  },
  // A paying subscriber past the fair-use ceiling. Deliberately NOT an upsell
  // and deliberately not the same message as a per-minute limit.
  fair_use_exceeded: {
    status: 429,
    message: "You've hit this month's fair-use limit. It resets at the start of next month.",
  },
  rate_limited: { status: 429, message: 'Give it a moment and try again.' },
  invalid_request: { status: 400, message: "Something about that request didn't look right." },
  image_too_large: {
    status: 413,
    message: "That image is too large or couldn't be read. Try another photo.",
  },
  image_unreadable: {
    status: 400,
    message: "That image is too large or couldn't be read. Try another photo.",
  },
  url_unreadable: {
    status: 422,
    message: "We couldn't read the product page. You can still send us a screenshot.",
  },
  analysis_failed: { status: 502, message: "We couldn't finish that analysis." },
  provider_unavailable: { status: 503, message: "We couldn't finish that analysis." },
  content_unsupported: {
    status: 422,
    message: "We couldn't analyse that image. Try a photo of the product itself.",
  },
  not_found: { status: 404, message: "We couldn't find that." },
  conflict: { status: 409, message: 'That was already being processed.' },
  internal_error: { status: 500, message: 'Something went wrong on our side.' },
};

export class ApiError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number;
  readonly userMessage: string;
  readonly retryAfterSeconds?: number;
  /** Internal detail for logs. Never sent to the client. */
  readonly detail?: string;

  constructor(code: ApiErrorCode, detail?: string, retryAfterSeconds?: number) {
    const spec = ERROR_SPECS[code];
    super(detail ? `${code}: ${detail}` : code);
    this.name = 'ApiError';
    this.code = code;
    this.status = spec.status;
    this.userMessage = spec.message;
    this.retryAfterSeconds = retryAfterSeconds;
    this.detail = detail;
  }

  toBody(requestId: string): ApiErrorBody {
    return {
      error: {
        code: this.code,
        message: this.userMessage,
        requestId,
        ...(this.retryAfterSeconds !== undefined
          ? { retryAfterSeconds: this.retryAfterSeconds }
          : {}),
      },
    };
  }
}

export const CORS_HEADERS: Record<string, string> = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, x-client-info, apikey, content-type, idempotency-key',
  'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
};

export function jsonResponse(body: unknown, status: number, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...CORS_HEADERS, ...extraHeaders },
  });
}

/**
 * Turn anything thrown into a client-safe response. An unrecognised error
 * becomes a generic 500 — an unexpected exception must never leak its message,
 * which may contain a URL, a key fragment, or a row of user data.
 */
export function errorResponse(error: unknown, requestId: string): Response {
  if (error instanceof ApiError) {
    // Annotated rather than inferred: a bare ternary gives the union
    // `{ 'retry-after': string } | { 'retry-after'?: undefined }`, which is not
    // assignable to Record<string, string>.
    const headers: Record<string, string> =
      error.retryAfterSeconds !== undefined
        ? { 'retry-after': String(error.retryAfterSeconds) }
        : {};
    return jsonResponse(error.toBody(requestId), error.status, headers);
  }

  const fallback = new ApiError('internal_error');
  return jsonResponse(fallback.toBody(requestId), fallback.status);
}
