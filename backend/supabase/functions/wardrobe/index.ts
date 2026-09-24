/**
 * GET    /v1/wardrobe      — list what the user owns
 * POST   /v1/wardrobe      — add an item
 * PATCH  /v1/wardrobe/:id  — edit one
 * DELETE /v1/wardrobe/:id  — remove one
 *
 * Wardrobe compatibility is the heaviest signal in the score at 25%, and
 * duplication is what makes BEFORE say BYE at all. Until an item reaches this
 * table it changes nothing about a verdict, which is why local-only wardrobe
 * memory was the largest hole in the product.
 *
 * Reads and writes go through the caller-scoped client, so RLS is doing the
 * access control rather than a `where user_id =` that someone can forget.
 */

import { withContext, readJson, type RequestContext } from '../_shared/context.ts';
import { isPlus } from '../_shared/repository.ts';
import { ApiError, jsonResponse } from '@shared/http/errors.ts';
import { CATEGORIES, type Category } from '@shared/types.ts';

interface WardrobeBody {
  category?: string;
  subcategory?: string | null;
  color?: string | null;
  brand?: string | null;
  price?: number | null;
  currency?: string | null;
  purchaseDate?: string | null;
  styleTags?: string[];
  notes?: string | null;
  imagePath?: string | null;
  /** 'manual' | 'analysis'. Set when created from "do you own something similar?". */
  source?: string;
}

const MAX_TAGS = 12;

function itemId(url: URL): string | null {
  const segments = url.pathname.split('/').filter(Boolean);
  const index = segments.indexOf('wardrobe');
  const candidate = index >= 0 ? segments[index + 1] : undefined;
  if (!candidate) return null;
  if (!/^[0-9a-f-]{36}$/i.test(candidate)) {
    throw new ApiError('invalid_request', 'that is not a wardrobe item id');
  }
  return candidate;
}

/** Validate and normalise. Anything unrecognised is dropped, not stored. */
function sanitise(body: WardrobeBody): Record<string, unknown> {
  const update: Record<string, unknown> = {};

  if (body.category !== undefined) {
    if (!(CATEGORIES as readonly string[]).includes(body.category)) {
      throw new ApiError('invalid_request', `unknown category: ${body.category}`);
    }
    update.category = body.category as Category;
  }

  if (body.subcategory !== undefined) update.subcategory = body.subcategory?.slice(0, 40) || null;
  if (body.color !== undefined) update.color = body.color?.slice(0, 40) || null;
  if (body.brand !== undefined) update.brand = body.brand?.slice(0, 60) || null;
  if (body.notes !== undefined) update.notes = body.notes?.slice(0, 500) || null;
  if (body.imagePath !== undefined) update.imagePath = body.imagePath;

  if (body.price !== undefined) {
    if (body.price === null) {
      update.price = null;
      update.currency = null;
    } else {
      if (!Number.isFinite(body.price) || body.price < 0) {
        throw new ApiError('invalid_request', 'price must be a positive number');
      }
      const currency = body.currency?.trim().toUpperCase();
      // A price with no currency cannot be formatted for anyone, and the
      // database enforces the same rule.
      if (!currency || !/^[A-Z]{3}$/.test(currency)) {
        throw new ApiError('invalid_request', 'a price needs a 3-letter currency code');
      }
      update.price = Math.round(body.price * 100) / 100;
      update.currency = currency;
    }
  }

  if (body.purchaseDate !== undefined) {
    if (body.purchaseDate === null) {
      update.purchase_date = null;
    } else if (!/^\d{4}-\d{2}-\d{2}$/.test(body.purchaseDate)) {
      throw new ApiError('invalid_request', 'purchaseDate must be YYYY-MM-DD');
    } else {
      update.purchase_date = body.purchaseDate;
    }
  }

  if (body.styleTags !== undefined) {
    update.style_tags = [
      ...new Set(
        (body.styleTags ?? [])
          .filter((tag): tag is string => typeof tag === 'string')
          .map((tag) => tag.trim().toLowerCase().slice(0, 32))
          .filter(Boolean),
      ),
    ].slice(0, MAX_TAGS);
  }

  // `imagePath` is camelCase on the wire and snake_case in the table.
  if ('imagePath' in update) {
    update.image_path = update.imagePath;
    delete update.imagePath;
  }

  return update;
}

function toResponse(row: Record<string, unknown>) {
  return {
    id: row.id,
    category: row.category,
    subcategory: row.subcategory,
    color: row.color,
    brand: row.brand,
    price: row.price === null ? null : Number(row.price),
    currency: row.currency,
    purchaseDate: row.purchase_date,
    styleTags: row.style_tags ?? [],
    notes: row.notes,
    imagePath: row.image_path,
    source: row.source,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const SELECT =
  'id, category, subcategory, color, brand, price, currency, purchase_date, style_tags, notes, image_path, source, created_at, updated_at';

async function handler(request: Request, ctx: RequestContext): Promise<Response> {
  const url = new URL(request.url);
  const id = itemId(url);

  // ---- List ---------------------------------------------------------------
  if (request.method === 'GET') {
    const { data, error } = await ctx.db
      .from('wardrobe_items')
      .select(SELECT)
      .order('created_at', { ascending: false })
      .limit(500);

    if (error) throw new ApiError('internal_error', error.message);

    const plus = await isPlus(ctx.admin, ctx.userId);
    return jsonResponse(
      {
        items: (data ?? []).map(toResponse),
        limit: plus ? null : ctx.config.quota.freeWardrobeItems,
      },
      200,
    );
  }

  // ---- Create -------------------------------------------------------------
  if (request.method === 'POST') {
    const body = await readJson<WardrobeBody>(request, 64 * 1024);
    const fields = sanitise(body);

    if (!fields.category) fields.category = 'fashion';

    // §35 lists "full wardrobe memory" as a Plus feature. The free cap is set
    // generously on purpose: the wardrobe is what makes a verdict personal, and
    // gating it too hard would gate result quality, which §35 also forbids.
    const plus = await isPlus(ctx.admin, ctx.userId);
    if (!plus) {
      const { count } = await ctx.db
        .from('wardrobe_items')
        .select('id', { count: 'exact', head: true });

      if ((count ?? 0) >= ctx.config.quota.freeWardrobeItems) {
        throw new ApiError(
          'quota_exceeded',
          `free wardrobe limit of ${ctx.config.quota.freeWardrobeItems} reached`,
        );
      }
    }

    const { data, error } = await ctx.db
      .from('wardrobe_items')
      .insert({
        user_id: ctx.userId,
        source: body.source === 'analysis' ? 'analysis' : 'manual',
        ...fields,
      })
      .select(SELECT)
      .single();

    if (error) throw new ApiError('internal_error', error.message);

    ctx.log.info('wardrobe.added', { note: String(fields.category) });
    return jsonResponse(toResponse(data), 201);
  }

  if (!id) throw new ApiError('invalid_request', 'an item id is required');

  // ---- Update -------------------------------------------------------------
  if (request.method === 'PATCH') {
    const body = await readJson<WardrobeBody>(request, 64 * 1024);
    const fields = sanitise(body);
    if (Object.keys(fields).length === 0) {
      throw new ApiError('invalid_request', 'nothing to update');
    }

    const { data, error } = await ctx.db
      .from('wardrobe_items')
      .update(fields)
      .eq('id', id)
      .select(SELECT)
      .maybeSingle();

    if (error) throw new ApiError('internal_error', error.message);
    // RLS makes someone else's row invisible; this turns that into a clean 404.
    if (!data) throw new ApiError('not_found', 'no such wardrobe item');

    return jsonResponse(toResponse(data), 200);
  }

  // ---- Delete -------------------------------------------------------------
  if (request.method === 'DELETE') {
    const { data: existing } = await ctx.db
      .from('wardrobe_items')
      .select('image_path')
      .eq('id', id)
      .maybeSingle();

    if (!existing) throw new ApiError('not_found', 'no such wardrobe item');

    // The row cascade cannot reach storage, so the object goes first. A failure
    // here would otherwise leave an orphaned photo behind forever.
    if (existing.image_path) {
      await ctx.admin.storage.from('wardrobe').remove([existing.image_path as string]);
    }

    const { error } = await ctx.db.from('wardrobe_items').delete().eq('id', id);
    if (error) throw new ApiError('internal_error', error.message);

    ctx.log.info('wardrobe.removed');
    return jsonResponse({ deleted: true }, 200);
  }

  throw new ApiError('invalid_request', 'unsupported method');
}

Deno.serve(
  withContext(
    { endpoint: '/v1/wardrobe', methods: ['GET', 'POST', 'PATCH', 'DELETE'] },
    handler,
  ),
);
