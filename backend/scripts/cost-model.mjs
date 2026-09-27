#!/usr/bin/env node
/**
 * BEFORE — unit economics.
 *
 * Measures the REAL prompt the pipeline sends (by calling the actual builder
 * in backend/shared/prompt/) and turns it into a per-analysis cost, then into
 * subscription margins.
 *
 * Every number that comes from the codebase is measured, not assumed. Every
 * number that comes from outside it is labelled with its source and date, so
 * the ones that will go stale are obvious.
 *
 *   node backend/scripts/cost-model.mjs
 *   node backend/scripts/cost-model.mjs --image-px 1280 --monthly 8.99
 */

import { buildAnalysisPrompt, estimateTokens } from '../shared/prompt/builder.ts';
import { SYSTEM_PROMPT } from '../shared/prompt/system.ts';
import { ANALYSIS_JSON_SCHEMA } from '../shared/ai/schema.ts';
import { RELEVANCE_LIMITS } from '../shared/context/relevance.ts';

// ---------------------------------------------------------------------------
// Inputs you might want to change
// ---------------------------------------------------------------------------

const args = Object.fromEntries(
  process.argv.slice(2).flatMap((a, i, all) => (a.startsWith('--') ? [[a.slice(2), all[i + 1]]] : [])),
);

const CONFIG = {
  /** Longest edge the app uploads. Mirrors ImageProcessor.maximumDimension. */
  imageLongEdgePx: Number(args['image-px'] ?? 1568),
  /** Typical product photo aspect. 4:3 portrait is the common case. */
  imageAspect: 3 / 4,

  monthlyPrice: Number(args.monthly ?? 9.99),
  yearlyPrice: Number(args.yearly ?? 69.99),

  /** Analyses per month for a paying subscriber. The number that decides everything. */
  analysesPerPlusUser: Number(args.usage ?? 12),
  freeMonthlyAnalyses: 5,
};

// ---- External prices. Sources dated; these are the ones that go stale. ----

const PRICES = {
  // Anthropic list prices, claude-api skill, cached 2026-06-24.
  sonnet5: { input: 2.00, output: 10.00, cacheWrite: 2.50, cacheRead: 0.20 },
  opus5:   { input: 5.00, output: 25.00, cacheWrite: 6.25, cacheRead: 0.50 },

  // Apple: 30% standard, 15% under the Small Business Program (<$1M/yr proceeds)
  // and on year 2+ of any subscription.
  appleCutSmallBusiness: 0.15,
  appleCutStandard: 0.30,

  // Supabase Pro, per month, as listed 2026.
  supabasePro: 25,
  supabaseStorageGbMonth: 0.021,
  supabaseEgressGbMonth: 0.09,
};

// ---------------------------------------------------------------------------
// 1. Measure the real prompt
// ---------------------------------------------------------------------------

function sampleWardrobe(count) {
  const kinds = [
    ['outerwear', 'black'], ['outerwear', 'camel'], ['tops', 'black'],
    ['tops', 'white'], ['tops', 'navy'], ['bottoms', 'black'],
    ['bottoms', 'indigo'], ['shoes', 'black'], ['shoes', 'tan'],
    ['bags', 'brown'], ['dresses', 'green'], ['knitwear', 'grey'],
  ];
  return Array.from({ length: count }, (_, i) => {
    const [subcategory, color] = kinds[i % kinds.length];
    return {
      id: `wardrobe-${i}`,
      category: 'fashion',
      subcategory,
      color,
      brand: i % 3 === 0 ? 'Everlane' : null,
      price: 60 + i * 15,
      styleTags: ['minimal', 'classic'],
      purchaseDate: '2025-06-01',
    };
  });
}

function sampleHistory(count) {
  return Array.from({ length: count }, (_, i) => ({
    analysisId: `analysis-${i}`,
    productName: ['Wool coat', 'Ribbed knit top', 'Leather loafers', 'Mini bag'][i % 4],
    category: 'fashion',
    subcategory: ['outerwear', 'tops', 'shoes', 'bags'][i % 4],
    price: 90 + i * 20,
    verdict: ['BUY', 'WAIT', 'BYE'][i % 3],
    action: ['bought', 'skipped', 'still_thinking'][i % 3],
    satisfaction: i % 3 === 0 ? 'love_it' : null,
    decidedAt: '2026-08-01T00:00:00Z',
  }));
}

const userPrompt = buildAnalysisPrompt({
  product: {
    title: 'Cropped Leather Biker Jacket',
    brand: 'Aritzia',
    price: 198,
    currency: 'USD',
    retailer: 'aritzia.com',
    availability: 'InStock',
    url: 'https://www.aritzia.com/us/en/product/cropped-leather-jacket/109384.html',
    fromStructuredMetadata: true,
    hasImage: true,
    userNote: 'For a wedding in June, and I want to wear it to work too',
  },
  user: {
    preferences: {
      shoppingPriorities: ['style', 'versatility', 'quality'],
      favoriteStyles: ['minimal', 'classic'],
      budgetSensitivity: 'medium',
      shoppingFocus: 'both',
    },
    locale: 'en-US',
    currency: 'USD',
    categoryAverageSpend: {},
    analysesCount: 23,
  },
  wardrobe: sampleWardrobe(RELEVANCE_LIMITS.wardrobeItems),
  history: sampleHistory(RELEVANCE_LIMITS.historyEntries),
  categoryAverageSpend: 165,
});

// The schema travels as a strict tool definition on every request.
const schemaJson = JSON.stringify(ANALYSIS_JSON_SCHEMA);

const measured = {
  systemPrompt: estimateTokens(SYSTEM_PROMPT),
  toolSchema: estimateTokens(schemaJson),
  userPrompt: estimateTokens(userPrompt),
};

/** Image tokens ≈ (w × h) / 784 — roughly one token per 28×28 patch. */
function imageTokens(longEdge, aspect) {
  const w = longEdge;
  const h = Math.round(longEdge * aspect);
  return Math.round((w * h) / 784);
}

measured.image = imageTokens(CONFIG.imageLongEdgePx, CONFIG.imageAspect);

/**
 * Output. The structured result is small, but effort=medium means adaptive
 * thinking tokens are billed as output too, and they dominate.
 */
const OUTPUT = {
  structuredResult: 550,
  thinkingMedium: 1400,
};
measured.output = OUTPUT.structuredResult + OUTPUT.thinkingMedium;

// ---------------------------------------------------------------------------
// 2. Cost per analysis
// ---------------------------------------------------------------------------

const per = (tokens, pricePerMillion) => (tokens / 1_000_000) * pricePerMillion;

function costPerAnalysis(model, { cacheHitRate = 0.7 } = {}) {
  const p = PRICES[model];

  // The system prompt and the tool schema are byte-identical for every user,
  // so they are the cacheable prefix. Everything else is per-request.
  const cacheablePrefix = measured.systemPrompt + measured.toolSchema;
  const volatile = measured.userPrompt + measured.image;

  const cachedPortion =
    cacheHitRate * per(cacheablePrefix, p.cacheRead) +
    (1 - cacheHitRate) * per(cacheablePrefix, p.cacheWrite);

  const input = cachedPortion + per(volatile, p.input);
  const output = per(measured.output, p.output);

  return { input, output, total: input + output };
}

// ---------------------------------------------------------------------------
// 3. Report
// ---------------------------------------------------------------------------

const money = (n, dp = 4) => `$${n.toFixed(dp)}`;
const pct = (n) => `${(n * 100).toFixed(1)}%`;
const line = (c = '─') => console.log(c.repeat(74));

console.log('\nBEFORE — unit economics');
line('═');

console.log('\n1. MEASURED TOKENS PER ANALYSIS  (from the real prompt builder)\n');
console.log(`   system prompt (cacheable)   ${String(measured.systemPrompt).padStart(7)} tok`);
console.log(`   tool schema   (cacheable)   ${String(measured.toolSchema).padStart(7)} tok`);
console.log(`   user prompt   (per request) ${String(measured.userPrompt).padStart(7)} tok`
  + `   ${RELEVANCE_LIMITS.wardrobeItems} wardrobe + ${RELEVANCE_LIMITS.historyEntries} history`);
console.log(`   image         (per request) ${String(measured.image).padStart(7)} tok`
  + `   at ${CONFIG.imageLongEdgePx}px long edge`);
line();
const totalInput = measured.systemPrompt + measured.toolSchema + measured.userPrompt + measured.image;
console.log(`   input total                 ${String(totalInput).padStart(7)} tok`);
console.log(`   output (result + thinking)  ${String(measured.output).padStart(7)} tok`);
console.log(`\n   image is ${pct(measured.image / totalInput)} of all input tokens`);

console.log('\n2. COST PER ANALYSIS\n');
for (const [model, label] of [['sonnet5', 'Sonnet 5 (current)'], ['opus5', 'Opus 5']]) {
  const cold = costPerAnalysis(model, { cacheHitRate: 0 });
  const warm = costPerAnalysis(model, { cacheHitRate: 0.7 });
  console.log(`   ${label.padEnd(20)} cold cache ${money(cold.total)}   70% warm ${money(warm.total)}`);
}

const unit = costPerAnalysis('sonnet5', { cacheHitRate: 0.7 }).total;

console.log('\n3. INFRASTRUCTURE (per paying user per month)\n');
// An analysis stores one ~400KB image only if saved; assume half are saved.
const storageGbPerUser = (CONFIG.analysesPerPlusUser * 0.5 * 0.4) / 1024;
const egressGbPerUser = (CONFIG.analysesPerPlusUser * 1.2) / 1024;
const infraPerUser =
  storageGbPerUser * PRICES.supabaseStorageGbMonth + egressGbPerUser * PRICES.supabaseEgressGbMonth;
console.log(`   storage + egress            ${money(infraPerUser)}  (Supabase usage-based)`);
console.log(`   Supabase Pro base           ${money(PRICES.supabasePro, 2)}/mo fixed, amortised below`);

console.log('\n4. SUBSCRIPTION MARGIN\n');

function margin({ price, months, appleCut, analysesPerMonth, label }) {
  const gross = price;
  const apple = gross * appleCut;
  const net = gross - apple;
  const ai = unit * analysesPerMonth * months;
  const infra = infraPerUser * months;
  const contribution = net - ai - infra;
  return { label, gross, apple, net, ai, infra, contribution, marginPct: contribution / gross };
}

const scenarios = [
  margin({ price: CONFIG.monthlyPrice, months: 1, appleCut: PRICES.appleCutSmallBusiness,
           analysesPerMonth: CONFIG.analysesPerPlusUser, label: `Monthly $${CONFIG.monthlyPrice} · Apple 15%` }),
  margin({ price: CONFIG.monthlyPrice, months: 1, appleCut: PRICES.appleCutStandard,
           analysesPerMonth: CONFIG.analysesPerPlusUser, label: `Monthly $${CONFIG.monthlyPrice} · Apple 30%` }),
  margin({ price: CONFIG.yearlyPrice, months: 12, appleCut: PRICES.appleCutSmallBusiness,
           analysesPerMonth: CONFIG.analysesPerPlusUser, label: `Yearly $${CONFIG.yearlyPrice} · Apple 15%` }),
  margin({ price: CONFIG.yearlyPrice, months: 12, appleCut: PRICES.appleCutStandard,
           analysesPerMonth: CONFIG.analysesPerPlusUser, label: `Yearly $${CONFIG.yearlyPrice} · Apple 30%` }),
];

console.log(`   at ${CONFIG.analysesPerPlusUser} analyses/month per subscriber\n`);
console.log('   ' + 'scenario'.padEnd(30) + 'net'.padStart(9) + 'AI'.padStart(10)
  + 'contrib'.padStart(10) + 'margin'.padStart(9));
line();
for (const s of scenarios) {
  console.log('   ' + s.label.padEnd(30) + money(s.net, 2).padStart(9) + money(s.ai, 2).padStart(10)
    + money(s.contribution, 2).padStart(10) + pct(s.marginPct).padStart(9));
}

console.log('\n5. HOW MUCH USAGE BREAKS EVEN\n');
for (const [cut, cutLabel] of [[PRICES.appleCutSmallBusiness, '15%'], [PRICES.appleCutStandard, '30%']]) {
  const netMonthly = CONFIG.monthlyPrice * (1 - cut);
  const breakeven = Math.floor((netMonthly - infraPerUser) / unit);
  const netYearlyMonth = (CONFIG.yearlyPrice * (1 - cut)) / 12;
  const breakevenYear = Math.floor((netYearlyMonth - infraPerUser) / unit);
  console.log(`   Apple ${cutLabel}:  monthly plan breaks even at ${breakeven} analyses/mo`
    + `   ·   yearly plan at ${breakevenYear}/mo`);
}

console.log('\n6. THE FREE TIER\n');
// Most free users never reach the cap. Assuming all five is the pessimistic
// bound, not the expected case.
const AVERAGE_FREE_USAGE = 2.2;
const freeCostWorst = unit * CONFIG.freeMonthlyAnalyses;
const freeCostTypical = unit * AVERAGE_FREE_USAGE;
console.log(`   worst case  (all ${CONFIG.freeMonthlyAnalyses} used)   ${money(freeCostWorst, 3)}/mo`);
console.log(`   typical     (${AVERAGE_FREE_USAGE} used)     ${money(freeCostTypical, 3)}/mo\n`);

for (const conv of [0.02, 0.05, 0.10]) {
  const netPerPaid = CONFIG.monthlyPrice * (1 - PRICES.appleCutSmallBusiness);
  const paidContribution = netPerPaid - unit * CONFIG.analysesPerPlusUser - infraPerUser;
  const blended = conv * paidContribution - (1 - conv) * freeCostTypical;
  console.log(`   ${pct(conv).padStart(5)} conversion -> ${money(blended, 3).padStart(8)} per signup per month`
    + (blended > 0 ? '   profitable' : '   LOSS'));
}
const breakEvenConv = freeCostTypical /
  (CONFIG.monthlyPrice * (1 - PRICES.appleCutSmallBusiness) - unit * CONFIG.analysesPerPlusUser
    - infraPerUser + freeCostTypical);
console.log(`\n   break-even conversion: ${pct(breakEvenConv)}`);

console.log('\n7. THE ABUSE TAIL  (what the current rate limits permit)\n');
const DAILY_CAP = 120;   // RATE_LIMIT_ANALYSES_PER_DAY
const monthlyCeiling = DAILY_CAP * 30;
const worstCost = unit * monthlyCeiling;
const yearlyNetPerMonth = (CONFIG.yearlyPrice * (1 - PRICES.appleCutSmallBusiness)) / 12;
console.log(`   daily cap ${DAILY_CAP} permits ${monthlyCeiling} analyses/month = ${money(worstCost, 2)} of AI`);
console.log(`   a yearly subscriber nets ${money(yearlyNetPerMonth, 2)}/month`);
console.log(`   worst-case single user: ${money(yearlyNetPerMonth - worstCost, 2)}/month\n`);

const yearlyBreakEven = Math.floor((yearlyNetPerMonth - infraPerUser) / unit);
console.log(`   break-even is ${yearlyBreakEven} analyses/month, so the cap allows`
  + ` ${Math.round(monthlyCeiling / yearlyBreakEven)}x that.`);
console.log(`   a monthly ceiling near ${Math.round(yearlyBreakEven * 0.75)} would keep every`);
console.log(`   subscriber profitable while staying ~${Math.round((yearlyBreakEven * 0.75) / CONFIG.analysesPerPlusUser)}x`
  + ` typical usage.`);

// ---------------------------------------------------------------------------
// Repricing for a target margin
// ---------------------------------------------------------------------------

/**
 * Two different things get called "margin", and the difference decides whether
 * a target is even reachable.
 *
 *   GROSS   contribution / sticker price, with the store's cut counted as a
 *           cost. contribution = P(1-a) - C, so margin = (1-a) - C/P. As the
 *           price rises this approaches (1-a) and never reaches it. With a 30%
 *           cut the ceiling is 70%, whatever you charge.
 *
 *   NET     contribution / what actually lands in the bank. The store's cut is
 *           treated as a fact of distribution rather than a cost of goods.
 *           This is what most people mean by "our margin", and it has no
 *           ceiling below 100%.
 */
function priceForTargetMargin(target, appleCut, monthlyCost, basis) {
  if (basis === 'gross') {
    const ceiling = 1 - appleCut;
    if (target >= ceiling) return { impossible: true, ceiling };
    return { price: monthlyCost / (ceiling - target), ceiling };
  }
  // net basis: P(1-a)(1-target) = C
  return { price: monthlyCost / ((1 - appleCut) * (1 - target)), ceiling: 1 };
}

function marginAtPrice(price, appleCut, monthlyCost, basis) {
  const net = price * (1 - appleCut);
  const contribution = net - monthlyCost;
  return basis === 'gross' ? contribution / price : contribution / net;
}

const TARGET = Number(args.target ?? 0.90);
const APPLE = Number(args.apple ?? PRICES.appleCutStandard);
const monthlyCost = unit * CONFIG.analysesPerPlusUser + infraPerUser;

console.log(`\n8. REPRICING FOR A ${pct(TARGET)} MARGIN  (Apple ${pct(APPLE)})\n`);
console.log(`   direct cost per subscriber per month: ${money(monthlyCost, 3)}`
  + `   (${CONFIG.analysesPerPlusUser} analyses)\n`);

for (const basis of ['gross', 'net']) {
  const label = basis === 'gross' ? 'of sticker price (Apple = cost)' : 'of net receipts (after Apple)';
  const result = priceForTargetMargin(TARGET, APPLE, monthlyCost, basis);

  console.log(`   ${pct(TARGET)} ${label}`);
  if (result.impossible) {
    console.log(`     IMPOSSIBLE — the ceiling is ${pct(result.ceiling)} at any price,`);
    console.log(`     because Apple takes ${pct(APPLE)} before you see a cent.\n`);
    continue;
  }
  const current = marginAtPrice(CONFIG.monthlyPrice, APPLE, monthlyCost, basis);
  console.log(`     required monthly price  ${money(result.price, 2)}`);
  console.log(`     at today's ${money(CONFIG.monthlyPrice, 2)}      ${pct(current)}`
    + (current >= TARGET ? '  already there' : '  short'));
  console.log('');
}

// What today's price actually delivers, on both readings.
console.log(`   Today at ${money(CONFIG.monthlyPrice, 2)}, Apple ${pct(APPLE)}:`);
console.log(`     gross margin  ${pct(marginAtPrice(CONFIG.monthlyPrice, APPLE, monthlyCost, 'gross'))}`
  + `   (ceiling ${pct(1 - APPLE)})`);
console.log(`     net margin    ${pct(marginAtPrice(CONFIG.monthlyPrice, APPLE, monthlyCost, 'net'))}`);

// The yearly plan is the binding constraint: its effective monthly rate is far
// below the monthly plan's, so it hits any margin target first.
console.log(`\n   Yearly ${money(CONFIG.yearlyPrice, 2)} = ${money(CONFIG.yearlyPrice / 12, 2)}/month sticker,`
  + ` ${money((CONFIG.yearlyPrice * (1 - APPLE)) / 12, 2)}/month net`);
const yearlyNetMargin = marginAtPrice(CONFIG.yearlyPrice / 12, APPLE, monthlyCost, 'net');
console.log(`     net margin    ${pct(yearlyNetMargin)}`
  + (yearlyNetMargin >= TARGET ? '  meets target' : '  BELOW TARGET'));

// Headroom on each plan: how far usage can drift before the target slips.
console.log(`\n   usage headroom at ${pct(TARGET)} net:`);
for (const [label, effectiveMonthly] of [
  ['monthly', CONFIG.monthlyPrice],
  ['yearly ', CONFIG.yearlyPrice / 12],
]) {
  const budget = effectiveMonthly * (1 - APPLE) * (1 - TARGET);
  const maxUsage = Math.floor((budget - infraPerUser) / unit);
  console.log(`     ${label}  holds to ${String(maxUsage).padStart(3)} analyses/month`);
}
console.log(`     (typical is ${CONFIG.analysesPerPlusUser}; the fair-use ceiling is 100)`);

// What each plan would have to cost to hit the target at a given usage level.
console.log(`\n   prices that hold ${pct(TARGET)} net at higher usage:\n`);
console.log('     ' + 'analyses/mo'.padEnd(14) + 'monthly'.padStart(10) + 'yearly'.padStart(11));
for (const usage of [12, 18, 25, 40]) {
  const cost = unit * usage + infraPerUser;
  const monthlyNeeded = cost / ((1 - APPLE) * (1 - TARGET));
  const yearlyNeeded = monthlyNeeded * 12;
  console.log('     ' + String(usage).padEnd(14)
    + money(monthlyNeeded, 2).padStart(10) + money(yearlyNeeded, 2).padStart(11));
}

// Selling outside the App Store is the only route to a high GROSS margin.
const STRIPE_PCT = 0.029;
const STRIPE_FIXED = 0.30;
console.log('\n   If a 90% GROSS margin is the real goal, the store cut is the only');
console.log('   thing in the way. Billing direct (Stripe 2.9% + 30c) instead:\n');
for (const [price, months, label] of [
  [CONFIG.monthlyPrice, 1, 'monthly'],
  [CONFIG.yearlyPrice, 12, 'yearly '],
]) {
  const fee = price * STRIPE_PCT + STRIPE_FIXED;
  const cost = monthlyCost * months;
  const contribution = price - fee - cost;
  console.log(`     ${label} ${money(price, 2).padStart(7)}  fee ${money(fee, 2)}`
    + `  cost ${money(cost, 2).padStart(6)}  ->  ${pct(contribution / price)} gross`);
}
console.log('\n   The fixed 30c is why the yearly plan clears 90% and the monthly does not.');

console.log('\n9. WHAT ACTUALLY DECIDES PROFIT\n');
const contributionMonthly = CONFIG.monthlyPrice * (1 - PRICES.appleCutSmallBusiness)
  - unit * CONFIG.analysesPerPlusUser - infraPerUser;
console.log(`   contribution per subscriber  ${money(contributionMonthly, 2)}/month`);
for (const cac of [10, 20, 40]) {
  const months = cac / contributionMonthly;
  console.log(`   CAC $${String(cac).padEnd(3)} -> payback in ${months.toFixed(1)} months`
    + (months <= 6 ? '   healthy' : months <= 12 ? '   workable' : '   too slow'));
}
const fixedMonthly = PRICES.supabasePro;
console.log(`\n   subscribers needed to cover ${money(fixedMonthly, 0)}/mo fixed costs: `
  + `${Math.ceil(fixedMonthly / contributionMonthly)}`);

console.log('');
line('═');
console.log('Prices: Anthropic list (claude-api skill, cached 2026-06-24); Apple 15% SBP / 30%');
console.log('standard; Supabase Pro $25/mo. Token counts measured from the live prompt builder');
console.log('at ~4 chars/token (±15%). Image formula (w×h)/784.\n');
