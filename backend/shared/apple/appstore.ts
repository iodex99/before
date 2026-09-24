/**
 * BEFORE — App Store Server API client.
 *
 * Asks Apple what the subscription actually is, rather than believing what the
 * client said it is. This is the half that makes `subscriptions` an
 * authoritative record instead of a cache of claims.
 *
 * Everything Apple returns is itself a signed JWS and is verified before use —
 * being reached over TLS from Apple's own host is not a substitute for checking
 * the signature.
 */

import { bytesToBase64Url, pemToBytes } from './der.ts';
import { verifyAppleSignedPayload, type AppleRenewalInfoPayload, type AppleTransactionPayload } from './jws.ts';

export class AppStoreError extends Error {
  readonly status: number | null;
  readonly retryable: boolean;

  constructor(message: string, status: number | null = null) {
    super(message);
    this.name = 'AppStoreError';
    this.status = status;
    this.retryable = status === null || status === 429 || status >= 500;
  }
}

export const APP_STORE_HOSTS = {
  production: 'https://api.storekit.itunes.apple.com',
  sandbox: 'https://api.storekit-sandbox.itunes.apple.com',
} as const;

/** Apple's subscription status codes, from GET /inApps/v1/subscriptions. */
export const APPLE_STATUS = {
  ACTIVE: 1,
  EXPIRED: 2,
  IN_BILLING_RETRY: 3,
  IN_GRACE_PERIOD: 4,
  REVOKED: 5,
} as const;

/** Our own vocabulary, matching the `subscription_status` enum in Postgres. */
export type SubscriptionStatus =
  | 'active'
  | 'expired'
  | 'in_grace_period'
  | 'in_billing_retry'
  | 'revoked'
  | 'refunded';

export function statusFromApple(code: number | undefined): SubscriptionStatus {
  switch (code) {
    case APPLE_STATUS.ACTIVE: return 'active';
    case APPLE_STATUS.IN_BILLING_RETRY: return 'in_billing_retry';
    case APPLE_STATUS.IN_GRACE_PERIOD: return 'in_grace_period';
    case APPLE_STATUS.REVOKED: return 'revoked';
    case APPLE_STATUS.EXPIRED: return 'expired';
    // An unknown code must not be read as entitlement.
    default: return 'expired';
  }
}

export interface AppStoreCredentials {
  issuerId: string;
  keyId: string;
  /** PEM contents of the .p8 downloaded from App Store Connect. */
  privateKeyPem: string;
  bundleId: string;
}

export interface AppStoreClientOptions {
  credentials: AppStoreCredentials;
  /** DER of Apple Root CA G3, for verifying what comes back. */
  rootCertificate: Uint8Array;
  environment: 'production' | 'sandbox';
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
  now?: () => Date;
}

// ---------------------------------------------------------------------------
// Request authentication
// ---------------------------------------------------------------------------

/**
 * Sign the ES256 JWT the App Store Server API expects.
 *
 * Apple caps the lifetime at one hour. We use twenty minutes: short enough that
 * a leaked token is nearly worthless, long enough that clock skew is a non-issue.
 */
export async function createAppStoreToken(
  credentials: AppStoreCredentials,
  now: Date = new Date(),
): Promise<string> {
  const issuedAt = Math.floor(now.getTime() / 1000);

  const header = { alg: 'ES256', kid: credentials.keyId, typ: 'JWT' };
  const payload = {
    iss: credentials.issuerId,
    iat: issuedAt,
    exp: issuedAt + 20 * 60,
    aud: 'appstoreconnect-v1',
    bid: credentials.bundleId,
  };

  const encoder = new TextEncoder();
  const segments = [
    bytesToBase64Url(encoder.encode(JSON.stringify(header))),
    bytesToBase64Url(encoder.encode(JSON.stringify(payload))),
  ].join('.');

  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      'pkcs8',
      pemToBytes(credentials.privateKeyPem) as BufferSource,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign'],
    );
  } catch {
    throw new AppStoreError('APPLE_PRIVATE_KEY is not a usable PKCS#8 P-256 key');
  }

  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    encoder.encode(segments) as BufferSource,
  );

  return `${segments}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

interface SubscriptionStatusResponse {
  environment?: string;
  bundleId?: string;
  data?: Array<{
    subscriptionGroupIdentifier?: string;
    lastTransactions?: Array<{
      originalTransactionId?: string;
      status?: number;
      signedTransactionInfo?: string;
      signedRenewalInfo?: string;
    }>;
  }>;
}

export interface SubscriptionSnapshot {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  status: SubscriptionStatus;
  purchaseDate: Date;
  expirationDate: Date | null;
  revocationDate: Date | null;
  autoRenewStatus: boolean | null;
  environment: 'production' | 'sandbox';
  appAccountToken: string | null;
}

export class AppStoreClient {
  private readonly options: AppStoreClientOptions;

  constructor(options: AppStoreClientOptions) {
    this.options = options;
  }

  private get host(): string {
    return APP_STORE_HOSTS[this.options.environment];
  }

  /**
   * The current state of a subscription, straight from Apple.
   *
   * Returns null when Apple has no record of it — which is a legitimate answer
   * for a transaction id the client made up, and must not be mistaken for
   * "still active".
   */
  async subscriptionStatus(originalTransactionId: string): Promise<SubscriptionSnapshot | null> {
    const now = this.options.now?.() ?? new Date();
    const token = await createAppStoreToken(this.options.credentials, now);
    const doFetch = this.options.fetchImpl ?? fetch;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.options.timeoutMs ?? 10_000);

    let response: Response;
    try {
      response = await doFetch(
        `${this.host}/inApps/v1/subscriptions/${encodeURIComponent(originalTransactionId)}`,
        {
          method: 'GET',
          headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
          signal: controller.signal,
        },
      );
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        throw new AppStoreError('App Store Server API timed out');
      }
      throw new AppStoreError('could not reach the App Store Server API');
    } finally {
      clearTimeout(timer);
    }

    // Apple returns 404 for a transaction it does not know about.
    if (response.status === 404) return null;

    if (!response.ok) {
      const detail = (await response.text().catch(() => '')).slice(0, 200);
      throw new AppStoreError(`App Store Server API returned ${response.status}: ${detail}`, response.status);
    }

    const body = (await response.json()) as SubscriptionStatusResponse;

    const entry = body.data
      ?.flatMap((group) => group.lastTransactions ?? [])
      .find((candidate) => candidate.originalTransactionId === originalTransactionId)
      ?? body.data?.flatMap((group) => group.lastTransactions ?? [])[0];

    if (!entry?.signedTransactionInfo) return null;

    // Verify what Apple sent. TLS says it came from Apple; the signature says
    // Apple meant it.
    const transaction = await verifyAppleSignedPayload<AppleTransactionPayload>(
      entry.signedTransactionInfo,
      { rootCertificate: this.options.rootCertificate, now },
    );

    if (transaction.bundleId !== this.options.credentials.bundleId) {
      throw new AppStoreError('App Store returned a transaction for a different app');
    }

    let renewal: AppleRenewalInfoPayload | null = null;
    if (entry.signedRenewalInfo) {
      renewal = await verifyAppleSignedPayload<AppleRenewalInfoPayload>(entry.signedRenewalInfo, {
        rootCertificate: this.options.rootCertificate,
        now,
      });
    }

    return {
      originalTransactionId: transaction.originalTransactionId,
      transactionId: transaction.transactionId,
      productId: transaction.productId,
      status: statusFromApple(entry.status),
      purchaseDate: new Date(transaction.purchaseDate),
      expirationDate: transaction.expiresDate ? new Date(transaction.expiresDate) : null,
      revocationDate: transaction.revocationDate ? new Date(transaction.revocationDate) : null,
      autoRenewStatus: renewal?.autoRenewStatus === undefined ? null : renewal.autoRenewStatus === 1,
      environment: transaction.environment === 'Sandbox' ? 'sandbox' : 'production',
      appAccountToken: transaction.appAccountToken ?? null,
    };
  }
}

/**
 * Whether a status grants Plus.
 *
 * Grace period and billing retry count: Apple is retrying the charge, and
 * cutting someone off mid-retry is a bad experience for an expired card. Must
 * agree with `public.is_plus()` in migration 0006.
 */
export function grantsEntitlement(status: SubscriptionStatus, expirationDate: Date | null, now: Date): boolean {
  if (status === 'revoked' || status === 'refunded' || status === 'expired') return false;
  if (expirationDate && expirationDate <= now && status === 'active') return false;
  return status === 'active' || status === 'in_grace_period' || status === 'in_billing_retry';
}
