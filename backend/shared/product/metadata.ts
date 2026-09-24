/**
 * BEFORE — product page metadata.
 *
 * Reads what a page volunteers about itself: JSON-LD Product, Open Graph, then
 * the plain <title>. That is the whole scope.
 *
 * Deliberately NOT here: headless browsers, rotating user agents, cookie
 * replay, or anything else aimed at defeating a site's own access controls. If
 * a page will not tell us what it is, the answer is "we couldn't read the
 * product page, send a screenshot" — not a workaround. Anything we cannot read
 * stays null and is reported as unknown, never guessed (Rule 5).
 *
 * The parsing half is pure and tested; the fetching half is a thin wrapper.
 */

export interface ProductMetadata {
  title: string | null;
  brand: string | null;
  price: number | null;
  currency: string | null;
  availability: string | null;
  imageUrl: string | null;
  retailer: string | null;
  /** True when anything came from JSON-LD or Open Graph rather than the title. */
  structured: boolean;
}

export const EMPTY_METADATA: ProductMetadata = {
  title: null,
  brand: null,
  price: null,
  currency: null,
  availability: null,
  imageUrl: null,
  retailer: null,
  structured: false,
};

const MAX_HTML_BYTES = 512 * 1024;
const FETCH_TIMEOUT_MS = 8000;

export class UrlUnreadableError extends Error {
  readonly reason: string;
  constructor(reason: string) {
    super(`product page could not be read: ${reason}`);
    this.name = 'UrlUnreadableError';
    this.reason = reason;
  }
}

// ---------------------------------------------------------------------------
// URL handling
// ---------------------------------------------------------------------------

/**
 * Accept only public http(s) URLs.
 *
 * The private-range check is an SSRF guard: this endpoint fetches a URL chosen
 * by the caller, from inside our infrastructure. Without it, a crafted link can
 * make the server read its own metadata service.
 */
export function normaliseProductUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    throw new UrlUnreadableError('not a valid URL');
  }

  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new UrlUnreadableError('only http and https are supported');
  }

  const host = url.hostname.toLowerCase();
  const isPrivate =
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.local') ||
    host.endsWith('.internal') ||
    /^127\./.test(host) ||
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
    /^169\.254\./.test(host) ||
    host === '0.0.0.0' ||
    host === '::1' ||
    host === '[::1]';

  if (isPrivate) throw new UrlUnreadableError('that address is not reachable');

  // Tracking parameters change nothing about the product and would defeat the
  // metadata cache, so they are stripped.
  for (const key of [...url.searchParams.keys()]) {
    if (/^(utm_|fbclid|gclid|mc_|ref|_branch)/i.test(key)) url.searchParams.delete(key);
  }
  url.hash = '';
  return url;
}

export function retailerFromUrl(url: URL): string {
  return url.hostname.replace(/^www\./i, '');
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function decodeEntities(text: string): string {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)));
}

function clean(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const text = decodeEntities(value).replace(/\s+/g, ' ').trim();
  return text === '' ? null : text.slice(0, 200);
}

function toPrice(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) return value;
  if (typeof value !== 'string') return null;
  // Take the first number that looks like a price, ignoring thousands separators.
  const match = value.replace(/[\s,](?=\d{3}\b)/g, '').match(/\d+(?:\.\d{1,2})?/);
  if (!match) return null;
  const parsed = Number.parseFloat(match[0]);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function toCurrency(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const code = value.trim().toUpperCase();
  return /^[A-Z]{3}$/.test(code) ? code : null;
}

/** Pull every <script type="application/ld+json"> payload out of the HTML. */
function jsonLdBlocks(html: string): unknown[] {
  const blocks: unknown[] = [];
  const pattern = /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(html)) !== null) {
    const body = match[1].trim();
    if (!body) continue;
    try {
      blocks.push(JSON.parse(body));
    } catch {
      // A malformed block is ignored; the rest of the page may still be readable.
    }
  }
  return blocks;
}

/** Walk JSON-LD, which is routinely nested inside @graph or arrays. */
function findProductNode(node: unknown, depth = 0): Record<string, unknown> | null {
  if (depth > 6 || node === null || typeof node !== 'object') return null;

  if (Array.isArray(node)) {
    for (const entry of node) {
      const found = findProductNode(entry, depth + 1);
      if (found) return found;
    }
    return null;
  }

  const record = node as Record<string, unknown>;
  const type = record['@type'];
  const types = Array.isArray(type) ? type : [type];
  if (types.some((t) => typeof t === 'string' && t.toLowerCase() === 'product')) {
    return record;
  }

  for (const key of ['@graph', 'mainEntity', 'itemListElement', 'hasVariant']) {
    const found = findProductNode(record[key], depth + 1);
    if (found) return found;
  }
  return null;
}

function firstOffer(product: Record<string, unknown>, depth = 0): Record<string, unknown> | null {
  if (depth > 3) return null;
  const offers = product.offers;
  if (!offers) return null;

  if (Array.isArray(offers)) {
    return (offers.find((o) => o && typeof o === 'object') as Record<string, unknown>) ?? null;
  }

  if (typeof offers === 'object') {
    const record = offers as Record<string, unknown>;
    // An AggregateOffer may nest concrete offers. Prefer one of those, but fall
    // back to the aggregate itself — it carries lowPrice, and its nested list
    // is often present but empty.
    return firstOffer(record, depth + 1) ?? record;
  }
  return null;
}

function metaContent(html: string, property: string): string | null {
  const patterns = [
    new RegExp(
      `<meta[^>]+(?:property|name)=["']${property}["'][^>]*content=["']([^"']*)["']`,
      'i',
    ),
    new RegExp(
      `<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']${property}["']`,
      'i',
    ),
  ];
  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (match?.[1]) return clean(match[1]);
  }
  return null;
}

/**
 * Extract what the page states about itself.
 *
 * Order of trust: JSON-LD Product (a deliberate machine-readable claim), then
 * Open Graph, then <title>. A field is only marked `structured` when it came
 * from one of the first two — a <title> is not a price and never becomes one.
 */
export function extractProductMetadata(html: string, url: URL): ProductMetadata {
  const result: ProductMetadata = { ...EMPTY_METADATA, retailer: retailerFromUrl(url) };

  for (const block of jsonLdBlocks(html)) {
    const product = findProductNode(block);
    if (!product) continue;

    result.title = result.title ?? clean(product.name);
    result.imageUrl =
      result.imageUrl ??
      clean(Array.isArray(product.image) ? product.image[0] : product.image);

    const brand = product.brand;
    if (typeof brand === 'string') {
      result.brand = result.brand ?? clean(brand);
    } else if (brand && typeof brand === 'object') {
      result.brand = result.brand ?? clean((brand as Record<string, unknown>).name);
    }

    const offer = firstOffer(product);
    if (offer) {
      result.price = result.price ?? toPrice(offer.price ?? offer.lowPrice);
      result.currency = result.currency ?? toCurrency(offer.priceCurrency);
      const availability = clean(offer.availability);
      if (availability) {
        result.availability = result.availability ?? availability.replace(/^.*\//, '');
      }
    }

    result.structured = true;
    if (result.title && result.price) break;
  }

  const ogTitle = metaContent(html, 'og:title');
  const ogImage = metaContent(html, 'og:image');
  const ogPrice = metaContent(html, 'product:price:amount') ?? metaContent(html, 'og:price:amount');
  const ogCurrency =
    metaContent(html, 'product:price:currency') ?? metaContent(html, 'og:price:currency');
  const ogBrand = metaContent(html, 'product:brand') ?? metaContent(html, 'og:brand');
  const ogAvailability = metaContent(html, 'product:availability');
  const ogSite = metaContent(html, 'og:site_name');

  if (ogTitle || ogPrice || ogBrand) result.structured = true;

  result.title = result.title ?? ogTitle;
  result.imageUrl = result.imageUrl ?? ogImage;
  result.price = result.price ?? toPrice(ogPrice);
  result.currency = result.currency ?? toCurrency(ogCurrency);
  result.brand = result.brand ?? ogBrand;
  result.availability = result.availability ?? ogAvailability;
  if (ogSite) result.retailer = ogSite;

  if (!result.title) {
    const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    // A <title> is a page name, not a product claim, so it does not set
    // `structured` — downstream it is treated as an estimate, never a fact.
    result.title = match?.[1] ? clean(match[1]) : null;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

export interface FetchOptions {
  timeoutMs?: number;
  maxBytes?: number;
  /** Injected in tests. */
  fetchImpl?: typeof fetch;
  userAgent?: string;
}

/**
 * Fetch a product page and extract its metadata.
 *
 * Identifies itself honestly, follows redirects, and gives up quickly. A 403 or
 * a bot wall is a normal outcome, not something to route around: the caller
 * falls back to the image.
 */
export async function fetchProductMetadata(
  rawUrl: string,
  options: FetchOptions = {},
): Promise<{ url: URL; metadata: ProductMetadata }> {
  const url = normaliseProductUrl(rawUrl);
  const doFetch = options.fetchImpl ?? fetch;
  const maxBytes = options.maxBytes ?? MAX_HTML_BYTES;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? FETCH_TIMEOUT_MS);

  let response: Response;
  try {
    response = await doFetch(url.toString(), {
      method: 'GET',
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        'user-agent':
          options.userAgent ?? 'BEFORE/1.0 (+https://example.invalid/bot; product metadata)',
        accept: 'text/html,application/xhtml+xml',
        'accept-language': 'en',
      },
    });
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new UrlUnreadableError('the page took too long to respond');
    }
    throw new UrlUnreadableError('the page could not be reached');
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    throw new UrlUnreadableError(`the page returned ${response.status}`);
  }

  const contentType = response.headers.get('content-type') ?? '';
  if (!/text\/html|application\/xhtml/i.test(contentType)) {
    throw new UrlUnreadableError('that link is not a web page');
  }

  const html = await readCapped(response, maxBytes);
  return { url, metadata: extractProductMetadata(html, url) };
}

/** Read at most `maxBytes`; product metadata always lives in the <head>. */
async function readCapped(response: Response, maxBytes: number): Promise<string> {
  if (!response.body) return await response.text();

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let html = '';
  let bytes = 0;

  try {
    while (bytes < maxBytes) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      html += decoder.decode(value, { stream: true });
    }
  } finally {
    await reader.cancel().catch(() => {});
  }

  return html;
}
