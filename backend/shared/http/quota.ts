/**
 * BEFORE — quota and rate-limit decisions.
 *
 * Pure decision logic, separated from storage so it can be tested without a
 * database. The edge function supplies the counts; this decides.
 *
 * Two different things live here and they are not the same:
 *   QUOTA      the product rule — 5 free checks a month. Plus removes it.
 *   RATE LIMIT the anti-abuse rule — applies to everyone, Plus included.
 *              This is why the paywall says "Unlimited checks" and the docs
 *              say what the real ceiling is (spec §52).
 */

import type { QuotaConfig } from '../config.ts';
import { ApiError } from './errors.ts';

export interface UsageCounts {
  /** Analyses in the current calendar month, in the user's own timezone. */
  monthUsed: number;
  lastMinuteUsed: number;
  lastDayUsed: number;
  inFlight: number;
}

export interface QuotaDecision {
  allowed: boolean;
  /** null when there is no monthly cap (Plus). */
  limit: number | null;
  remaining: number | null;
}

export function evaluateQuota(
  counts: UsageCounts,
  isPlus: boolean,
  config: QuotaConfig,
): QuotaDecision {
  if (isPlus) {
    return { allowed: true, limit: null, remaining: null };
  }
  const limit = config.freeMonthlyAnalyses;
  const remaining = Math.max(0, limit - counts.monthUsed);
  return { allowed: remaining > 0, limit, remaining };
}

/**
 * Anti-abuse limits. Applied to every account regardless of subscription.
 * Throws with a real Retry-After rather than returning a bare 429.
 */
export function assertWithinRateLimits(counts: UsageCounts, config: QuotaConfig): void {
  if (counts.inFlight >= config.maxConcurrentAnalyses) {
    throw new ApiError(
      'rate_limited',
      `${counts.inFlight} analyses already in flight`,
      5,
    );
  }
  if (counts.lastMinuteUsed >= config.analysesPerMinute) {
    throw new ApiError('rate_limited', 'per-minute limit reached', 60);
  }
  if (counts.lastDayUsed >= config.analysesPerDay) {
    throw new ApiError('rate_limited', 'daily limit reached', 3600);
  }
}

/**
 * The calendar-month window for a user, in their own timezone.
 *
 * "5 per calendar month" has to mean the user's calendar, not UTC's — otherwise
 * someone in Los Angeles loses most of the last day of every month. Returns
 * UTC instants bounding their local month.
 */
export function monthWindow(now: Date, timezone: string): { start: Date; end: Date } {
  const parts = localParts(now, timezone);

  const startUtc = utcForLocalMidnight(parts.year, parts.month, 1, timezone);
  const nextMonth = parts.month === 12 ? 1 : parts.month + 1;
  const nextYear = parts.month === 12 ? parts.year + 1 : parts.year;
  const endUtc = utcForLocalMidnight(nextYear, nextMonth, 1, timezone);

  return { start: startUtc, end: endUtc };
}

function localParts(date: Date, timezone: string): { year: number; month: number; day: number } {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  const parts = Object.fromEntries(
    formatter.formatToParts(date).map((part) => [part.type, part.value]),
  );
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
  };
}

/**
 * The UTC instant of local midnight on a given date in a zone.
 *
 * Done by measuring the zone's offset at an approximate instant and correcting
 * once, which is enough for month boundaries: a DST transition moves the wall
 * clock by an hour, never across a month start.
 */
function utcForLocalMidnight(year: number, month: number, day: number, timezone: string): Date {
  const guess = Date.UTC(year, month - 1, day, 0, 0, 0);
  const offset = zoneOffsetMs(new Date(guess), timezone);
  const corrected = guess - offset;
  // One correction pass, in case the first guess landed on the other side of a
  // transition and reported a different offset.
  const offset2 = zoneOffsetMs(new Date(corrected), timezone);
  return new Date(guess - offset2);
}

function zoneOffsetMs(date: Date, timezone: string): number {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const parts = Object.fromEntries(
    formatter.formatToParts(date).map((part) => [part.type, part.value]),
  );
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour === '24' ? '00' : parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return asUtc - date.getTime();
}

/** Validate a timezone, falling back to UTC rather than throwing on bad input. */
export function safeTimezone(timezone: string | null | undefined): string {
  if (!timezone) return 'UTC';
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: timezone });
    return timezone;
  } catch {
    return 'UTC';
  }
}
