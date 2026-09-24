/**
 * BEFORE — relevance filtering.
 *
 * Sending a user's whole closet and full history to the model would be slow,
 * expensive, and worse: a 200-item context buries the three items that actually
 * matter. This picks the small subset that could change the verdict.
 *
 * Ordering problem worth knowing about: we need wardrobe context BEFORE the
 * model has classified the product, so we cannot filter on the product's real
 * category. We filter on a HINT (from URL metadata, the share source, or the
 * user's stated focus) when we have one, and fall back to a recency-weighted
 * stratified sample across their categories when we do not. See DECISIONS.md
 * for why this beats a two-pass classify-then-analyse round trip at MVP scale.
 */

import type {
  Category,
  PurchaseHistorySummary,
  WardrobeItemSummary,
} from '../types.ts';

export const RELEVANCE_LIMITS = {
  wardrobeItems: 12,
  historyEntries: 8,
  recentAnalyses: 5,
} as const;

/** Subcategories that compete for the same job in a wardrobe. */
const ADJACENCY: Record<string, string[]> = {
  outerwear: ['tops', 'formalwear'],
  tops: ['outerwear', 'dresses', 'activewear'],
  bottoms: ['dresses', 'activewear'],
  dresses: ['tops', 'bottoms', 'formalwear'],
  shoes: [],
  bags: ['accessories'],
  accessories: ['bags'],
  activewear: ['tops', 'bottoms'],
  formalwear: ['dresses', 'outerwear'],
  makeup: ['tools'],
  skincare: [],
  haircare: ['tools'],
  fragrance: [],
  nails: ['tools'],
  tools: ['makeup', 'haircare', 'nails'],
};

export interface ProductHint {
  category: Category | null;
  subcategory: string | null;
  colors: string[];
  styleTags: string[];
}

const norm = (v: string | null | undefined) => (v ?? '').trim().toLowerCase();

function overlap(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const set = new Set(a.map(norm));
  let count = 0;
  for (const entry of b) if (set.has(norm(entry))) count++;
  return count;
}

/**
 * Relevance score for one wardrobe item against the hint. Higher is more likely
 * to change the verdict — either because it duplicates the candidate or because
 * it is what the candidate would be worn with.
 */
export function wardrobeRelevance(item: WardrobeItemSummary, hint: ProductHint): number {
  let score = 0;

  if (hint.subcategory && norm(item.subcategory) === norm(hint.subcategory)) {
    score += 50; // a direct duplication candidate
  } else if (hint.subcategory) {
    const adjacent = ADJACENCY[norm(hint.subcategory)] ?? [];
    if (adjacent.includes(norm(item.subcategory))) score += 30;
  }

  if (hint.category && item.category === hint.category) score += 10;

  if (item.color) score += overlap(hint.colors, [item.color]) * 15;
  score += Math.min(overlap(hint.styleTags, item.styleTags), 3) * 10;

  return score;
}

/**
 * A recency-weighted stratified sample, used when we have no category hint.
 * Takes the most recent items from each subcategory in turn so a 60-item closet
 * does not come back as sixty t-shirts.
 */
function stratifiedSample(items: WardrobeItemSummary[], limit: number): WardrobeItemSummary[] {
  const buckets = new Map<string, WardrobeItemSummary[]>();
  for (const item of items) {
    const key = norm(item.subcategory) || item.category;
    const bucket = buckets.get(key) ?? [];
    bucket.push(item);
    buckets.set(key, bucket);
  }

  for (const bucket of buckets.values()) {
    bucket.sort((a, b) => (b.purchaseDate ?? '').localeCompare(a.purchaseDate ?? ''));
  }

  const out: WardrobeItemSummary[] = [];
  const keys = [...buckets.keys()].sort();
  let round = 0;
  while (out.length < limit) {
    let added = false;
    for (const key of keys) {
      const bucket = buckets.get(key)!;
      if (round < bucket.length) {
        out.push(bucket[round]);
        added = true;
        if (out.length >= limit) break;
      }
    }
    if (!added) break;
    round++;
  }
  return out;
}

export function selectRelevantWardrobe(
  wardrobe: WardrobeItemSummary[],
  hint: ProductHint,
  limit: number = RELEVANCE_LIMITS.wardrobeItems,
): WardrobeItemSummary[] {
  if (wardrobe.length === 0) return [];
  if (wardrobe.length <= limit) return [...wardrobe];

  const hasHint = Boolean(hint.category || hint.subcategory || hint.styleTags.length > 0);
  if (!hasHint) return stratifiedSample(wardrobe, limit);

  const ranked = wardrobe
    .map((item) => ({ item, score: wardrobeRelevance(item, hint) }))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      // Stable, deterministic tiebreak: newer first, then id.
      const dateDiff = (b.item.purchaseDate ?? '').localeCompare(a.item.purchaseDate ?? '');
      return dateDiff !== 0 ? dateDiff : a.item.id.localeCompare(b.item.id);
    });

  const relevant = ranked.filter((r) => r.score > 0).slice(0, limit).map((r) => r.item);

  // If the hint matched nothing, a stratified sample is more useful than the
  // arbitrary top-N of a list where every score is zero.
  if (relevant.length === 0) return stratifiedSample(wardrobe, limit);

  return relevant;
}

/**
 * History relevance. A past decision matters most when it was the same kind of
 * thing AND the user told us what happened afterwards — an outcome is the only
 * ground truth BEFORE ever gets.
 */
export function historyRelevance(entry: PurchaseHistorySummary, hint: ProductHint): number {
  let score = 0;
  if (hint.subcategory && norm(entry.subcategory) === norm(hint.subcategory)) score += 40;
  if (hint.category && entry.category === hint.category) score += 15;
  if (entry.satisfaction) score += 20; // a known outcome
  if (entry.action === 'bought' || entry.action === 'skipped') score += 10;
  return score;
}

export function selectRelevantHistory(
  history: PurchaseHistorySummary[],
  hint: ProductHint,
  limit: number = RELEVANCE_LIMITS.historyEntries,
): PurchaseHistorySummary[] {
  if (history.length <= limit) {
    return [...history].sort((a, b) => b.decidedAt.localeCompare(a.decidedAt));
  }

  return history
    .map((entry) => ({ entry, score: historyRelevance(entry, hint) }))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      const dateDiff = b.entry.decidedAt.localeCompare(a.entry.decidedAt);
      return dateDiff !== 0 ? dateDiff : a.entry.analysisId.localeCompare(b.entry.analysisId);
    })
    .slice(0, limit)
    .map((r) => r.entry);
}

/**
 * The user's own median spend for a category, used by the budget override rule.
 * Median, not mean — one coat should not redefine "normal" for outerwear.
 * Returns null below three data points rather than inventing a normal.
 */
export function medianCategorySpend(
  history: PurchaseHistorySummary[],
  category: Category,
  subcategory: string | null,
): number | null {
  const prices = history
    .filter((h) => h.category === category && h.action === 'bought' && h.price !== null && h.price > 0)
    .filter((h) => (subcategory ? norm(h.subcategory) === norm(subcategory) : true))
    .map((h) => h.price as number)
    .sort((a, b) => a - b);

  if (prices.length < 3) return null;

  const mid = Math.floor(prices.length / 2);
  return prices.length % 2 === 0 ? (prices[mid - 1] + prices[mid]) / 2 : prices[mid];
}
