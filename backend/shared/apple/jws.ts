/**
 * BEFORE — Apple signed-payload (JWS) verification.
 *
 * Apple signs transactions, renewal info, and App Store Server Notifications as
 * ES256 JWS with the certificate chain in the `x5c` header. Verifying one means:
 *
 *   1. parse the chain out of the header;
 *   2. verify the chain terminates at the pinned Apple root;
 *   3. verify the JWS signature under the leaf key;
 *   4. only then look at the payload.
 *
 * Step 4 is the discipline. A JWS payload is trivially readable without any of
 * steps 1–3, which is exactly why unverified decoding must not exist as a
 * convenience function anyone can reach for by mistake — `decodeUnverified` is
 * named to make that impossible to do accidentally.
 */

import { base64UrlToBytes } from './der.ts';
import {
  CertificateError,
  parseCertificateBase64,
  verifyCertificateChain,
  type ParsedCertificate,
} from './x509.ts';

export class JwsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'JwsError';
  }
}

interface JwsHeader {
  alg?: string;
  x5c?: string[];
}

interface JwsParts {
  header: JwsHeader;
  protectedSegment: string;
  payloadSegment: string;
  signature: Uint8Array;
}

function splitJws(token: string): JwsParts {
  const segments = token.split('.');
  if (segments.length !== 3) throw new JwsError('not a compact JWS');

  const [protectedSegment, payloadSegment, signatureSegment] = segments;
  if (!protectedSegment || !payloadSegment || !signatureSegment) {
    throw new JwsError('JWS has an empty segment');
  }

  let header: JwsHeader;
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(protectedSegment)));
  } catch {
    throw new JwsError('JWS header is not valid JSON');
  }

  return {
    header,
    protectedSegment,
    payloadSegment,
    signature: base64UrlToBytes(signatureSegment),
  };
}

/**
 * Read a payload WITHOUT verifying anything.
 *
 * Used only to route a notification before verification (to find which account
 * it concerns) and in tests. Anything it returns is attacker-controlled.
 */
export function decodeUnverified<T = unknown>(token: string): T {
  const { payloadSegment } = splitJws(token);
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadSegment))) as T;
  } catch {
    throw new JwsError('JWS payload is not valid JSON');
  }
}

export interface VerifyOptions {
  /** DER bytes of Apple Root CA G3, from configuration. */
  rootCertificate: Uint8Array;
  now?: Date;
}

/**
 * Verify an Apple-signed JWS and return its payload.
 *
 * Throws on any failure. There is no "verified: false" return value, because a
 * boolean is too easy to ignore at a call site.
 */
export async function verifyAppleSignedPayload<T = unknown>(
  token: string,
  options: VerifyOptions,
): Promise<T> {
  const { header, protectedSegment, payloadSegment, signature } = splitJws(token);

  if (header.alg !== 'ES256') {
    throw new JwsError(`unsupported JWS algorithm: ${header.alg ?? 'none'}`);
  }
  if (!Array.isArray(header.x5c) || header.x5c.length === 0) {
    throw new JwsError('JWS header carries no certificate chain');
  }

  let chain: ParsedCertificate[];
  try {
    chain = header.x5c.map(parseCertificateBase64);
  } catch (error) {
    throw new JwsError(
      error instanceof CertificateError ? error.message : 'certificate chain could not be parsed',
    );
  }

  let leafKey: CryptoKey;
  try {
    leafKey = await verifyCertificateChain(chain, {
      rootCertificate: options.rootCertificate,
      now: options.now,
    });
  } catch (error) {
    throw new JwsError(
      error instanceof CertificateError ? error.message : 'certificate chain verification failed',
    );
  }

  // ES256 signs the ASCII of `protected.payload`, and JOSE uses raw r||s rather
  // than the DER form certificates use.
  const signedData = new TextEncoder().encode(`${protectedSegment}.${payloadSegment}`);
  const valid = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    leafKey,
    signature as BufferSource,
    signedData as BufferSource,
  );

  if (!valid) throw new JwsError('JWS signature does not verify');

  try {
    return JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadSegment))) as T;
  } catch {
    throw new JwsError('JWS payload is not valid JSON');
  }
}

// ---------------------------------------------------------------------------
// Apple payload shapes
// ---------------------------------------------------------------------------

/** JWSTransactionDecodedPayload — the fields BEFORE uses. */
export interface AppleTransactionPayload {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate: number;
  originalPurchaseDate?: number;
  expiresDate?: number;
  type?: string;
  inAppOwnershipType?: string;
  environment?: string;
  revocationDate?: number;
  revocationReason?: number;
  appAccountToken?: string;
}

/** JWSRenewalInfoDecodedPayload */
export interface AppleRenewalInfoPayload {
  originalTransactionId: string;
  autoRenewProductId?: string;
  autoRenewStatus?: number;
  expirationIntent?: number;
  gracePeriodExpiresDate?: number;
  isInBillingRetryPeriod?: boolean;
  environment?: string;
}

/** responseBodyV2DecodedPayload */
export interface AppleNotificationPayload {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  version?: string;
  signedDate?: number;
  data?: {
    bundleId?: string;
    environment?: string;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
    status?: number;
  };
}

export interface VerifiedTransaction {
  transaction: AppleTransactionPayload;
  environment: 'sandbox' | 'production';
}

/**
 * Verify a signed transaction and check it is actually ours.
 *
 * The bundle id check is not ceremony: without it, a validly-signed transaction
 * from any other App Store app would verify here and could be replayed to grant
 * BEFORE Plus.
 */
export async function verifyTransaction(
  signedTransaction: string,
  options: VerifyOptions & { expectedBundleId: string; allowSandbox: boolean },
): Promise<VerifiedTransaction> {
  const payload = await verifyAppleSignedPayload<AppleTransactionPayload>(signedTransaction, options);

  if (!payload.transactionId || !payload.originalTransactionId || !payload.productId) {
    throw new JwsError('transaction payload is missing required fields');
  }

  if (payload.bundleId !== options.expectedBundleId) {
    throw new JwsError(
      `transaction belongs to ${payload.bundleId}, not ${options.expectedBundleId}`,
    );
  }

  const environment = payload.environment === 'Sandbox' ? 'sandbox' : 'production';
  if (environment === 'sandbox' && !options.allowSandbox) {
    throw new JwsError('sandbox transactions are not accepted in this environment');
  }

  return { transaction: payload, environment };
}
