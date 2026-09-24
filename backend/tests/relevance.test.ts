/**
 * Relevance filtering — the cost-control and quality layer between the user's
 * whole history and the model's context window.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  RELEVANCE_LIMITS,
  medianCategorySpend,
  selectRelevantHistory,
  selectRelevantWardrobe,
  wardrobeRelevance,
  type ProductHint,
} from '../shared/context/relevance.ts';
import type { Category, PurchaseHistorySummary, WardrobeItemSummary } from '../shared/types.ts';

function item(overrides: Partial<WardrobeItemSummary> & { id: string }): WardrobeItemSummary {
  return {
    category: 'fashion',
    subcategory: 'tops',
    color: 'black',
    brand: null,
    price: 60,
    styleTags: ['minimal'],
    purchaseDate: '2025-01-01',
    ...overrides,
  };
}

function history(
  overrides: Partial<PurchaseHistorySummary> & { analysisId: string },
): PurchaseHistorySummary {
  return {
    productName: 'Thing',
    category: 'fashion',
    subcategory: 'tops',
    price: 80,
    verdict: 'WAIT',
    action: null,
    satisfaction: null,
    decidedAt: '2025-06-01T00:00:00Z',
    ...overrides,
  };
}

const jacketHint: ProductHint = {
  category: 'fashion',
  subcategory: 'outerwear',
  colors: ['black'],
  styleTags: ['minimal', 'classic'],
};

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

test('a same-subcategory item outranks an adjacent one, which outranks an unrelated one', () => {
  const sameSub = wardrobeRelevance(item({ id: 'a', subcategory: 'outerwear' }), jacketHint);
  const adjacent = wardrobeRelevance(item({ id: 'b', subcategory: 'tops' }), jacketHint);
  const unrelated = wardrobeRelevance(
    item({ id: 'c', category: 'beauty', subcategory: 'skincare', color: 'white', styleTags: [] }),
    jacketHint,
  );
  assert.ok(sameSub > adjacent, `same ${sameSub} should beat adjacent ${adjacent}`);
  assert.ok(adjacent > unrelated, `adjacent ${adjacent} should beat unrelated ${unrelated}`);
});

test('a colour match raises relevance', () => {
  const matching = wardrobeRelevance(item({ id: 'a', subcategory: 'outerwear', color: 'black' }), jacketHint);
  const other = wardrobeRelevance(item({ id: 'b', subcategory: 'outerwear', color: 'yellow' }), jacketHint);
  assert.ok(matching > other);
});

test('skincare is not sent when analysing a blazer', () => {
  const wardrobe = [
    ...Array.from({ length: 20 }, (_, i) =>
      item({ id: `beauty-${i}`, category: 'beauty' as Category, subcategory: 'skincare', color: 'white', styleTags: [] }),
    ),
    item({ id: 'jacket-1', subcategory: 'outerwear' }),
    item({ id: 'jacket-2', subcategory: 'outerwear' }),
  ];
  const selected = selectRelevantWardrobe(wardrobe, jacketHint);
  assert.ok(selected.some((i) => i.id === 'jacket-1'));
  assert.ok(selected.some((i) => i.id === 'jacket-2'));
  assert.equal(selected.filter((i) => i.category === 'beauty').length, 0);
});

// ---------------------------------------------------------------------------
// Limits and shape
// ---------------------------------------------------------------------------

test('a small wardrobe is sent whole', () => {
  const wardrobe = Array.from({ length: 5 }, (_, i) => item({ id: `i-${i}` }));
  assert.equal(selectRelevantWardrobe(wardrobe, jacketHint).length, 5);
});

test('a large wardrobe is capped', () => {
  const wardrobe = Array.from({ length: 200 }, (_, i) => item({ id: `i-${i}`, subcategory: 'outerwear' }));
  assert.equal(selectRelevantWardrobe(wardrobe, jacketHint).length, RELEVANCE_LIMITS.wardrobeItems);
});

test('an empty wardrobe returns nothing rather than throwing', () => {
  assert.deepEqual(selectRelevantWardrobe([], jacketHint), []);
});

test('with no hint, the sample spreads across subcategories instead of one bucket', () => {
  const wardrobe = [
    ...Array.from({ length: 40 }, (_, i) => item({ id: `top-${i}`, subcategory: 'tops' })),
    ...Array.from({ length: 5 }, (_, i) => item({ id: `shoe-${i}`, subcategory: 'shoes' })),
    ...Array.from({ length: 5 }, (_, i) => item({ id: `bag-${i}`, subcategory: 'bags' })),
  ];
  const selected = selectRelevantWardrobe(wardrobe, {
    category: null,
    subcategory: null,
    colors: [],
    styleTags: [],
  });
  const subcategories = new Set(selected.map((i) => i.subcategory));
  assert.ok(subcategories.size >= 3, `expected a spread, got ${[...subcategories].join(', ')}`);
  assert.equal(selected.length, RELEVANCE_LIMITS.wardrobeItems);
});

test('a hint that matches nothing still returns a useful sample', () => {
  const wardrobe = Array.from({ length: 30 }, (_, i) =>
    item({ id: `i-${i}`, category: 'beauty' as Category, subcategory: 'fragrance', color: null, styleTags: [] }),
  );
  const selected = selectRelevantWardrobe(wardrobe, jacketHint);
  assert.ok(selected.length > 0, 'an empty context is worse than an imperfect one');
  assert.equal(selected.length, RELEVANCE_LIMITS.wardrobeItems);
});

test('selection is deterministic', () => {
  const wardrobe = Array.from({ length: 60 }, (_, i) =>
    item({ id: `i-${i}`, subcategory: i % 2 === 0 ? 'outerwear' : 'tops' }),
  );
  const a = selectRelevantWardrobe(wardrobe, jacketHint).map((i) => i.id);
  const b = selectRelevantWardrobe(wardrobe, jacketHint).map((i) => i.id);
  assert.deepEqual(a, b);
});

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

test('history with a recorded outcome outranks history without one', () => {
  const entries = [
    ...Array.from({ length: 20 }, (_, i) => history({ analysisId: `plain-${i}` })),
    history({ analysisId: 'with-outcome', subcategory: 'outerwear', action: 'bought', satisfaction: 'regret_it' }),
  ];
  const selected = selectRelevantHistory(entries, jacketHint);
  assert.ok(
    selected.some((e) => e.analysisId === 'with-outcome'),
    'a known outcome is the only ground truth BEFORE gets — it must survive the filter',
  );
  assert.equal(selected.length, RELEVANCE_LIMITS.historyEntries);
});

test('short history is returned newest first', () => {
  const entries = [
    history({ analysisId: 'old', decidedAt: '2025-01-01T00:00:00Z' }),
    history({ analysisId: 'new', decidedAt: '2025-09-01T00:00:00Z' }),
  ];
  assert.deepEqual(
    selectRelevantHistory(entries, jacketHint).map((e) => e.analysisId),
    ['new', 'old'],
  );
});

// ---------------------------------------------------------------------------
// Median spend — the input to the budget override rule
// ---------------------------------------------------------------------------

test('median spend needs at least three data points', () => {
  const entries = [
    history({ analysisId: '1', action: 'bought', price: 100 }),
    history({ analysisId: '2', action: 'bought', price: 200 }),
  ];
  assert.equal(medianCategorySpend(entries, 'fashion', null), null);
});

test('median spend ignores items that were not bought', () => {
  const entries = [
    history({ analysisId: '1', action: 'bought', price: 100 }),
    history({ analysisId: '2', action: 'bought', price: 110 }),
    history({ analysisId: '3', action: 'bought', price: 120 }),
    history({ analysisId: '4', action: 'skipped', price: 5000 }),
  ];
  assert.equal(medianCategorySpend(entries, 'fashion', null), 110);
});

test('median, not mean — one expensive coat does not redefine normal', () => {
  const entries = [
    history({ analysisId: '1', action: 'bought', price: 60 }),
    history({ analysisId: '2', action: 'bought', price: 70 }),
    history({ analysisId: '3', action: 'bought', price: 80 }),
    history({ analysisId: '4', action: 'bought', price: 4000 }),
  ];
  // Mean would be 1052.5. Median of [60,70,80,4000] is 75.
  assert.equal(medianCategorySpend(entries, 'fashion', null), 75);
});

test('median spend can be narrowed to a subcategory', () => {
  const entries = [
    history({ analysisId: '1', action: 'bought', price: 50, subcategory: 'tops' }),
    history({ analysisId: '2', action: 'bought', price: 60, subcategory: 'tops' }),
    history({ analysisId: '3', action: 'bought', price: 70, subcategory: 'tops' }),
    history({ analysisId: '4', action: 'bought', price: 900, subcategory: 'outerwear' }),
  ];
  assert.equal(medianCategorySpend(entries, 'fashion', 'tops'), 60);
  assert.equal(medianCategorySpend(entries, 'fashion', 'outerwear'), null, 'one point is not a normal');
});
