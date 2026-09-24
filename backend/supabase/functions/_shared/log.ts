/**
 * BEFORE — structured logging.
 *
 * The allow-list is the point. `log.info(event, fields)` only emits the fields
 * named in LoggableFields, so a well-meaning `{ ...request }` cannot put an
 * image, a bearer token, or someone's purchase history into the log stream
 * (spec §74).
 */

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

/** The complete set of things any BEFORE log line may contain. */
export interface LoggableFields {
  requestId?: string;
  /** Internal UUID. Never an email, never an Apple identity token. */
  userId?: string;
  endpoint?: string;
  method?: string;
  status?: number;
  latencyMs?: number;
  provider?: string;
  model?: string;
  promptVersion?: string;
  scoreVersion?: string;
  inputTokens?: number;
  outputTokens?: number;
  estimatedCostUsd?: number;
  errorKind?: string;
  errorCode?: string;
  /** Counts only, never the offending text. */
  safetyFindings?: number;
  schemaWarnings?: number;
  retried?: boolean;
  verdict?: string;
  score?: number;
  inputType?: string;
  cacheHit?: boolean;
  isPlus?: boolean;
  quotaRemaining?: number | null;
  durationBucket?: string;
  /** Short, developer-written note. Never interpolated user or model content. */
  note?: string;
}

const ALLOWED_KEYS = new Set<keyof LoggableFields>([
  'requestId', 'userId', 'endpoint', 'method', 'status', 'latencyMs',
  'provider', 'model', 'promptVersion', 'scoreVersion',
  'inputTokens', 'outputTokens', 'estimatedCostUsd',
  'errorKind', 'errorCode', 'safetyFindings', 'schemaWarnings', 'retried',
  'verdict', 'score', 'inputType', 'cacheHit', 'isPlus', 'quotaRemaining',
  'durationBucket', 'note',
]);

function sanitise(fields: LoggableFields): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(fields)) {
    if (!ALLOWED_KEYS.has(key as keyof LoggableFields)) continue;
    if (value === undefined) continue;
    out[key] = value;
  }
  return out;
}

export class Logger {
  constructor(private readonly base: LoggableFields = {}) {}

  child(fields: LoggableFields): Logger {
    return new Logger({ ...this.base, ...fields });
  }

  private emit(level: LogLevel, event: string, fields: LoggableFields): void {
    const line = JSON.stringify({
      level,
      event,
      at: new Date().toISOString(),
      ...sanitise({ ...this.base, ...fields }),
    });
    if (level === 'error') console.error(line);
    else if (level === 'warn') console.warn(line);
    else console.log(line);
  }

  debug(event: string, fields: LoggableFields = {}) { this.emit('debug', event, fields); }
  info(event: string, fields: LoggableFields = {}) { this.emit('info', event, fields); }
  warn(event: string, fields: LoggableFields = {}) { this.emit('warn', event, fields); }
  error(event: string, fields: LoggableFields = {}) { this.emit('error', event, fields); }
}

/** Latency as a coarse bucket, which is what dashboards actually want. */
export function durationBucket(ms: number): string {
  if (ms < 1000) return '<1s';
  if (ms < 3000) return '1-3s';
  if (ms < 6000) return '3-6s';
  if (ms < 12000) return '6-12s';
  if (ms < 25000) return '12-25s';
  return '>25s';
}
