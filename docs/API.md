# API — `/v1`

Every endpoint is a Supabase Edge Function. Base URL:

```
https://<project>.supabase.co/functions/v1
```

All routes require `Authorization: Bearer <supabase-jwt>` and `apikey: <anon-key>`.
The JWT is verified against Supabase, not merely decoded.

Responses are JSON. Enums are the exact strings below — never free text.

---

## Errors

Every failure has the same shape and a message written for a person.

```json
{
  "error": {
    "code": "quota_exceeded",
    "message": "You've used all your checks this month.",
    "requestId": "b0c1…",
    "retryAfterSeconds": 60
  }
}
```

| Code | Status | Client should |
| --- | --- | --- |
| `unauthorized` | 401 | refresh the session, then sign in |
| `forbidden` | 403 | show the message |
| `quota_exceeded` | **402** | show the paywall |
| `fair_use_exceeded` | 429 | explain and stop — do NOT upsell, they already pay |
| `rate_limited` | 429 | back off using `retryAfterSeconds` |
| `invalid_request` | 400 | fix the request |
| `image_too_large` | 413 | re-process the image |
| `image_unreadable` | 400 | ask for a different photo |
| `url_unreadable` | 422 | offer the screenshot path |
| `analysis_failed` | 502 | offer retry |
| `provider_unavailable` | 503 | offer retry |
| `content_unsupported` | 422 | ask for a photo of the product |
| `not_found` | 404 | — |
| `conflict` | 409 | idempotency key reused with a different body |
| `internal_error` | 500 | offer retry |

`402` is deliberately distinct from `429`: one is an offer, the other is a wait.

---

## `POST /v1/analyses` → `analyze-purchase`

The core endpoint. Costs one quota unit **on success only**.

**Headers:** `Idempotency-Key: <uuid>` — strongly recommended. A repeat returns
the existing analysis instead of running a second one. A repeat with a *different*
body is a `409`.

```jsonc
{
  "imagePath": "a1b2.../c3d4.jpg",   // storage path, uploaded first (see below)
  "productUrl": "https://shop.example.com/p/123",
  "userNote": "for a wedding in June",
  "inputType": "photo",              // photo | camera | screenshot | url | share_extension
  "categoryHint": "fashion",         // narrows the wardrobe slice sent to the model
  "subcategoryHint": "outerwear"
}
```

At least one of `imagePath` or `productUrl` is required. Supplying both is best:
the page gives facts, the image gives context.

### Uploading the image first

```
POST {SUPABASE_URL}/storage/v1/object/analyses/<user-id>/<uuid>.jpg
Content-Type: image/jpeg
Authorization: Bearer <jwt>
```

The `<user-id>/` prefix is enforced by a storage policy — a client cannot write
outside its own folder. See DECISIONS.md §9 for why this is two steps.

### Response `200`

```jsonc
{
  "analysisId": "uuid",
  "status": "completed",
  "createdAt": "2026-09-24T10:30:00.123Z",
  "product": {
    "name": "Cropped leather jacket",
    "brand": null,
    "category": "fashion",
    "subcategory": "outerwear",
    "price": 198,
    "currency": "USD",
    "retailer": "shop.example.com",
    "material": "Leather",
    "productUrl": "https://shop.example.com/p/123",
    "sources": { "price": "confirmed", "brand": "unknown", "material": "estimated" },
    "priceConfidence": 0.95,
    "identityConfidence": 0.6
  },
  "visual": {
    "colors": ["black"],
    "styleTags": ["minimal", "classic"],
    "occasionTags": ["everyday"],
    "versatilityEstimate": 84,
    "visualQualityConfidence": 0.7
  },
  "score": 78,
  "verdict": "WAIT",                  // BUY | WAIT | BYE
  "confidence": 0.74,
  "confidenceLabel": "medium",        // low | medium | high
  "factors": [
    {
      "key": "wardrobe_compatibility",
      "value": 9.0,                   // 0..10 as displayed; already inverted for duplication
      "weight": 0.25,                 // effective weight after redistribution
      "included": true,
      "excludedReason": null
    }
  ],
  "reasons": {
    "positive": ["Works with the neutrals that make up most of what you own"],
    "negative": ["You own a black moto jacket that covers a similar occasion"],
    "keyRisk": "It overlaps with a jacket you already reach for.",
    "advice": "Wait 48 hours. If you are still thinking about it, come back.",
    "uncertainties": ["Brand not confidently identified"]
  },
  "suggestedAction": "WAIT_48_HOURS",
  "imageUrl": "https://…signed…",     // short-lived, private bucket
  "promptVersion": "purchase_analysis_v1",
  "scoreAlgorithmVersion": "score_v1"
}
```

**`sources`** is how the UI distinguishes a confirmed fact from an estimate from
an unknown. `confirmed` means it came from parsed page metadata.

**`factors`** always contains all seven signals. An excluded one carries
`included: false` and a human-readable `excludedReason`, so the UI can say
"BEFORE doesn't know your wardrobe well enough yet" rather than silently showing
six rows.

**`suggestedAction`** is derived deterministically from the verdict and the rules
that fired — never free-form model text:
`BUY_IT` · `WAIT_48_HOURS` · `CHECK_WARDROBE_FIRST` · `WAIT_FOR_SALE` · `SKIP_IT`

An idempotent replay carries `Idempotent-Replay: true`.

---

## `GET /v1/analyses/:id` → `analysis`

Reopen an analysis with its product, factors, saved bucket, and outcome. Returns
`404` for an id that is not yours (RLS makes it invisible; the check makes it a
clean 404).

## `POST /v1/analyses/:id/outcome` → `analysis`

```jsonc
{
  "action": "skipped",          // bought | skipped | still_thinking  (required)
  "purchaseDate": "2026-09-24",
  "actualPrice": 198,
  "currency": "USD",
  "returned": false,
  "satisfaction": "love_it",    // love_it | good | fine | regret_it | returned
  "notes": "…"
}
```

`satisfaction` and `returned` require `action: "bought"` — enforced at the
endpoint *and* by a check constraint.

Marking `bought` moves the saved item to the Bought bucket. Marking `bought`
without a satisfaction schedules a follow-up 14 days out (delivered only if
notification permission was granted).

→ `{ "recorded": true, "action": "skipped" }`

---

## `GET /v1/me` · `PATCH /v1/me` → `me`

```jsonc
{
  "userId": "uuid",
  "displayName": "Sam Rivera",     // from Apple, first authorisation only
  "preferredName": null,
  "locale": "en-US",
  "currency": "USD",
  "timezone": "America/New_York",
  "preferences": {
    "shoppingPriorities": ["style", "versatility"],   // max 3
    "favoriteStyles": ["minimal", "classic"],         // max 5
    "budgetSensitivity": "medium",
    "shoppingFocus": "both"
  },
  "isPlus": true,
  "createdAt": "2026-01-01T00:00:00Z"
}
```

`PATCH` accepts any subset. Unknown enum members are dropped rather than
rejected, so an older client cannot lock itself out of its own settings.

`isPlus` is derived from verified App Store transactions by `is_plus()`. There is
no request that can set it.

---

## `GET /v1/usage` → `usage`

```jsonc
{
  "periodStart": "2026-09-01T04:00:00Z",   // the USER'S calendar month
  "periodEnd": "2026-10-01T04:00:00Z",
  "used": 1,
  "limit": 5,             // null for Plus — no plan limit
  "remaining": 4,         // null for Plus
  "isPlus": false,
  "fairUseLimit": null,   // 100 for Plus; see docs/LIMITS.md
  "fairUseRemaining": null
}
```

The window is computed in the user's own timezone — in UTC, someone in Los
Angeles loses most of the last day of every month.

`fairUseLimit` / `fairUseRemaining` are populated only for Plus. The app shows
nothing until the remainder drops below ten: a running counter on a plan sold as
"unlimited" reads as a lie.

---

## `POST /v1/product-metadata` → `product-metadata`

Reads what a product page says about itself, for the paste-a-link preview.
Cached for 7 days across all users.

```jsonc
{ "url": "https://shop.example.com/p/123" }
```

→

```jsonc
{
  "url": "https://shop.example.com/p/123",   // normalised, tracking params stripped
  "metadata": {
    "title": "Cropped Leather Jacket",
    "brand": "Example",
    "price": 198,
    "currency": "USD",
    "imageUrl": "https://cdn…",
    "retailer": "shop.example.com",
    "structured": true    // false when it came from a <title> — not a fact
  },
  "cached": false
}
```

`422 url_unreadable` is a **normal outcome**, not a bug: some shops block
automated readers. The client falls back to a screenshot. BEFORE does not try to
route around a site's access controls.

Private and loopback addresses are refused (SSRF guard).

---

## `GET/POST/PATCH/DELETE /v1/wardrobe` → `wardrobe`

What the user owns. Wardrobe compatibility is the heaviest signal in the score
at 25%, and duplication is what lets BEFORE say BYE — so an item only matters
once it reaches this table.

```jsonc
// GET /v1/wardrobe
{
  "items": [
    {
      "id": "uuid",
      "category": "fashion",
      "subcategory": "outerwear",
      "color": "black",
      "brand": null,
      "price": 210,
      "currency": "USD",
      "purchaseDate": "2025-11-02",
      "styleTags": ["minimal", "edgy"],
      "notes": null,
      "imagePath": null,
      "source": "analysis",      // manual | analysis | import
      "createdAt": "…", "updatedAt": "…"
    }
  ],
  "limit": 25                    // null for Plus
}
```

`POST` takes the same shape without `id`. A price requires a currency — the
endpoint and a check constraint both enforce it, because a price nobody can
format is worse than no price.

Hitting the free cap returns **402** `quota_exceeded`, not an error: the answer
is an upgrade offer.

`DELETE /v1/wardrobe/:id` removes the storage object before the row, because a
row cascade cannot reach object storage.

---

## `POST /v1/analyses/:id/explain` → `explain` · **Plus**

Deeper explanation of a verdict (spec §35). Deliberately **not** a chat.

```jsonc
{ "angle": "why_this_verdict" }
// why_this_verdict | what_would_change_it | how_it_fits
```

→ `{ "angle": "why_this_verdict", "explanation": "…" }`

The angle comes from a closed set; there is no free-text question field, because
Rule 1 says BEFORE is not a general AI assistant and §8 rules out a chat surface.

The model is given only the analysis it already produced — no image, no metadata
fetch, no wardrobe — so it has nothing to invent a new fact from. The response
goes through the same safety scan as the main analysis.

A free user gets **403**. The verdict, the score, and the full reasoning are all
free; this is extra depth on top, not a gate on result quality.

---

## `GET /v1/account/export` → `account-export`

Everything BEFORE holds about the caller (spec §43), as a downloadable JSON
document.

Backed by `export_user_data()`, which is `security invoker` — so RLS does the
filtering and the endpoint adds none of its own.

Image bytes are not inlined. Each image appears as a path plus a signed URL that
**expires after one hour**: an export file that granted permanent access to
someone's wardrobe photos would be a worse privacy outcome than no export.

---

## `POST /v1/subscription/sync` → `subscription-sync`

The client reports a StoreKit transaction. **Nothing it says is trusted.**

```jsonc
{
  "signedTransaction": "<JWS>",   // the only field with any authority
  "productId": "before.plus.yearly",      // advisory, logging only
  "originalTransactionId": "2000000…",    // advisory, logging only
  "environment": "production"             // advisory, logging only
}
```

What happens:

1. The JWS is verified against the pinned Apple Root CA G3 — full certificate
   chain, validity windows, ES256 signature.
2. The bundle id must be ours. A validly-signed transaction from any other App
   Store app would otherwise verify and could be replayed to grant Plus.
3. A sandbox transaction against `APP_ENV=production` is refused.
4. When App Store Server API credentials are configured, Apple is asked for the
   current state, and *that* is stored — renewals, refunds, and revocations are
   only visible this way.

Every stored value comes from the verified payload. A verification failure is
**403**.

→

```jsonc
{
  "isPlus": true,
  "status": "active",
  "environment": "production",
  "expirationDate": "2027-09-01T00:00:00Z",
  "reconciled": true    // false when Apple was unreachable; retry later
}
```

---

## `POST /v1/app-store/notifications` → `app-store-notifications`

**Unauthenticated — Apple calls it.** The JWS signature is the entire
authentication, which is why it is verified before anything else happens and why
a bad signature returns **401** rather than 200.

```jsonc
{ "signedPayload": "<JWS>" }
```

Handled types: `SUBSCRIBED`, `DID_RENEW`, `OFFER_REDEEMED`, `RENEWAL_EXTENDED`
→ active · `DID_FAIL_TO_RENEW` → grace period or billing retry ·
`GRACE_PERIOD_EXPIRED` → billing retry · `EXPIRED` · `REFUND` · `REVOKE`.

Anything else is recorded and changes nothing, because guessing at an unknown
notification's meaning is worse than leaving state alone.

Apple retries until it gets a 2xx, so the same `notificationUUID` arrives more
than once by design; a unique index dedupes it.

Deploy with `--no-verify-jwt` — Apple does not send a Supabase JWT.

→ `{ "received": true, "applied": true, "notificationType": "DID_RENEW" }`

---

## `POST /v1/account/delete` → `account-delete`

```jsonc
{ "confirmation": "DELETE" }
```

Anything else is a `400`. Deletion order and scope: `docs/PRIVACY.md`.

→

```jsonc
{
  "deleted": true,
  "details": { "storage_objects_removed": 12, "analyses_removed": 34 },
  "subscriptionNotice": "Your BEFORE data has been deleted. If you have an active subscription, cancel it in Settings on your device — only Apple can do that."
}
```

BEFORE **cannot** cancel an App Store subscription and does not imply otherwise.

---

## Versioning

- Endpoints are versioned. There are no unversioned production routes.
- Every completed analysis stores `promptVersion` and `scoreAlgorithmVersion`, so
  changing either never silently redefines what an old score meant.
- Adding an enum member is backwards-compatible: clients drop what they do not
  recognise. Removing or renaming one is a breaking change and needs `/v2`.
