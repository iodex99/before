/**
 * BEFORE — configuration.
 *
 * Runtime-neutral: takes a plain env record rather than reading Deno.env or
 * process.env itself, so it is testable and so shared code never depends on a
 * particular host. Each edge function hands it `Deno.env.toObject()`.
 *
 * Invalid configuration throws at boot, not on the first user request.
 */

import { AI_PROVIDERS, type AiProviderName } from './ai/provider.ts';

export const APP_ENVS = ['development', 'staging', 'production'] as const;
export type AppEnv = (typeof APP_ENVS)[number];

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export interface QuotaConfig {
  freeMonthlyAnalyses: number;
  analysesPerMinute: number;
  analysesPerDay: number;
  /** Fair-use ceiling for Plus. See evaluateQuota() for why it exists. */
  plusMonthlyAnalyses: number;
  metadataPerMinute: number;
  maxUploadBytes: number;
  maxConcurrentAnalyses: number;
  /** Free wardrobe cap. Plus removes it (spec §35). */
  freeWardrobeItems: number;
}

export interface AiConfig {
  provider: AiProviderName;
  model: string;
  apiKey: string;
  mockMode: boolean;
  maxOutputTokens: number;
  timeoutMs: number;
  effort: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  refusalFallbacks: boolean;
}

export interface AppleConfig {
  /**
   * DER bytes of Apple Root CA G3, decoded from APPLE_ROOT_CA_G3_BASE64.
   *
   * Null only outside production. Without it nothing can be verified, so
   * production refuses to boot rather than silently accepting client claims.
   */
  rootCertificate: Uint8Array | null;
  bundleId: string;
  /** Present only when the App Store Server API credentials are configured. */
  serverApi: {
    issuerId: string;
    keyId: string;
    privateKeyPem: string;
  } | null;
  /** True when a sandbox transaction may grant entitlement. */
  allowSandbox: boolean;
}

export interface AppConfig {
  appEnv: AppEnv;
  supabaseUrl: string;
  serviceRoleKey: string;
  ai: AiConfig;
  quota: QuotaConfig;
  apple: AppleConfig;
  analyticsEnabled: boolean;
  termsUrl: string;
  privacyUrl: string;
}

type Env = Record<string, string | undefined>;

function required(env: Env, key: string): string {
  const value = env[key]?.trim();
  if (!value) throw new ConfigError(`${key} is required but not set`);
  return value;
}

function optional(env: Env, key: string, fallback: string): string {
  const value = env[key]?.trim();
  return value ? value : fallback;
}

function integer(env: Env, key: string, fallback: number): number {
  const raw = env[key]?.trim();
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new ConfigError(`${key} must be a positive integer, got "${raw}"`);
  }
  return parsed;
}

function boolean(env: Env, key: string, fallback: boolean): boolean {
  const raw = env[key]?.trim().toLowerCase();
  if (raw === undefined || raw === '') return fallback;
  if (raw === 'true' || raw === '1') return true;
  if (raw === 'false' || raw === '0') return false;
  throw new ConfigError(`${key} must be true or false, got "${raw}"`);
}

/** The env var holding the key for each provider. */
const API_KEY_VAR: Record<Exclude<AiProviderName, 'mock'>, string> = {
  anthropic: 'ANTHROPIC_API_KEY',
  openai: 'OPENAI_API_KEY',
  gemini: 'GEMINI_API_KEY',
};

/**
 * Default model per provider. Kept here rather than hard-coded at the call site
 * so AI_MODEL stays the single override point (spec §16: never pin a model name
 * that will age out of the codebase).
 *
 * Anthropic default is Sonnet rather than Opus: this is a high-volume consumer
 * path where the analysis is a bounded, well-structured task, and Sonnet costs
 * roughly 40% as much per call. Set AI_MODEL=claude-opus-5 to trade cost for
 * depth. See docs/AI.md.
 */
const DEFAULT_MODEL: Record<Exclude<AiProviderName, 'mock'>, string> = {
  anthropic: 'claude-sonnet-5',
  openai: 'gpt-5',
  gemini: 'gemini-2.5-pro',
};

const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;

export function loadConfig(env: Env): AppConfig {
  const appEnvRaw = optional(env, 'APP_ENV', 'development');
  if (!(APP_ENVS as readonly string[]).includes(appEnvRaw)) {
    throw new ConfigError(`APP_ENV must be one of ${APP_ENVS.join(', ')}, got "${appEnvRaw}"`);
  }
  const appEnv = appEnvRaw as AppEnv;

  const providerRaw = optional(env, 'AI_PROVIDER', 'anthropic');
  if (!(AI_PROVIDERS as readonly string[]).includes(providerRaw)) {
    throw new ConfigError(`AI_PROVIDER must be one of ${AI_PROVIDERS.join(', ')}, got "${providerRaw}"`);
  }
  const provider = providerRaw as AiProviderName;

  const mockMode = boolean(env, 'AI_MOCK_MODE', false);

  // The single most important guard in this file. A mock verdict reaching a
  // paying user is worse than an outage: it looks real and it is fabricated.
  if (mockMode && appEnv === 'production') {
    throw new ConfigError('AI_MOCK_MODE must not be enabled when APP_ENV=production');
  }
  if (provider === 'mock' && appEnv === 'production') {
    throw new ConfigError('AI_PROVIDER=mock must not be used when APP_ENV=production');
  }

  const usingMock = mockMode || provider === 'mock';
  const realProvider = provider === 'mock' ? 'anthropic' : provider;

  const effortRaw = optional(env, 'AI_EFFORT', 'medium');
  if (!(EFFORTS as readonly string[]).includes(effortRaw)) {
    throw new ConfigError(`AI_EFFORT must be one of ${EFFORTS.join(', ')}, got "${effortRaw}"`);
  }

  return {
    appEnv,
    supabaseUrl: required(env, 'SUPABASE_URL'),
    serviceRoleKey: required(env, 'SUPABASE_SERVICE_ROLE_KEY'),
    ai: {
      provider,
      model: optional(env, 'AI_MODEL', DEFAULT_MODEL[realProvider]),
      // A real key is not needed when everything is mocked, which is what makes
      // `npm run test:backend` runnable on a laptop with no credentials.
      apiKey: usingMock ? '' : required(env, API_KEY_VAR[realProvider]),
      mockMode: usingMock,
      maxOutputTokens: integer(env, 'AI_MAX_OUTPUT_TOKENS', 8000),
      timeoutMs: integer(env, 'AI_TIMEOUT_MS', 45_000),
      effort: effortRaw as AiConfig['effort'],
      refusalFallbacks: boolean(env, 'AI_REFUSAL_FALLBACKS', true),
    },
    apple: loadAppleConfig(env, appEnv),
    quota: {
      freeMonthlyAnalyses: integer(env, 'FREE_MONTHLY_ANALYSES', 5),
      analysesPerMinute: integer(env, 'RATE_LIMIT_ANALYSES_PER_MINUTE', 6),
      // Burst protection within a day. Lowered from 120 once the monthly
      // ceiling landed: 120/day was the thing that permitted 3,600/month.
      analysesPerDay: integer(env, 'RATE_LIMIT_ANALYSES_PER_DAY', 40),
      // ~8x typical use, and comfortably below the ~130/month where a yearly
      // subscriber stops paying for themselves.
      plusMonthlyAnalyses: integer(env, 'PLUS_MONTHLY_ANALYSES', 100),
      metadataPerMinute: integer(env, 'RATE_LIMIT_METADATA_PER_MINUTE', 20),
      maxUploadBytes: integer(env, 'MAX_UPLOAD_BYTES', 6 * 1024 * 1024),
      maxConcurrentAnalyses: integer(env, 'MAX_CONCURRENT_ANALYSES', 2),
      // Deliberately generous: the wardrobe is what makes a verdict personal,
      // and gating it hard would gate result quality, which §35 forbids.
      freeWardrobeItems: integer(env, 'FREE_WARDROBE_ITEMS', 25),
    },
    analyticsEnabled: boolean(env, 'ANALYTICS_ENABLED', false),
    termsUrl: optional(env, 'TERMS_URL', ''),
    privacyUrl: optional(env, 'PRIVACY_URL', ''),
  };
}

// ---------------------------------------------------------------------------
// Apple
// ---------------------------------------------------------------------------

function decodeBase64(value: string, key: string): Uint8Array {
  try {
    const binary = atob(value.replace(/\s+/g, ''));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    if (bytes.length < 100) throw new Error('too short to be a certificate');
    return bytes;
  } catch (error) {
    throw new ConfigError(
      `${key} is not valid base64 DER: ${error instanceof Error ? error.message : 'unknown'}`,
    );
  }
}

function loadAppleConfig(env: Env, appEnv: AppEnv): AppleConfig {
  const rootRaw = env.APPLE_ROOT_CA_G3_BASE64?.trim();

  // Without the root certificate nothing Apple sends can be verified, and
  // subscription-sync would be back to trusting whatever the client claimed.
  // That is the exact failure this code exists to remove, so production will
  // not start without it.
  if (!rootRaw && appEnv === 'production') {
    throw new ConfigError(
      'APPLE_ROOT_CA_G3_BASE64 is required in production — see docs/SETUP.md for where to get it',
    );
  }

  const issuerId = env.APPLE_ISSUER_ID?.trim();
  const keyId = env.APPLE_KEY_ID?.trim();
  // Secrets managers commonly flatten newlines; restore them or the PEM will
  // not parse.
  const privateKeyPem = env.APPLE_PRIVATE_KEY?.trim().replace(/\\n/g, '\n');

  const credentialCount = [issuerId, keyId, privateKeyPem].filter(Boolean).length;
  if (credentialCount > 0 && credentialCount < 3) {
    throw new ConfigError(
      'APPLE_ISSUER_ID, APPLE_KEY_ID and APPLE_PRIVATE_KEY must be set together or not at all',
    );
  }

  return {
    rootCertificate: rootRaw ? decodeBase64(rootRaw, 'APPLE_ROOT_CA_G3_BASE64') : null,
    bundleId: optional(env, 'APPLE_BUNDLE_ID', 'com.yourcompany.before'),
    serverApi:
      credentialCount === 3
        ? { issuerId: issuerId as string, keyId: keyId as string, privateKeyPem: privateKeyPem as string }
        : null,
    // A sandbox transaction must never grant production entitlement.
    allowSandbox: appEnv !== 'production',
  };
}
