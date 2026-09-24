/**
 * POST /v1/subscription/sync
 *
 * The client reports a StoreKit transaction. Nothing it says is trusted.
 *
 *   1. The signed transaction JWS is verified against the pinned Apple root.
 *   2. The bundle id must be ours, and a sandbox transaction must not grant
 *      production entitlement.
 *   3. When App Store Server API credentials are configured, Apple is asked
 *      what the subscription actually is right now, and THAT is what is stored.
 *      Renewals, refunds, and revocations are only visible this way.
 *   4. The row is written with the service role, so no client can write it.
 *
 * Everything the client sends other than `signedTransaction` is used for
 * logging only. The verified payload is the source of every stored value.
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import { verifyTransaction, JwsError } from '@shared/apple/jws.ts';
import {
  AppStoreClient,
  AppStoreError,
  grantsEntitlement,
  statusFromApple,
  type SubscriptionSnapshot,
  type SubscriptionStatus,
} from '@shared/apple/appstore.ts';

interface SyncBody {
  /** The JWS from StoreKit. The only field that carries any authority. */
  signedTransaction?: string;
  /** Advisory, for logging when verification fails. */
  productId?: string;
  originalTransactionId?: string;
  environment?: 'sandbox' | 'production';
}

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const body = await readJson<SyncBody>(request, 256 * 1024);

  if (!body.signedTransaction) {
    throw new ApiError('invalid_request', 'signedTransaction is required');
  }

  const apple = ctx.config.apple;
  if (!apple.rootCertificate) {
    // Only reachable outside production; loadConfig refuses to boot otherwise.
    ctx.log.error('subscription.verification_unavailable', {
      note: 'APPLE_ROOT_CA_G3_BASE64 not configured',
    });
    throw new ApiError('internal_error', 'subscription verification is not configured');
  }

  // --- 1 and 2: verify the client's transaction -----------------------------
  let verified;
  try {
    verified = await verifyTransaction(body.signedTransaction, {
      rootCertificate: apple.rootCertificate,
      expectedBundleId: apple.bundleId,
      allowSandbox: apple.allowSandbox,
    });
  } catch (error) {
    ctx.log.warn('subscription.verification_failed', {
      errorKind: error instanceof JwsError ? 'jws' : 'unknown',
      note: error instanceof Error ? error.message.slice(0, 160) : undefined,
    });
    throw new ApiError('forbidden', 'that transaction could not be verified');
  }

  const { transaction, environment } = verified;

  // --- 3: ask Apple what it is now ------------------------------------------
  let snapshot: SubscriptionSnapshot | null = null;
  let reconciled = false;

  if (apple.serverApi) {
    try {
      const client = new AppStoreClient({
        credentials: { ...apple.serverApi, bundleId: apple.bundleId },
        rootCertificate: apple.rootCertificate,
        environment,
      });
      snapshot = await client.subscriptionStatus(transaction.originalTransactionId);
      reconciled = snapshot !== null;
    } catch (error) {
      // A reachability problem must not block a legitimate purchase. The
      // verified transaction is still trustworthy; it is just older than
      // Apple's current view. The notification handler will correct it.
      ctx.log.warn('subscription.reconcile_failed', {
        errorKind: error instanceof AppStoreError ? 'appstore' : 'unknown',
        status: error instanceof AppStoreError ? (error.status ?? undefined) : undefined,
      });
    }
  }

  // --- Resolve the values to store ------------------------------------------
  const expirationDate = snapshot?.expirationDate
    ?? (transaction.expiresDate ? new Date(transaction.expiresDate) : null);
  const revocationDate = snapshot?.revocationDate
    ?? (transaction.revocationDate ? new Date(transaction.revocationDate) : null);

  const status: SubscriptionStatus = snapshot
    ? snapshot.status
    : revocationDate
      ? 'revoked'
      : deriveStatusFromExpiry(expirationDate);

  const { error } = await ctx.admin.from('subscriptions').upsert(
    {
      user_id: ctx.userId,
      product_id: snapshot?.productId ?? transaction.productId,
      original_transaction_id: transaction.originalTransactionId,
      transaction_id: snapshot?.transactionId ?? transaction.transactionId,
      purchase_date: new Date(transaction.purchaseDate).toISOString(),
      expiration_date: expirationDate?.toISOString() ?? null,
      environment,
      status,
      app_account_token: snapshot?.appAccountToken ?? transaction.appAccountToken ?? null,
      auto_renew_status: snapshot?.autoRenewStatus ?? null,
      revocation_date: revocationDate?.toISOString() ?? null,
      last_verified_at: new Date().toISOString(),
    },
    { onConflict: 'original_transaction_id,environment' },
  );

  if (error) throw new ApiError('internal_error', `subscription upsert failed: ${error.message}`);

  const isPlus = grantsEntitlement(status, expirationDate, new Date());

  ctx.log.info('subscription.synced', {
    isPlus,
    note: `${status}${reconciled ? ' (reconciled)' : ' (transaction only)'}`,
  });

  return jsonResponse(
    {
      isPlus,
      status,
      environment,
      expirationDate: expirationDate?.toISOString() ?? null,
      /** False when Apple could not be reached; the client should try later. */
      reconciled,
    },
    200,
  );
}

function deriveStatusFromExpiry(expirationDate: Date | null): SubscriptionStatus {
  if (!expirationDate) return 'active'; // non-renewing or lifetime
  return expirationDate.getTime() > Date.now() ? 'active' : 'expired';
}

export { statusFromApple };

Deno.serve(withContext({ endpoint: '/v1/subscription/sync', methods: ['POST'] }, handler));
