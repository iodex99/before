/**
 * App Store Server API client.
 *
 * The JWT is signed with a real P-256 key generated in the test and verified
 * with the matching public key, so "the token is valid" is demonstrated rather
 * than assumed. HTTP is stubbed; Apple is not called.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { generateKeyPairSync, createVerify, createPublicKey } from 'node:crypto';

import {
  APPLE_STATUS,
  AppStoreClient,
  AppStoreError,
  createAppStoreToken,
  grantsEntitlement,
  statusFromApple,
} from '../shared/apple/appstore.ts';
import { base64ToBytes } from '../shared/apple/der.ts';

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(
  readFileSync(join(here, '../shared/fixtures/apple-chain.json'), 'utf8'),
) as {
  validAt: string;
  trustedRootDer: string;
  tokens: Record<string, string>;
  payloads: Record<string, Record<string, unknown>>;
};

const trustedRoot = base64ToBytes(fixtures.trustedRootDer);
const now = new Date(fixtures.validAt);

/** A real ES256 key pair, so the JWT can actually be verified. */
const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'P-256',
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

const credentials = {
  issuerId: '57246542-96fe-1a63-e053-0824d011072a',
  keyId: 'ABC123DEFG',
  privateKeyPem: privateKey,
  bundleId: 'com.yourcompany.before',
};

// ---------------------------------------------------------------------------
// JWT
// ---------------------------------------------------------------------------

test('the API token is a genuine ES256 JWT that verifies under the key', async () => {
  const token = await createAppStoreToken(credentials, now);
  const [headerSegment, payloadSegment, signatureSegment] = token.split('.');

  const header = JSON.parse(Buffer.from(headerSegment, 'base64url').toString());
  assert.equal(header.alg, 'ES256');
  assert.equal(header.kid, credentials.keyId);
  assert.equal(header.typ, 'JWT');

  const payload = JSON.parse(Buffer.from(payloadSegment, 'base64url').toString());
  assert.equal(payload.iss, credentials.issuerId);
  assert.equal(payload.aud, 'appstoreconnect-v1');
  assert.equal(payload.bid, credentials.bundleId);

  const verifier = createVerify('SHA256');
  verifier.update(`${headerSegment}.${payloadSegment}`);
  verifier.end();

  const valid = verifier.verify(
    { key: createPublicKey(publicKey), dsaEncoding: 'ieee-p1363' },
    Buffer.from(signatureSegment, 'base64url'),
  );
  assert.ok(valid, 'the signed JWT must verify under the matching public key');
});

test('the token expires well inside the hour Apple allows', async () => {
  const token = await createAppStoreToken(credentials, now);
  const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());

  const lifetime = payload.exp - payload.iat;
  assert.ok(lifetime > 0 && lifetime <= 3600, `lifetime was ${lifetime}s`);
  assert.equal(payload.iat, Math.floor(now.getTime() / 1000));
});

test('an unusable private key fails with a readable message', async () => {
  await assert.rejects(
    () => createAppStoreToken({ ...credentials, privateKeyPem: 'not a key' }),
    (error: unknown) => error instanceof AppStoreError && /APPLE_PRIVATE_KEY/.test(error.message),
  );
});

// ---------------------------------------------------------------------------
// Status mapping
// ---------------------------------------------------------------------------

test("Apple's status codes map to our vocabulary", () => {
  assert.equal(statusFromApple(APPLE_STATUS.ACTIVE), 'active');
  assert.equal(statusFromApple(APPLE_STATUS.EXPIRED), 'expired');
  assert.equal(statusFromApple(APPLE_STATUS.IN_BILLING_RETRY), 'in_billing_retry');
  assert.equal(statusFromApple(APPLE_STATUS.IN_GRACE_PERIOD), 'in_grace_period');
  assert.equal(statusFromApple(APPLE_STATUS.REVOKED), 'revoked');
});

test('an unknown status code never reads as entitlement', () => {
  // A code Apple adds later must fail closed.
  for (const code of [0, 6, 99, undefined]) {
    const status = statusFromApple(code);
    assert.equal(grantsEntitlement(status, null, now), false, `code ${code} granted access`);
  }
});

test('grace period and billing retry keep access; revoked and refunded do not', () => {
  const future = new Date(now.getTime() + 86_400_000);
  assert.equal(grantsEntitlement('active', future, now), true);
  assert.equal(grantsEntitlement('in_grace_period', future, now), true);
  assert.equal(grantsEntitlement('in_billing_retry', future, now), true);
  assert.equal(grantsEntitlement('expired', future, now), false);
  assert.equal(grantsEntitlement('revoked', future, now), false);
  assert.equal(grantsEntitlement('refunded', future, now), false);
});

test('an active status with a past expiry does not grant access', () => {
  const past = new Date(now.getTime() - 86_400_000);
  assert.equal(grantsEntitlement('active', past, now), false);
});

// ---------------------------------------------------------------------------
// Subscription status lookup
// ---------------------------------------------------------------------------

function clientWith(respond: (url: string) => Response) {
  return new AppStoreClient({
    credentials,
    rootCertificate: trustedRoot,
    environment: 'production',
    now: () => now,
    fetchImpl: (async (input: string | URL | Request) => respond(String(input))) as typeof fetch,
  });
}

function statusBody(status: number) {
  return JSON.stringify({
    environment: 'Production',
    bundleId: 'com.yourcompany.before',
    data: [
      {
        subscriptionGroupIdentifier: 'before_plus',
        lastTransactions: [
          {
            originalTransactionId: '2000000400000001',
            status,
            signedTransactionInfo: fixtures.tokens.transaction,
          },
        ],
      },
    ],
  });
}

test('a subscription status is fetched and its signed transaction verified', async () => {
  const client = clientWith(() => new Response(statusBody(APPLE_STATUS.ACTIVE), { status: 200 }));
  const snapshot = await client.subscriptionStatus('2000000400000001');

  assert.ok(snapshot);
  assert.equal(snapshot.originalTransactionId, '2000000400000001');
  assert.equal(snapshot.productId, 'before.plus.yearly');
  assert.equal(snapshot.status, 'active');
  assert.equal(snapshot.environment, 'production');
  assert.equal(snapshot.appAccountToken, '2b0b8c5e-9b8a-4c6f-9d1e-7a3f5c2d1e4b');
});

test('the request carries a bearer token and targets the right host', async () => {
  let seenUrl = '';
  const client = new AppStoreClient({
    credentials,
    rootCertificate: trustedRoot,
    environment: 'sandbox',
    now: () => now,
    fetchImpl: (async (input: string | URL | Request, init?: RequestInit) => {
      seenUrl = String(input);
      const authorization = new Headers(init?.headers).get('authorization') ?? '';
      assert.match(authorization, /^Bearer ey/, 'must send a signed JWT');
      return new Response(statusBody(APPLE_STATUS.ACTIVE), { status: 200 });
    }) as typeof fetch,
  });

  await client.subscriptionStatus('2000000400000001');
  assert.match(seenUrl, /api\.storekit-sandbox\.itunes\.apple\.com/);
  assert.match(seenUrl, /\/inApps\/v1\/subscriptions\/2000000400000001$/);
});

test('a status Apple does not recognise returns null, not an assumption', async () => {
  const client = clientWith(() => new Response('', { status: 404 }));
  assert.equal(await client.subscriptionStatus('2000000400000099'), null);
});

test('a transaction for another app is refused even though Apple sent it', async () => {
  const body = JSON.stringify({
    data: [
      {
        lastTransactions: [
          {
            originalTransactionId: '2000000400000001',
            status: APPLE_STATUS.ACTIVE,
            signedTransactionInfo: fixtures.tokens.foreignBundleTransaction,
          },
        ],
      },
    ],
  });

  const client = clientWith(() => new Response(body, { status: 200 }));
  await assert.rejects(() => client.subscriptionStatus('2000000400000001'), AppStoreError);
});

test('a tampered response is refused despite arriving over the real transport', async () => {
  const body = JSON.stringify({
    data: [
      {
        lastTransactions: [
          {
            originalTransactionId: '2000000400000001',
            status: APPLE_STATUS.ACTIVE,
            signedTransactionInfo: fixtures.tokens.corruptSignature,
          },
        ],
      },
    ],
  });

  const client = clientWith(() => new Response(body, { status: 200 }));
  await assert.rejects(() => client.subscriptionStatus('2000000400000001'));
});

test('server errors are retryable, client errors are not', async () => {
  const serverError = clientWith(() => new Response('boom', { status: 503 }));
  await assert.rejects(
    () => serverError.subscriptionStatus('2000000400000001'),
    (error: unknown) => error instanceof AppStoreError && error.retryable,
  );

  const badRequest = clientWith(() => new Response('nope', { status: 400 }));
  await assert.rejects(
    () => badRequest.subscriptionStatus('2000000400000001'),
    (error: unknown) => error instanceof AppStoreError && !error.retryable,
  );
});

test('an unreachable App Store surfaces as a retryable error', async () => {
  const client = new AppStoreClient({
    credentials,
    rootCertificate: trustedRoot,
    environment: 'production',
    now: () => now,
    fetchImpl: (async () => {
      throw new TypeError('connection refused');
    }) as typeof fetch,
  });

  await assert.rejects(
    () => client.subscriptionStatus('2000000400000001'),
    (error: unknown) => error instanceof AppStoreError && error.retryable,
  );
});
