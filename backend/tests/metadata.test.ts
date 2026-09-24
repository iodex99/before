/**
 * Product page parsing and the SSRF guard on the URL endpoint.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  UrlUnreadableError,
  extractProductMetadata,
  fetchProductMetadata,
  normaliseProductUrl,
  retailerFromUrl,
} from '../shared/product/metadata.ts';

const url = new URL('https://shop.example.com/products/leather-jacket');

// ---------------------------------------------------------------------------
// URL safety
// ---------------------------------------------------------------------------

test('public https URLs are accepted', () => {
  assert.equal(
    normaliseProductUrl('https://shop.example.com/p/1').toString(),
    'https://shop.example.com/p/1',
  );
});

test('SSRF: private and loopback addresses are refused', () => {
  const blocked = [
    'http://localhost/admin',
    'http://127.0.0.1/',
    'http://10.0.0.5/',
    'http://192.168.1.1/',
    'http://172.16.0.1/',
    'http://169.254.169.254/latest/meta-data/',
    'http://0.0.0.0/',
    'http://service.internal/',
  ];
  for (const candidate of blocked) {
    assert.throws(() => normaliseProductUrl(candidate), UrlUnreadableError, `should refuse ${candidate}`);
  }
});

test('non-http schemes are refused', () => {
  for (const candidate of ['file:///etc/passwd', 'ftp://example.com/x', 'javascript:alert(1)']) {
    assert.throws(() => normaliseProductUrl(candidate), UrlUnreadableError);
  }
});

test('malformed URLs are refused', () => {
  assert.throws(() => normaliseProductUrl('not a url'), UrlUnreadableError);
  assert.throws(() => normaliseProductUrl(''), UrlUnreadableError);
});

test('tracking parameters are stripped but real ones are kept', () => {
  const result = normaliseProductUrl(
    'https://shop.example.com/p?utm_source=ig&fbclid=abc&color=black&size=M#reviews',
  );
  assert.equal(result.searchParams.get('color'), 'black');
  assert.equal(result.searchParams.get('size'), 'M');
  assert.equal(result.searchParams.get('utm_source'), null);
  assert.equal(result.searchParams.get('fbclid'), null);
  assert.equal(result.hash, '');
});

test('the retailer is the bare hostname', () => {
  assert.equal(retailerFromUrl(new URL('https://www.aritzia.com/p/1')), 'aritzia.com');
});

// ---------------------------------------------------------------------------
// JSON-LD
// ---------------------------------------------------------------------------

test('a JSON-LD Product is read', () => {
  const html = `<html><head><script type="application/ld+json">${JSON.stringify({
    '@context': 'https://schema.org',
    '@type': 'Product',
    name: 'Cropped Leather Jacket',
    brand: { '@type': 'Brand', name: 'Aritzia' },
    image: ['https://cdn.example.com/a.jpg'],
    offers: {
      '@type': 'Offer',
      price: '198.00',
      priceCurrency: 'USD',
      availability: 'https://schema.org/InStock',
    },
  })}</script></head><body></body></html>`;

  const meta = extractProductMetadata(html, url);
  assert.equal(meta.title, 'Cropped Leather Jacket');
  assert.equal(meta.brand, 'Aritzia');
  assert.equal(meta.price, 198);
  assert.equal(meta.currency, 'USD');
  assert.equal(meta.availability, 'InStock');
  assert.equal(meta.imageUrl, 'https://cdn.example.com/a.jpg');
  assert.equal(meta.structured, true);
});

test('a Product nested in @graph is found', () => {
  const html = `<script type="application/ld+json">${JSON.stringify({
    '@graph': [
      { '@type': 'WebSite', name: 'Shop' },
      { '@type': 'Product', name: 'Loafers', offers: { price: 145, priceCurrency: 'GBP' } },
    ],
  })}</script>`;
  const meta = extractProductMetadata(html, url);
  assert.equal(meta.title, 'Loafers');
  assert.equal(meta.price, 145);
  assert.equal(meta.currency, 'GBP');
});

test('an AggregateOffer resolves to a price', () => {
  const html = `<script type="application/ld+json">${JSON.stringify({
    '@type': 'Product',
    name: 'Coat',
    offers: { '@type': 'AggregateOffer', lowPrice: '240.00', priceCurrency: 'EUR', offers: [] },
  })}</script>`;
  const meta = extractProductMetadata(html, url);
  assert.equal(meta.price, 240);
});

test('malformed JSON-LD does not break the rest of the page', () => {
  const html = `
    <script type="application/ld+json">{ this is not json }</script>
    <meta property="og:title" content="Fallback Title">`;
  const meta = extractProductMetadata(html, url);
  assert.equal(meta.title, 'Fallback Title');
});

// ---------------------------------------------------------------------------
// Open Graph and title fallback
// ---------------------------------------------------------------------------

test('Open Graph tags are read in either attribute order', () => {
  const html = `
    <meta property="og:title" content="Wool Coat">
    <meta content="240.00" property="product:price:amount">
    <meta property="product:price:currency" content="usd">
    <meta property="og:site_name" content="Example Shop">`;
  const meta = extractProductMetadata(html, url);
  assert.equal(meta.title, 'Wool Coat');
  assert.equal(meta.price, 240);
  assert.equal(meta.currency, 'USD');
  assert.equal(meta.retailer, 'Example Shop');
  assert.equal(meta.structured, true);
});

test('a bare <title> is used but is NOT treated as structured data', () => {
  const meta = extractProductMetadata('<html><head><title>Some Shop | Jacket</title></head></html>', url);
  assert.equal(meta.title, 'Some Shop | Jacket');
  assert.equal(
    meta.structured,
    false,
    'a page title is not a product claim — marking it structured would let it be shown as a confirmed fact',
  );
  assert.equal(meta.price, null);
});

test('an unparseable page yields nulls rather than guesses', () => {
  const meta = extractProductMetadata('<html><body>Hello</body></html>', url);
  assert.equal(meta.title, null);
  assert.equal(meta.price, null);
  assert.equal(meta.brand, null);
  assert.equal(meta.structured, false);
});

test('HTML entities are decoded', () => {
  const meta = extractProductMetadata('<title>Dolce &amp; Gabbana &#39;90s Jacket</title>', url);
  assert.equal(meta.title, "Dolce & Gabbana '90s Jacket");
});

test('prices with separators and symbols parse correctly', () => {
  const cases: Array<[string, number | null]> = [
    ['1,299.00', 1299],
    ['$198', 198],
    ['198.50 USD', 198.5],
    ['free', null],
    ['0', null],
  ];
  for (const [raw, expected] of cases) {
    const html = `<meta property="product:price:amount" content="${raw}">`;
    assert.equal(extractProductMetadata(html, url).price, expected, `price "${raw}"`);
  }
});

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

function stubFetch(body: string, init: { status?: number; contentType?: string } = {}) {
  return async () =>
    new Response(body, {
      status: init.status ?? 200,
      headers: { 'content-type': init.contentType ?? 'text/html; charset=utf-8' },
    });
}

test('a successful fetch returns parsed metadata', async () => {
  const { metadata } = await fetchProductMetadata('https://shop.example.com/p/1', {
    fetchImpl: stubFetch('<title>Nice Jacket</title>') as unknown as typeof fetch,
  });
  assert.equal(metadata.title, 'Nice Jacket');
});

test('a bot wall (403) surfaces as unreadable rather than being worked around', async () => {
  await assert.rejects(
    () =>
      fetchProductMetadata('https://shop.example.com/p/1', {
        fetchImpl: stubFetch('Forbidden', { status: 403 }) as unknown as typeof fetch,
      }),
    (error: unknown) => error instanceof UrlUnreadableError && /403/.test(error.reason),
  );
});

test('a non-HTML response is refused', async () => {
  await assert.rejects(
    () =>
      fetchProductMetadata('https://shop.example.com/a.pdf', {
        fetchImpl: stubFetch('%PDF', { contentType: 'application/pdf' }) as unknown as typeof fetch,
      }),
    UrlUnreadableError,
  );
});

test('a network failure surfaces as unreadable', async () => {
  await assert.rejects(
    () =>
      fetchProductMetadata('https://shop.example.com/p/1', {
        fetchImpl: (async () => {
          throw new TypeError('connection refused');
        }) as unknown as typeof fetch,
      }),
    UrlUnreadableError,
  );
});

test('an oversized page is read only up to the cap', async () => {
  const huge = '<title>Capped</title>' + 'x'.repeat(2_000_000);
  const { metadata } = await fetchProductMetadata('https://shop.example.com/p/1', {
    maxBytes: 4096,
    fetchImpl: stubFetch(huge) as unknown as typeof fetch,
  });
  assert.equal(metadata.title, 'Capped');
});
