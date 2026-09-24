/**
 * Quota, rate limits, and the calendar-month window.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  assertWithinRateLimits,
  evaluateQuota,
  monthWindow,
  safeTimezone,
  type UsageCounts,
} from '../shared/http/quota.ts';
import { ApiError, ERROR_SPECS, errorResponse, jsonResponse } from '../shared/http/errors.ts';
import { API_ERROR_CODES } from '../shared/types.ts';

const quotaConfig = {
  freeMonthlyAnalyses: 5,
  analysesPerMinute: 6,
  analysesPerDay: 120,
  metadataPerMinute: 20,
  maxUploadBytes: 6 * 1024 * 1024,
  maxConcurrentAnalyses: 2,
};

function counts(overrides: Partial<UsageCounts> = {}): UsageCounts {
  return { monthUsed: 0, lastMinuteUsed: 0, lastDayUsed: 0, inFlight: 0, ...overrides };
}

// ---------------------------------------------------------------------------
// Quota
// ---------------------------------------------------------------------------

test('a free user gets five checks a month', () => {
  assert.deepEqual(evaluateQuota(counts({ monthUsed: 0 }), false, quotaConfig), {
    allowed: true,
    limit: 5,
    remaining: 5,
  });
  assert.deepEqual(evaluateQuota(counts({ monthUsed: 4 }), false, quotaConfig), {
    allowed: true,
    limit: 5,
    remaining: 1,
  });
});

test('the fifth check is allowed and the sixth is not', () => {
  assert.equal(evaluateQuota(counts({ monthUsed: 4 }), false, quotaConfig).allowed, true);
  assert.equal(evaluateQuota(counts({ monthUsed: 5 }), false, quotaConfig).allowed, false);
});

test('remaining never goes negative', () => {
  const decision = evaluateQuota(counts({ monthUsed: 99 }), false, quotaConfig);
  assert.equal(decision.remaining, 0);
  assert.equal(decision.allowed, false);
});

test('a Plus user has no monthly cap', () => {
  assert.deepEqual(evaluateQuota(counts({ monthUsed: 500 }), true, quotaConfig), {
    allowed: true,
    limit: null,
    remaining: null,
  });
});

// ---------------------------------------------------------------------------
// Rate limits — these apply to Plus too
// ---------------------------------------------------------------------------

test('normal usage passes the rate limiter', () => {
  assert.doesNotThrow(() => assertWithinRateLimits(counts({ lastMinuteUsed: 2 }), quotaConfig));
});

test('too many concurrent analyses is refused with a short retry', () => {
  assert.throws(
    () => assertWithinRateLimits(counts({ inFlight: 2 }), quotaConfig),
    (error: unknown) =>
      error instanceof ApiError && error.code === 'rate_limited' && error.retryAfterSeconds === 5,
  );
});

test('the per-minute limit is enforced', () => {
  assert.throws(
    () => assertWithinRateLimits(counts({ lastMinuteUsed: 6 }), quotaConfig),
    (error: unknown) => error instanceof ApiError && error.retryAfterSeconds === 60,
  );
});

test('the daily limit is enforced', () => {
  assert.throws(
    () => assertWithinRateLimits(counts({ lastDayUsed: 120 }), quotaConfig),
    (error: unknown) => error instanceof ApiError && error.retryAfterSeconds === 3600,
  );
});

// ---------------------------------------------------------------------------
// Month window
// ---------------------------------------------------------------------------

test('the month window covers the user\'s own calendar month, not UTC\'s', () => {
  // 2026-03-01 04:00 UTC is still 2026-02-28 20:00 in Los Angeles. The window
  // must be February's, or the user silently loses the end of every month.
  const { start, end } = monthWindow(new Date('2026-03-01T04:00:00Z'), 'America/Los_Angeles');
  assert.equal(start.toISOString(), '2026-02-01T08:00:00.000Z');
  assert.equal(end.toISOString(), '2026-03-01T08:00:00.000Z');
});

test('a UTC user gets a plain UTC month', () => {
  const { start, end } = monthWindow(new Date('2026-03-15T12:00:00Z'), 'UTC');
  assert.equal(start.toISOString(), '2026-03-01T00:00:00.000Z');
  assert.equal(end.toISOString(), '2026-04-01T00:00:00.000Z');
});

test('the window rolls over December correctly', () => {
  const { start, end } = monthWindow(new Date('2026-12-20T12:00:00Z'), 'UTC');
  assert.equal(start.toISOString(), '2026-12-01T00:00:00.000Z');
  assert.equal(end.toISOString(), '2027-01-01T00:00:00.000Z');
});

test('the window holds across a DST transition', () => {
  // US DST began 2026-03-08. A window opened in March must still start on the
  // 1st, at the offset in force then.
  const { start, end } = monthWindow(new Date('2026-03-20T12:00:00Z'), 'America/New_York');
  assert.equal(start.toISOString(), '2026-03-01T05:00:00.000Z', 'EST offset on 1 March');
  assert.equal(end.toISOString(), '2026-04-01T04:00:00.000Z', 'EDT offset on 1 April');
});

test('the window is always start < now < end', () => {
  const zones = ['UTC', 'America/Los_Angeles', 'Europe/London', 'Asia/Tokyo', 'Australia/Sydney', 'Pacific/Kiritimati'];
  const instants = ['2026-01-01T00:00:00Z', '2026-06-15T23:30:00Z', '2026-12-31T23:59:00Z'];
  for (const zone of zones) {
    for (const instant of instants) {
      const now = new Date(instant);
      const { start, end } = monthWindow(now, zone);
      assert.ok(start <= now, `${zone} @ ${instant}: start ${start.toISOString()} after now`);
      assert.ok(end > now, `${zone} @ ${instant}: end ${end.toISOString()} not after now`);
    }
  }
});

test('an invalid timezone falls back to UTC instead of throwing', () => {
  assert.equal(safeTimezone('Mars/Olympus_Mons'), 'UTC');
  assert.equal(safeTimezone(null), 'UTC');
  assert.equal(safeTimezone(''), 'UTC');
  assert.equal(safeTimezone('Europe/Paris'), 'Europe/Paris');
});

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

test('every error code has a user-facing message and a sane status', () => {
  for (const code of API_ERROR_CODES) {
    const spec = ERROR_SPECS[code];
    assert.ok(spec, `no spec for ${code}`);
    assert.ok(spec.status >= 400 && spec.status < 600, `${code} has status ${spec.status}`);
    assert.ok(spec.message.length > 0, `${code} has no message`);
    assert.ok(
      !/error \d|null|undefined|exception/i.test(spec.message),
      `${code} message reads like a stack trace: "${spec.message}"`,
    );
  }
});

test('quota exceeded is a distinct status the client can key the paywall on', () => {
  assert.equal(ERROR_SPECS.quota_exceeded.status, 402);
  assert.equal(ERROR_SPECS.rate_limited.status, 429);
});

test('an ApiError serialises with its code and request id', async () => {
  const response = errorResponse(new ApiError('quota_exceeded', 'internal detail'), 'req-123');
  assert.equal(response.status, 402);
  const body = await response.json();
  assert.equal(body.error.code, 'quota_exceeded');
  assert.equal(body.error.requestId, 'req-123');
  assert.equal(body.error.message, ERROR_SPECS.quota_exceeded.message);
  assert.ok(
    !JSON.stringify(body).includes('internal detail'),
    'internal detail must never reach the client',
  );
});

test('an unexpected exception becomes a generic 500 and leaks nothing', async () => {
  const response = errorResponse(
    new Error('connection string postgres://user:hunter2@db/x failed'),
    'req-9',
  );
  assert.equal(response.status, 500);
  const text = await response.text();
  assert.ok(!text.includes('hunter2'), 'an unexpected error must not leak its message');
  assert.ok(text.includes('internal_error'));
});

test('rate limiting sets Retry-After', () => {
  const response = errorResponse(new ApiError('rate_limited', 'slow down', 42), 'req-1');
  assert.equal(response.headers.get('retry-after'), '42');
});

test('responses carry CORS headers', () => {
  const response = jsonResponse({ ok: true }, 200);
  assert.equal(response.headers.get('access-control-allow-origin'), '*');
  assert.ok(response.headers.get('access-control-allow-headers')?.includes('idempotency-key'));
});
