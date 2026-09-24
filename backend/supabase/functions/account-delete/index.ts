/**
 * POST /v1/account/delete — permanent account deletion (spec §77).
 *
 * Requires an explicit confirmation in the body so a stray POST cannot delete
 * someone's account. The SQL function does the work in a documented order:
 * storage objects first, then the auth user, which cascades every public row.
 *
 * What this does NOT do: cancel the App Store subscription. We cannot, and
 * pretending otherwise would leave someone paying for an account that no longer
 * exists. The response says so, and the app repeats it before confirming.
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';

interface DeleteBody {
  /** Must be the literal string "DELETE". */
  confirmation?: string;
}

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const body = await readJson<DeleteBody>(request, 4096);

  if (body.confirmation !== 'DELETE') {
    throw new ApiError('invalid_request', 'confirmation must be the string "DELETE"');
  }

  const { data, error } = await ctx.admin.rpc('delete_user_account', { target_user: ctx.userId });

  if (error) {
    ctx.log.error('account.delete_failed', { errorKind: 'rpc', note: error.code });
    throw new ApiError('internal_error', `deletion failed: ${error.message}`);
  }

  // Logged without the user id: the account is gone, and keeping a line that
  // says "this specific person deleted their account" is its own privacy problem.
  ctx.log.info('account.deleted', { note: 'user data removed' });

  return jsonResponse(
    {
      deleted: true,
      details: data,
      subscriptionNotice:
        'Your BEFORE data has been deleted. If you have an active subscription, cancel it in Settings on your device — only Apple can do that.',
    },
    200,
  );
}

Deno.serve(withContext({ endpoint: '/v1/account/delete', methods: ['POST'] }, handler));
