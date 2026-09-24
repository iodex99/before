/**
 * BEFORE — shared domain contracts.
 *
 * Runtime-neutral: no Deno APIs, no Node APIs, no side-effecting imports.
 * Loaded by Supabase Edge Functions (Deno) and by the test suite (Node 22).
 * Mirrored in Swift at ios/BeforeKit/Sources/BeforeKit/Models.
 */

// ---------------------------------------------------------------------------
// Enumerations. Explicit values only — never ad-hoc strings across the wire.
// ---------------------------------------------------------------------------

export const VERDICTS = ['BUY', 'WAIT', 'BYE'] as const;
export type Verdict = (typeof VERDICTS)[number];

export const SUGGESTED_ACTIONS = [
  'BUY_IT',
  'WAIT_48_HOURS',
  'CHECK_WARDROBE_FIRST',
  'WAIT_FOR_SALE',
  'SKIP_IT',
] as const;
export type SuggestedAction = (typeof SUGGESTED_ACTIONS)[number];

/**
 * Top-level category. `fashion` and `beauty` ship in MVP; the rest are reserved
 * now so stored rows stay valid when those surfaces open up later.
 */
export const CATEGORIES = [
  'fashion',
  'beauty',
  'accessory',
  'home',
  'travel',
  'gift',
  'other',
] as const;
export type Category = (typeof CATEGORIES)[number];

export const FASHION_SUBCATEGORIES = [
  'tops',
  'bottoms',
  'dresses',
  'outerwear',
  'shoes',
  'bags',
  'accessories',
  'activewear',
  'formalwear',
] as const;

export const BEAUTY_SUBCATEGORIES = [
  'makeup',
  'skincare',
  'haircare',
  'fragrance',
  'nails',
  'tools',
] as const;

export const SHOPPING_PRIORITIES = [
  'style',
  'price',
  'quality',
  'versatility',
  'longevity',
  'trend',
  'sustainability',
] as const;
export type ShoppingPriority = (typeof SHOPPING_PRIORITIES)[number];

export const STYLE_PREFERENCES = [
  'minimal',
  'classic',
  'feminine',
  'casual',
  'edgy',
  'romantic',
  'streetwear',
  'preppy',
  'bohemian',
  'sporty',
] as const;
export type StylePreference = (typeof STYLE_PREFERENCES)[number];

export const BUDGET_SENSITIVITIES = ['low', 'medium', 'high'] as const;
export type BudgetSensitivity = (typeof BUDGET_SENSITIVITIES)[number];

export const SHOPPING_FOCUSES = ['fashion', 'beauty', 'both'] as const;
export type ShoppingFocus = (typeof SHOPPING_FOCUSES)[number];

export const INPUT_TYPES = [
  'photo',
  'camera',
  'screenshot',
  'url',
  'share_extension',
] as const;
export type InputType = (typeof INPUT_TYPES)[number];

export const OUTCOME_ACTIONS = ['bought', 'skipped', 'still_thinking'] as const;
export type OutcomeAction = (typeof OUTCOME_ACTIONS)[number];

export const SATISFACTIONS = [
  'love_it',
  'good',
  'fine',
  'regret_it',
  'returned',
] as const;
export type Satisfaction = (typeof SATISFACTIONS)[number];

export const SAVED_BUCKETS = ['maybe', 'bought', 'owned'] as const;
export type SavedBucket = (typeof SAVED_BUCKETS)[number];

export const ANALYSIS_STATUSES = [
  'pending',
  'processing',
  'completed',
  'failed',
] as const;
export type AnalysisStatus = (typeof ANALYSIS_STATUSES)[number];

export const CONFIDENCE_LABELS = ['low', 'medium', 'high'] as const;
export type ConfidenceLabel = (typeof CONFIDENCE_LABELS)[number];

/**
 * How a product fact was established. Drives the fact/estimate chips in the UI.
 * Rule 5: never present an estimate as confirmed, never invent a value.
 */
export const FACT_SOURCES = ['confirmed', 'estimated', 'unknown'] as const;
export type FactSource = (typeof FACT_SOURCES)[number];

// ---------------------------------------------------------------------------
// Signals — the only numbers the model is allowed to influence.
// All normalised 0..100. The model never produces the final score.
// ---------------------------------------------------------------------------

export const SIGNAL_KEYS = [
  'style_match',
  'wardrobe_compatibility',
  'duplication_risk',
  'expected_usage',
  'value_for_money',
  'budget_fit',
  'wardrobe_gap',
] as const;
export type SignalKey = (typeof SIGNAL_KEYS)[number];

export type AnalysisSignals = Record<SignalKey, number>;

/**
 * Which signals are actually knowable for this analysis. An unavailable signal
 * is dropped from the weighting and its weight redistributed — never silently
 * treated as zero, which would fake a penalty the data does not support.
 */
export type SignalAvailability = Record<SignalKey, boolean>;

// ---------------------------------------------------------------------------
// Product
// ---------------------------------------------------------------------------

export type ProductFactField =
  | 'name'
  | 'brand'
  | 'category'
  | 'subcategory'
  | 'price'
  | 'currency'
  | 'retailer'
  | 'material'
  | 'productUrl';

export interface ProductFacts {
  name: string | null;
  brand: string | null;
  category: Category;
  subcategory: string | null;
  price: number | null;
  currency: string | null;
  retailer: string | null;
  material: string | null;
  productUrl: string | null;
  /** Per-field provenance. A missing key means `unknown`. */
  sources: Partial<Record<ProductFactField, FactSource>>;
  priceConfidence: number;
  identityConfidence: number;
}

export interface VisualAnalysis {
  colors: string[];
  styleTags: string[];
  occasionTags: string[];
  versatilityEstimate: number;
  visualQualityConfidence: number;
}

export interface AnalysisReasoning {
  positiveFactors: string[];
  negativeFactors: string[];
  keyRisk: string | null;
  /** One short sentence shown under "BEFORE says". */
  advice: string;
  /** What the model could not establish. Surfaced verbatim, never hidden. */
  uncertainties: string[];
}

// ---------------------------------------------------------------------------
// User / wardrobe context supplied to the provider
// ---------------------------------------------------------------------------

export interface UserPreferences {
  shoppingPriorities: ShoppingPriority[];
  favoriteStyles: StylePreference[];
  budgetSensitivity: BudgetSensitivity;
  shoppingFocus: ShoppingFocus;
}

export interface UserContext {
  preferences: UserPreferences;
  locale: string;
  currency: string;
  /** Rolling median spend per category, computed server-side. Never invented. */
  categoryAverageSpend: Record<string, number>;
  analysesCount: number;
}

export interface WardrobeItemSummary {
  id: string;
  category: Category;
  subcategory: string | null;
  color: string | null;
  brand: string | null;
  price: number | null;
  styleTags: string[];
  purchaseDate: string | null;
}

export interface PurchaseHistorySummary {
  analysisId: string;
  productName: string | null;
  category: Category;
  subcategory: string | null;
  price: number | null;
  verdict: Verdict;
  action: OutcomeAction | null;
  satisfaction: Satisfaction | null;
  decidedAt: string;
}

// ---------------------------------------------------------------------------
// Scoring output
// ---------------------------------------------------------------------------

export interface FactorScore {
  key: SignalKey;
  /** Display label, e.g. "Wardrobe fit". */
  label: string;
  /** 0..10 with one decimal — the number shown in the UI. */
  value: number;
  /** Effective weight after redistribution, 0..1. Zero when excluded. */
  weight: number;
  included: boolean;
  /** Why it was excluded, when it was. Shown to the user, not swallowed. */
  excludedReason: string | null;
}

export interface ScoreResult {
  score: number;
  verdict: Verdict;
  suggestedAction: SuggestedAction;
  confidence: number;
  confidenceLabel: ConfidenceLabel;
  factors: FactorScore[];
  /** Ordered audit trail of every deterministic rule that fired. */
  appliedRules: string[];
  algorithmVersion: string;
}

// ---------------------------------------------------------------------------
// API contract — /v1
// ---------------------------------------------------------------------------

export interface AnalysisResponse {
  analysisId: string;
  status: AnalysisStatus;
  createdAt: string;
  product: ProductFacts;
  visual: VisualAnalysis;
  score: number;
  verdict: Verdict;
  confidence: number;
  confidenceLabel: ConfidenceLabel;
  factors: FactorScore[];
  reasons: {
    positive: string[];
    negative: string[];
    keyRisk: string | null;
    advice: string;
    uncertainties: string[];
  };
  suggestedAction: SuggestedAction;
  imageUrl: string | null;
  promptVersion: string;
  scoreAlgorithmVersion: string;
}

export interface UsageResponse {
  periodStart: string;
  periodEnd: string;
  used: number;
  /** null means no monthly cap (Plus). Anti-abuse limits still apply. */
  limit: number | null;
  remaining: number | null;
  isPlus: boolean;
}

export interface MeResponse {
  userId: string;
  displayName: string | null;
  preferredName: string | null;
  locale: string;
  currency: string;
  timezone: string;
  preferences: UserPreferences;
  isPlus: boolean;
  createdAt: string;
}

export const API_ERROR_CODES = [
  'unauthorized',
  'forbidden',
  'quota_exceeded',
  'rate_limited',
  'invalid_request',
  'image_too_large',
  'image_unreadable',
  'url_unreadable',
  'analysis_failed',
  'provider_unavailable',
  'content_unsupported',
  'not_found',
  'conflict',
  'internal_error',
] as const;
export type ApiErrorCode = (typeof API_ERROR_CODES)[number];

export interface ApiErrorBody {
  error: {
    code: ApiErrorCode;
    /** Safe to show a user verbatim. */
    message: string;
    requestId: string;
    retryAfterSeconds?: number;
  };
}
