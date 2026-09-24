/**
 * POST /v1/app-store/notifications — App Store Server Notifications V2.
 *
 * Apple calls this. There is no user session and no bearer token; the JWS
 * signature is the entire authentication, which is why it is verified before
 * anything else happens and why a failure returns 401 rather than 200.
 *
 * This is the only way BEFORE learns about a renewal, a refund, a revocation,
 * or a billing failure that happens while the app is closed. Without it, a
 * refunded subscription keeps its entitlement until the user next opens the app.
 *
 * Configure the URL in App Store Connect:
 *   https://<project>.supabase.co/functions/v1/app-store-notifications
 * and deploy with --no-verify-jwt, since Apple does not send a Supabase JWT.
 */

import { withPublicContext, readJson, type PublicRequestContext } from '../_shared/context.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import {
  JwsError,
  decodeUnverified,
  verifyAppleSignedPayload,
  verifyTransaction,
  type AppleNotificationPayload,
  type AppleRenewalInfoPayload,
} from '@shared/apple/jws.ts';
import { grantsEntitlement, type SubscriptionStatus } from '@shared/apple/appstore.ts';

interface NotificationBody {
  signedPayload?: string;
}

/**
 * How each notification maps to stored state.
 *
 * `null` means "record it, change nothing" — a price-increase consent or a
 * renewal-preference change is worth having in the log but does not alter
 * entitlement, and guessing at one would be worse than leaving it alone.
 */
function statusFor(type: string, subtype: string | undefined): SubscriptionStatus | null {
  switch (type) {
    case 'SUBSCRIBED':
    case 'DID_RENEW':
    case 'OFFER_REDEEMED':
    case 'RENEWAL_EXTENDED':
      return 'active';

    case 'DID_FAIL_TO_RENEW':
      // With GRACE_PERIOD the user keeps access while Apple retries.
      return subtype === 'GRACE_PERIOD' ? 'in_grace_period' : 'in_billing_retry';

    case 'GRACE_PERIOD_EXPIRED':
      return 'in_billing_retry';

    case 'EXPIRED':
      return 'expired';

    case 'REFUND':
      return 'refunded';

    case 'REVOKE':
      return 'revoked';

    default:
      return null;
  }
}

async function handler(request: Request, ctx: PublicRequestContext): Promise<Response> {
  const body = await readJson<NotificationBody>(request, 512 * 1024);
  if (!body.signedPayload) throw new ApiError('invalid_request', 'signedPayload is required');

  const apple = ctx.config.apple;
  if (!apple.rootCertificate) {
    ctx.log.error('notification.verification_unavailable', {
      note: 'APPLE_ROOT_CA_G3_BASE64 not configured',
    });
    throw new ApiError('internal_error', 'notification verification is not configured');
  }

  // --- Verify before reading -----------------------------------------------
  let notification: AppleNotificationPayload;
  try {
    notification = await verifyAppleSignedPayload<AppleNotificationPayload>(body.signedPayload, {
      rootCertificate: apple.rootCertificate,
    });
  } catch (error) {
    // Unauthenticated endpoint: anyone can POST here. A bad signature is the
    // expected shape of abuse and gets a 401, not a 200.
    ctx.log.warn('notification.verification_failed', {
      errorKind: error instanceof JwsError ? 'jws' : 'unknown',
      note: error instanceof Error ? error.message.slice(0, 160) : undefined,
    });
    throw new ApiError('unauthorized', 'notification signature is not valid');
  }

  const environment = notification.data?.environment === 'Sandbox' ? 'sandbox' : 'production';

  // A sandbox notification must never touch production entitlement.
  if (environment === 'sandbox' && !apple.allowSandbox) {
    ctx.log.info('notification.sandbox_ignored', { note: notification.notificationType });
    return jsonResponse({ received: true, applied: false, reason: 'sandbox ignored' }, 200);
  }

  // --- Record it, and use the unique index to dedupe -----------------------
  // Apple retries until it gets a 2xx, so the same notificationUUID arrives
  // more than once as a matter of course.
  const { error: insertError } = await ctx.admin.from('app_store_notifications').insert({
    notification_uuid: notification.notificationUUID,
    notification_type: notification.notificationType,
    subtype: notification.subtype ?? null,
    environment,
    // Retained briefly for replay; cleanup_expired_cache() purges it.
    signed_payload: body.signedPayload,
  });

  if (insertError) {
    // 23505 is unique_violation: we have already processed this one.
    if (insertError.code === '23505') {
      ctx.log.info('notification.duplicate', { note: notification.notificationUUID });
      return jsonResponse({ received: true, applied: false, reason: 'duplicate' }, 200);
    }
    throw new ApiError('internal_error', `could not record notification: ${insertError.message}`);
  }

  // --- The nested transaction is its own JWS and gets its own verification --
  const signedTransaction = notification.data?.signedTransactionInfo;
  if (!signedTransaction) {
    await markProcessed(ctx, notification.notificationUUID, 'no transaction attached');
    return jsonResponse({ received: true, applied: false, reason: 'no transaction' }, 200);
  }

  let transaction;
  try {
    const verified = await verifyTransaction(signedTransaction, {
      rootCertificate: apple.rootCertificate,
      expectedBundleId: apple.bundleId,
      allowSandbox: apple.allowSandbox,
    });
    transaction = verified.transaction;
  } catch (error) {
    await markProcessed(
      ctx,
      notification.notificationUUID,
      error instanceof Error ? error.message.slice(0, 200) : 'transaction verification failed',
    );
    throw new ApiError('unauthorized', 'nested transaction could not be verified');
  }

  let renewal: AppleRenewalInfoPayload | null = null;
  if (notification.data?.signedRenewalInfo) {
    try {
      renewal = await verifyAppleSignedPayload<AppleRenewalInfoPayload>(
        notification.data.signedRenewalInfo,
        { rootCertificate: apple.rootCertificate },
      );
    } catch {
      // Renewal info is supplementary; its absence must not drop the whole
      // notification, which still carries the authoritative transaction.
      ctx.log.warn('notification.renewal_info_unverified');
    }
  }

  const status = statusFor(notification.notificationType, notification.subtype);
  const expirationDate = transaction.expiresDate ? new Date(transaction.expiresDate) : null;
  const revocationDate = transaction.revocationDate ? new Date(transaction.revocationDate) : null;

  // --- Apply ---------------------------------------------------------------
  const update: Record<string, unknown> = {
    product_id: transaction.productId,
    transaction_id: transaction.transactionId,
    expiration_date: expirationDate?.toISOString() ?? null,
    revocation_date: revocationDate?.toISOString() ?? null,
    last_verified_at: new Date().toISOString(),
  };

  if (status) update.status = status;
  if (renewal?.autoRenewStatus !== undefined) update.auto_renew_status = renewal.autoRenewStatus === 1;

  // Matched on the transaction identity, not on a user id: a notification does
  // not carry one, and the subscription row is what links the two.
  const { data: updated, error: updateError } = await ctx.admin
    .from('subscriptions')
    .update(update)
    .eq('original_transaction_id', transaction.originalTransactionId)
    .eq('environment', environment)
    .select('user_id, status, expiration_date');

  if (updateError) {
    await markProcessed(ctx, notification.notificationUUID, updateError.message.slice(0, 200));
    throw new ApiError('internal_error', `could not apply notification: ${updateError.message}`);
  }

  // A notification for a subscription we have never seen is normal: a purchase
  // whose sync has not arrived yet, or a user who deleted their account. It is
  // recorded and acknowledged, not treated as an error.
  const matched = (updated ?? []).length > 0;

  await markProcessed(ctx, notification.notificationUUID, null);

  ctx.log.info('notification.applied', {
    isPlus: status ? grantsEntitlement(status, expirationDate, new Date()) : undefined,
    note: `${notification.notificationType}${notification.subtype ? `/${notification.subtype}` : ''}${matched ? '' : ' (no matching subscription)'}`,
  });

  return jsonResponse(
    { received: true, applied: matched && status !== null, notificationType: notification.notificationType },
    200,
  );
}

async function markProcessed(
  ctx: PublicRequestContext,
  notificationUuid: string,
  error: string | null,
): Promise<void> {
  await ctx.admin
    .from('app_store_notifications')
    .update({ processed_at: new Date().toISOString(), processing_error: error })
    .eq('notification_uuid', notificationUuid);
}

export { decodeUnverified };

Deno.serve(
  withPublicContext({ endpoint: '/v1/app-store/notifications', methods: ['POST'] }, handler),
);
