/**
 * Configuration loading. The production-safety guards here are the reason this
 * file exists — a mocked verdict reaching a paying user is worse than an outage,
 * because it looks real.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { ConfigError, loadConfig } from '../shared/config.ts';

const base = {
  SUPABASE_URL: 'https://project.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'service-role-key',
  ANTHROPIC_API_KEY: 'test-key',
};

test('a minimal valid environment loads with sensible defaults', () => {
  const config = loadConfig(base);
  assert.equal(config.appEnv, 'development');
  assert.equal(config.ai.provider, 'anthropic');
  assert.equal(config.ai.model, 'claude-sonnet-5');
  assert.equal(config.ai.mockMode, false);
  assert.equal(config.ai.effort, 'medium');
  assert.equal(config.quota.freeMonthlyAnalyses, 5);
});

test('AI_MODEL overrides the per-provider default', () => {
  assert.equal(loadConfig({ ...base, AI_MODEL: 'claude-opus-5' }).ai.model, 'claude-opus-5');
});

test('mock mode in production is refused', () => {
  assert.throws(
    () => loadConfig({ ...base, APP_ENV: 'production', AI_MOCK_MODE: 'true' }),
    (error: unknown) =>
      error instanceof ConfigError && /AI_MOCK_MODE must not be enabled/.test(error.message),
  );
});

test('the mock provider in production is refused', () => {
  assert.throws(
    () => loadConfig({ ...base, APP_ENV: 'production', AI_PROVIDER: 'mock' }),
    ConfigError,
  );
});

test('mock mode outside production is allowed and needs no API key', () => {
  const config = loadConfig({
    SUPABASE_URL: base.SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY: base.SUPABASE_SERVICE_ROLE_KEY,
    APP_ENV: 'development',
    AI_MOCK_MODE: 'true',
  });
  assert.equal(config.ai.mockMode, true);
  assert.equal(config.ai.apiKey, '');
});

test('a real provider without its API key fails at boot, not at request time', () => {
  assert.throws(
    () => loadConfig({ SUPABASE_URL: base.SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY: 'k' }),
    (error: unknown) => error instanceof ConfigError && /ANTHROPIC_API_KEY/.test(error.message),
  );
});

test('each provider requires its own key', () => {
  assert.throws(
    () => loadConfig({ ...base, AI_PROVIDER: 'openai' }),
    (error: unknown) => error instanceof ConfigError && /OPENAI_API_KEY/.test(error.message),
  );
  assert.equal(
    loadConfig({ ...base, AI_PROVIDER: 'openai', OPENAI_API_KEY: 'k' }).ai.provider,
    'openai',
  );
});

test('missing Supabase settings fail loudly', () => {
  assert.throws(() => loadConfig({}), ConfigError);
  assert.throws(() => loadConfig({ SUPABASE_URL: 'x' }), ConfigError);
});

test('unknown enum values are rejected rather than silently defaulted', () => {
  assert.throws(() => loadConfig({ ...base, APP_ENV: 'prod' }), ConfigError);
  assert.throws(() => loadConfig({ ...base, AI_PROVIDER: 'llama' }), ConfigError);
  assert.throws(() => loadConfig({ ...base, AI_EFFORT: 'turbo' }), ConfigError);
});

test('malformed numbers and booleans are rejected', () => {
  assert.throws(() => loadConfig({ ...base, FREE_MONTHLY_ANALYSES: 'five' }), ConfigError);
  assert.throws(() => loadConfig({ ...base, FREE_MONTHLY_ANALYSES: '0' }), ConfigError);
  assert.throws(() => loadConfig({ ...base, FREE_MONTHLY_ANALYSES: '-3' }), ConfigError);
  assert.throws(() => loadConfig({ ...base, AI_MOCK_MODE: 'yes' }), ConfigError);
});

test('boolean settings accept true/false/1/0', () => {
  for (const [raw, expected] of [
    ['true', true],
    ['1', true],
    ['false', false],
    ['0', false],
  ] as const) {
    assert.equal(loadConfig({ ...base, ANALYTICS_ENABLED: raw }).analyticsEnabled, expected);
  }
});

test('quota and rate limits are configurable', () => {
  const config = loadConfig({
    ...base,
    FREE_MONTHLY_ANALYSES: '3',
    RATE_LIMIT_ANALYSES_PER_MINUTE: '10',
    MAX_UPLOAD_BYTES: '1048576',
  });
  assert.equal(config.quota.freeMonthlyAnalyses, 3);
  assert.equal(config.quota.analysesPerMinute, 10);
  assert.equal(config.quota.maxUploadBytes, 1_048_576);
});

// ---------------------------------------------------------------------------
// Apple
// ---------------------------------------------------------------------------

/** A stand-in for Apple Root CA G3: long enough to pass the sanity check. */
const fakeRootBase64 = Buffer.alloc(400, 7).toString('base64');

test('production with a real provider, key and Apple root loads', () => {
  const config = loadConfig({
    ...base,
    APP_ENV: 'production',
    APPLE_ROOT_CA_G3_BASE64: fakeRootBase64,
  });
  assert.equal(config.appEnv, 'production');
  assert.equal(config.ai.mockMode, false);
  assert.ok(config.apple.rootCertificate);
  assert.equal(config.apple.allowSandbox, false, 'sandbox must not grant production entitlement');
});

test('production refuses to boot without the Apple root certificate', () => {
  // Without it, subscription-sync would be back to trusting the client — the
  // exact thing the verification work exists to remove.
  assert.throws(
    () => loadConfig({ ...base, APP_ENV: 'production' }),
    (error: unknown) =>
      error instanceof ConfigError && /APPLE_ROOT_CA_G3_BASE64 is required/.test(error.message),
  );
});

test('development runs without the Apple root, and allows sandbox', () => {
  const config = loadConfig(base);
  assert.equal(config.apple.rootCertificate, null);
  assert.equal(config.apple.allowSandbox, true);
});

test('a malformed Apple root certificate is rejected at boot', () => {
  assert.throws(
    () => loadConfig({ ...base, APPLE_ROOT_CA_G3_BASE64: 'AAAA' }),
    (error: unknown) => error instanceof ConfigError && /not valid base64 DER/.test(error.message),
  );
});

test('App Store Server API credentials must be set together or not at all', () => {
  assert.throws(
    () => loadConfig({ ...base, APPLE_ISSUER_ID: 'issuer' }),
    (error: unknown) => error instanceof ConfigError && /must be set together/.test(error.message),
  );

  const partial = loadConfig(base);
  assert.equal(partial.apple.serverApi, null, 'absent credentials simply disable reconciliation');

  const full = loadConfig({
    ...base,
    APPLE_ISSUER_ID: 'issuer',
    APPLE_KEY_ID: 'key',
    APPLE_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\\nAAAA\\n-----END PRIVATE KEY-----',
  });
  assert.ok(full.apple.serverApi);
  assert.equal(full.apple.serverApi.issuerId, 'issuer');
  assert.ok(
    full.apple.serverApi.privateKeyPem.includes('\n'),
    'escaped newlines from a secrets manager must be restored, or the PEM will not parse',
  );
});

test('the bundle id is configurable', () => {
  assert.equal(loadConfig(base).apple.bundleId, 'com.yourcompany.before');
  assert.equal(
    loadConfig({ ...base, APPLE_BUNDLE_ID: 'com.acme.before' }).apple.bundleId,
    'com.acme.before',
  );
});
