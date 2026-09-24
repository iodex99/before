/**
 * GET /v1/account/export — everything BEFORE holds about you (spec §43).
 *
 * Calls `export_user_data()`, which is `security invoker`, so RLS applies and
 * it can only ever return the caller's own rows. The endpoint adds no filtering
 * of its own — a `where user_id =` here would be a second place to get it
 * wrong, and the database is already right.
 *
 * Image bytes are not included. What is included is the storage path plus a
 * short-lived signed URL for each, so an export stays a readable document
 * rather than a hundred-megabyte download that times out.
 */

import { withContext, type RequestContext } from '../_shared/context.ts';
import { ApiError } from '@shared/http/errors.ts';
import { CORS_HEADERS } from '@shared/http/errors.ts';

interface ExportRow {
  analyses?: Array<{ id?: string; image_path?: string | null }>;
  wardrobe_items?: Array<{ id?: string; image_path?: string | null }>;
  [key: string]: unknown;
}

const SIGNED_URL_TTL_SECONDS = 3600;

async function handler(_request: Request, ctx: RequestContext): Promise<Response> {
  const { data, error } = await ctx.db.rpc('export_user_data');

  if (error) throw new ApiError('internal_error', `export failed: ${error.message}`);
  if (!data) throw new ApiError('not_found', 'no data to export');

  const payload = data as ExportRow;

  // Attach signed URLs so the export is actually usable. Deliberately
  // short-lived: an export file that grants permanent access to someone's
  // wardrobe photos is a worse privacy outcome than no export at all.
  const images: Array<{ bucket: string; path: string; url: string | null; expiresInSeconds: number }> = [];

  for (const [bucket, rows] of [
    ['analyses', payload.analyses ?? []],
    ['wardrobe', payload.wardrobe_items ?? []],
  ] as const) {
    for (const row of rows) {
      if (!row?.image_path) continue;
      const { data: signed } = await ctx.admin.storage
        .from(bucket)
        .createSignedUrl(row.image_path, SIGNED_URL_TTL_SECONDS);

      images.push({
        bucket,
        path: row.image_path,
        url: signed?.signedUrl ?? null,
        expiresInSeconds: SIGNED_URL_TTL_SECONDS,
      });
    }
  }

  const document = {
    format: 'before.export.v1',
    exportedAt: new Date().toISOString(),
    notice:
      'This is everything BEFORE holds about your account. Image links expire one hour after this file was created. Your subscription is managed by Apple and is not included.',
    ...payload,
    images,
  };

  ctx.log.info('account.exported', {
    note: `${(payload.analyses ?? []).length} analyses, ${images.length} images`,
  });

  // Sent as a download so the share sheet offers Files and Mail rather than
  // rendering a wall of JSON.
  return new Response(JSON.stringify(document, null, 2), {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'content-type': 'application/json',
      'content-disposition': `attachment; filename="before-export-${new Date().toISOString().slice(0, 10)}.json"`,
    },
  });
}

Deno.serve(withContext({ endpoint: '/v1/account/export', methods: ['GET'] }, handler));
