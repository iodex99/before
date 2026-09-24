/**
 * BEFORE — request builder.
 *
 * Turns the user's context into the compact, explicit block of text the model
 * reasons over. Two rules govern everything here:
 *   1. Say what is KNOWN and say what is NOT. Silence reads as zero to a model.
 *   2. Send the smallest context that could change the verdict (see relevance.ts).
 */

import type {
  PurchaseHistorySummary,
  UserContext,
  WardrobeItemSummary,
} from '../types.ts';

export interface ProductInput {
  /** Whatever the page gave us. Never guessed. */
  title: string | null;
  brand: string | null;
  price: number | null;
  currency: string | null;
  retailer: string | null;
  availability: string | null;
  url: string | null;
  /** True when the fields above came from a parsed page rather than the image. */
  fromStructuredMetadata: boolean;
  hasImage: boolean;
  /** Optional free text the user typed when submitting. */
  userNote: string | null;
}

export interface AnalysisPromptInput {
  product: ProductInput;
  user: UserContext;
  wardrobe: WardrobeItemSummary[];
  history: PurchaseHistorySummary[];
  /** The user's own median spend for this category, or null if not enough data. */
  categoryAverageSpend: number | null;
}

const UNKNOWN = 'not supplied';

function line(label: string, value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return `${label}: ${UNKNOWN}`;
  return `${label}: ${value}`;
}

function money(amount: number | null, currency: string | null): string | null {
  if (amount === null) return null;
  return currency ? `${amount} ${currency}` : `${amount} (currency not supplied)`;
}

function productBlock(p: ProductInput): string {
  const provenance = p.fromStructuredMetadata
    ? 'These fields were parsed from the product page and may be treated as confirmed.'
    : 'No product page was parsed. Treat every field below as unconfirmed; anything not listed must be marked unknown or estimated.';

  return [
    '## PRODUCT',
    provenance,
    line('title', p.title),
    line('brand', p.brand),
    line('price', money(p.price, p.currency)),
    line('retailer', p.retailer),
    line('availability', p.availability),
    line('source url', p.url),
    line('image supplied', p.hasImage ? 'yes' : 'no'),
    p.userNote ? line('what the user said about it', p.userNote) : null,
  ]
    .filter(Boolean)
    .join('\n');
}

function userBlock(u: UserContext, categoryAverageSpend: number | null): string {
  const prefs = u.preferences;
  return [
    '## USER',
    line('shopping priorities, most important first', prefs.shoppingPriorities.join(', ') || UNKNOWN),
    line('stated style preferences', prefs.favoriteStyles.join(', ') || UNKNOWN),
    line('budget sensitivity', prefs.budgetSensitivity),
    line('mainly shops for', prefs.shoppingFocus),
    line('locale', u.locale),
    line('currency', u.currency),
    line('analyses completed so far', u.analysesCount),
    categoryAverageSpend !== null
      ? line('their own median spend in this category', money(categoryAverageSpend, u.currency))
      : 'their own median spend in this category: not enough history yet — do not assume a normal',
  ].join('\n');
}

function wardrobeBlock(items: WardrobeItemSummary[]): string {
  if (items.length === 0) {
    return [
      '## WARDROBE',
      'BEFORE has no wardrobe data for this user.',
      'Set signal_availability false for wardrobe_compatibility, duplication_risk,',
      'and wardrobe_gap. Do not write as though you know what they own.',
    ].join('\n');
  }

  const rows = items.map((item) => {
    const parts = [
      item.subcategory ?? item.category,
      item.color ?? 'colour unknown',
      item.brand ?? 'brand unknown',
      item.price !== null ? String(item.price) : 'price unknown',
      item.styleTags.length > 0 ? item.styleTags.join('/') : 'no tags',
    ];
    return `- ${parts.join(' | ')}`;
  });

  return [
    '## WARDROBE',
    `${items.length} relevant item(s). This is a filtered subset, not their whole wardrobe —`,
    'do not conclude they own nothing else.',
    ...rows,
  ].join('\n');
}

function historyBlock(history: PurchaseHistorySummary[]): string {
  if (history.length === 0) {
    return ['## PAST DECISIONS', 'No previous decisions recorded.'].join('\n');
  }

  const rows = history.map((h) => {
    const outcome = h.satisfaction
      ? `${h.action ?? 'unknown action'} → ${h.satisfaction}`
      : (h.action ?? 'no outcome recorded');
    const price = h.price !== null ? String(h.price) : 'price unknown';
    return `- ${h.productName ?? 'unnamed'} (${h.subcategory ?? h.category}, ${price}) — BEFORE said ${h.verdict}, user ${outcome}`;
  });

  return [
    '## PAST DECISIONS',
    'What this user did after previous verdicts. Outcomes are the only ground truth here.',
    ...rows,
  ].join('\n');
}

/** The full user-turn text. The image, when present, is attached separately. */
export function buildAnalysisPrompt(input: AnalysisPromptInput): string {
  return [
    productBlock(input.product),
    '',
    userBlock(input.user, input.categoryAverageSpend),
    '',
    wardrobeBlock(input.wardrobe),
    '',
    historyBlock(input.history),
    '',
    '## TASK',
    'Judge whether THIS user has good reason to buy THIS product.',
    'Return the JSON object described in the schema. Nothing else.',
  ].join('\n');
}

/**
 * Rough token estimate for cost logging and for catching a context that has
 * grown without anyone noticing. Deliberately crude — ~4 characters per token
 * is close enough to spot a regression, and avoids shipping a tokeniser.
 */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}
