/**
 * BEFORE — data access for the analysis pipeline.
 *
 * Keeps SQL out of the handler. Reads go through the caller-scoped client so
 * RLS is doing the access control; only the ledger, the cost log, and the
 * metadata cache use the admin client, and each of those says why.
 */

import type { SupabaseClient } from '@supabase/supabase-js';

import type {
  Category,
  PurchaseHistorySummary,
  UserContext,
  UserPreferences,
  WardrobeItemSummary,
} from '@shared/types.ts';
import type { UsageCounts } from '@shared/http/quota.ts';
import { monthWindow, safeTimezone } from '@shared/http/quota.ts';
import type { ProductMetadata } from '@shared/product/metadata.ts';
import { ApiError } from '@shared/http/errors.ts';

export interface UserProfile {
  id: string;
  displayName: string | null;
  preferredName: string | null;
  locale: string;
  currency: string;
  timezone: string;
  preferences: UserPreferences;
  createdAt: string;
}

export async function loadUserProfile(db: SupabaseClient, userId: string): Promise<UserProfile> {
  const { data, error } = await db
    .from('users')
    .select(
      'id, display_name, preferred_name, locale, currency, timezone, created_at, user_preferences(shopping_priorities, favorite_styles, budget_sensitivity, shopping_focus)',
    )
    .eq('id', userId)
    .single();

  if (error || !data) throw new ApiError('not_found', 'profile not found');

  const prefsRow = Array.isArray(data.user_preferences)
    ? data.user_preferences[0]
    : data.user_preferences;

  return {
    id: data.id,
    displayName: data.display_name,
    preferredName: data.preferred_name,
    locale: data.locale,
    currency: data.currency,
    timezone: safeTimezone(data.timezone),
    createdAt: data.created_at,
    preferences: {
      shoppingPriorities: prefsRow?.shopping_priorities ?? [],
      favoriteStyles: prefsRow?.favorite_styles ?? [],
      budgetSensitivity: prefsRow?.budget_sensitivity ?? 'medium',
      shoppingFocus: prefsRow?.shopping_focus ?? 'both',
    },
  };
}

export async function isPlus(admin: SupabaseClient, userId: string): Promise<boolean> {
  // Entitlement is derived from verified transactions by a SQL function, never
  // from anything the client sent (spec §76).
  const { data, error } = await admin.rpc('is_plus', { target_user: userId });
  if (error) throw new ApiError('internal_error', `entitlement check failed: ${error.message}`);
  return data === true;
}

export async function loadUsageCounts(
  admin: SupabaseClient,
  userId: string,
  timezone: string,
  now: Date,
): Promise<UsageCounts> {
  const { start, end } = monthWindow(now, timezone);
  const minuteAgo = new Date(now.getTime() - 60_000).toISOString();
  const dayAgo = new Date(now.getTime() - 86_400_000).toISOString();

  const [month, minute, day, inFlight] = await Promise.all([
    admin
      .from('usage_ledger')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('counted_against_free_quota', true)
      .gte('created_at', start.toISOString())
      .lt('created_at', end.toISOString()),
    admin
      .from('usage_ledger')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .gte('created_at', minuteAgo),
    admin
      .from('usage_ledger')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .gte('created_at', dayAgo),
    admin
      .from('analyses')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .in('status', ['pending', 'processing']),
  ]);

  return {
    monthUsed: month.count ?? 0,
    lastMinuteUsed: minute.count ?? 0,
    lastDayUsed: day.count ?? 0,
    inFlight: inFlight.count ?? 0,
  };
}

export async function loadWardrobe(
  db: SupabaseClient,
  userId: string,
  limit = 300,
): Promise<WardrobeItemSummary[]> {
  const { data, error } = await db
    .from('wardrobe_items')
    .select('id, category, subcategory, color, brand, price, style_tags, purchase_date')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) throw new ApiError('internal_error', `wardrobe read failed: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id,
    category: row.category as Category,
    subcategory: row.subcategory,
    color: row.color,
    brand: row.brand,
    price: row.price === null ? null : Number(row.price),
    styleTags: row.style_tags ?? [],
    purchaseDate: row.purchase_date,
  }));
}

export async function loadHistory(
  db: SupabaseClient,
  userId: string,
  limit = 120,
): Promise<PurchaseHistorySummary[]> {
  const { data, error } = await db
    .from('analyses')
    .select(
      'id, verdict, created_at, analysis_products(name, category, subcategory, price), purchase_outcomes(action, satisfaction)',
    )
    .eq('user_id', userId)
    .eq('status', 'completed')
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) throw new ApiError('internal_error', `history read failed: ${error.message}`);

  return (data ?? []).map((row) => {
    const product = Array.isArray(row.analysis_products) ? row.analysis_products[0] : row.analysis_products;
    const outcome = Array.isArray(row.purchase_outcomes) ? row.purchase_outcomes[0] : row.purchase_outcomes;
    return {
      analysisId: row.id,
      productName: product?.name ?? null,
      category: (product?.category ?? 'other') as Category,
      subcategory: product?.subcategory ?? null,
      price: product?.price == null ? null : Number(product.price),
      verdict: row.verdict,
      action: outcome?.action ?? null,
      satisfaction: outcome?.satisfaction ?? null,
      decidedAt: row.created_at,
    };
  });
}

export function buildUserContext(
  profile: UserProfile,
  analysesCount: number,
  categoryAverageSpend: Record<string, number>,
): UserContext {
  return {
    preferences: profile.preferences,
    locale: profile.locale,
    currency: profile.currency,
    categoryAverageSpend,
    analysesCount,
  };
}

// ---------------------------------------------------------------------------
// Product metadata cache — admin client, because it is shared across users and
// therefore cannot be RLS-scoped to one.
// ---------------------------------------------------------------------------

export async function readMetadataCache(
  admin: SupabaseClient,
  url: string,
): Promise<ProductMetadata | null> {
  const { data } = await admin
    .from('product_metadata_cache')
    .select('*')
    .eq('url', url)
    .gt('expires_at', new Date().toISOString())
    .maybeSingle();

  if (!data) return null;
  return {
    title: data.title,
    brand: data.brand,
    price: data.price === null ? null : Number(data.price),
    currency: data.currency,
    availability: data.availability,
    imageUrl: data.image_url,
    retailer: data.retailer,
    structured: data.structured,
  };
}

export async function writeMetadataCache(
  admin: SupabaseClient,
  url: string,
  metadata: ProductMetadata,
): Promise<void> {
  await admin.from('product_metadata_cache').upsert(
    {
      url,
      title: metadata.title,
      brand: metadata.brand,
      price: metadata.price,
      currency: metadata.currency,
      availability: metadata.availability,
      image_url: metadata.imageUrl,
      retailer: metadata.retailer,
      structured: metadata.structured,
      fetched_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 7 * 86_400_000).toISOString(),
    },
    { onConflict: 'url' },
  );
}

// ---------------------------------------------------------------------------
// Image
// ---------------------------------------------------------------------------

const ALLOWED_MEDIA: Record<string, 'image/jpeg' | 'image/png' | 'image/webp'> = {
  'image/jpeg': 'image/jpeg',
  'image/jpg': 'image/jpeg',
  'image/png': 'image/png',
  'image/webp': 'image/webp',
};

/**
 * Fetch an uploaded image and prepare it for the model.
 *
 * The client uploads to its own storage prefix first and sends the path, so a
 * multi-megabyte JSON body never crosses the wire and a failed upload can be
 * retried without re-running the analysis.
 */
export async function loadImageForModel(
  admin: SupabaseClient,
  imagePath: string,
  maxBytes: number,
): Promise<{ data: string; mediaType: 'image/jpeg' | 'image/png' | 'image/webp' }> {
  const { data, error } = await admin.storage.from('analyses').download(imagePath);
  if (error || !data) throw new ApiError('image_unreadable', `download failed: ${error?.message}`);

  if (data.size > maxBytes) {
    throw new ApiError('image_too_large', `${data.size} bytes exceeds ${maxBytes}`);
  }

  const mediaType = ALLOWED_MEDIA[data.type] ?? null;
  if (!mediaType) {
    // HEIC reaches here only if the client failed to convert. The app converts
    // on device precisely so this stays a client bug, not a user-facing one.
    throw new ApiError('image_unreadable', `unsupported media type: ${data.type}`);
  }

  const bytes = new Uint8Array(await data.arrayBuffer());
  return { data: base64Encode(bytes), mediaType };
}

/** Chunked so a few megabytes does not blow the argument limit on spread. */
function base64Encode(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
