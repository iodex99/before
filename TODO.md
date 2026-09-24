# TODO

What is not built, what is not verified, and what to do first.

---

## 1. Verify on a Mac — do this before anything else

Nothing Swift has been compiled, because this environment has no Swift toolchain
and no Xcode. Everything is written carefully, cross-checked by static tests, and
**unverified by a compiler**.

```bash
# 1. Pure logic first — fastest feedback, no Xcode needed.
swift test --package-path ios/BeforeKit
```

`ScoreParityTests` is the one that matters: it runs the same fixtures as the
TypeScript suite. If the Swift engine disagrees, it fails here.

```bash
# 2. Then the app.
brew install xcodegen
cp ios/Config.xcconfig.example ios/Config.xcconfig     # fill it in
make ios-project
make ios-test
```

Expect to fix compile errors on the first pass. Likely spots, in order:

- `@Observable` + `@MainActor` under strict concurrency in `AppEnvironment`,
  `AuthService`, `SubscriptionManager`, `NotificationService`, and
  `WardrobeViewModel`.
- SwiftData `#Predicate` in `ResultView.record(_:)` — predicates capturing a
  local `analysis` sometimes need the value hoisted into a `let` first.
- `SKTestSession` API surface in `SubscriptionTests` (`expireSubscription`,
  `refundTransaction`, `failureError`) varies between Xcode versions.
- `Product.SubscriptionInfo.status(for:)` returns an array; the grace-period
  loop in `refreshEntitlements()` assumes that shape.
- `MockWardrobeRepository` is an `actor`; calls from `WardrobeViewModel` are
  already `await`ed, but check the isolation warnings.

None of these are design problems; they are the ordinary cost of writing Swift
without a compiler.

---

## 2. Backend deployment

**The migrations now run and are verified.** `npm run test:migrations` applies all
eight to a throwaway Postgres 16 and runs 49 functional RLS and constraint
assertions against it. `npm run check:deno` type-checks every edge function
under the runtime that will run them.

What remains untested is the real Supabase stack, where `auth` and `storage` are
the genuine articles rather than the test bootstrap:

```bash
supabase start
supabase db reset          # applies 0001 → 0008 against real Supabase
```

### The notifications endpoint needs `--no-verify-jwt`

Apple does not send a Supabase JWT. Deploy it explicitly:

```bash
supabase functions deploy app-store-notifications --no-verify-jwt
```

Everything else deploys normally. Getting this wrong means Apple's notifications
are rejected at the gateway and you never learn about a refund.

---

## 3. Built since the first pass

For anyone reading an older copy of this file, these are no longer gaps:

- **Apple JWS verification** — real DER/X.509/JWS verification with a pinned
  root, 27 tests against a genuine OpenSSL chain including a rogue-chain
  rejection test.
- **App Store Server API** — ES256 JWT signing and subscription reconciliation.
- **App Store Server Notifications V2** — `/v1/app-store/notifications`,
  deduped, verified, and mapped to subscription state.
- **Wardrobe** — full CRUD endpoint, management UI in the Saved → Owned bucket,
  and "do you own something similar?" now writes to the server, which is what
  makes it affect a verdict at all.
- **Pending upload retry** — surfaced on Home, reusing the original idempotency
  key so a retry cannot cost a second check.
- **Notifications** — opt-in 48-hour reminder and purchase follow-up.
- **Server-side data export** — `/v1/account/export` with signed image links.
- **Deeper explanations** — Plus-gated, three fixed questions, no free text.

---

## 4. Known gaps, deliberately left

### The OpenAI and Gemini adapters have never run

They exist so the provider abstraction is real rather than notional. Written
against the documented REST shapes, never exercised against a live key.

### Subscription reconciliation is best-effort on first sync

When the App Store Server API is unreachable, `subscription-sync` stores the
verified transaction and returns `reconciled: false`. That is correct — a
transient outage must not block a purchase — but it means a subscription that
was refunded between purchase and sync is briefly recorded as active until the
notification arrives. Acceptable; worth knowing.

### No retry queue for failed notification processing

If `app-store-notifications` fails mid-write, the row is marked with
`processing_error` and Apple retries. If Apple exhausts its retries, nothing
picks it up. Apple's `getNotificationHistory` endpoint exists for exactly this
and is not wired.

### Wardrobe images

The schema, the storage bucket, and the policies all support a photo per
wardrobe item. The editor does not offer one yet — it captures category, colour,
brand, price, and tags, which is what the duplication signal actually uses.

### Local wardrobe cache can drift

`CachedWardrobeItem` is written when a server sync fails, so the answer is not
lost. Nothing reconciles those orphans on the next successful load. They are
invisible to the user and harmless, but they are litter.

### Analytics has no provider

The abstraction is provider-neutral and the default sink in release builds drops
everything. Wiring PostHog is a one-file change plus a consent decision.

---

## 5. P1 — deliberately not built

Spec §89 is explicit: *do not let P1/P2 work delay a polished P0*. These are the
P1 items, listed so the omission is a decision rather than an oversight.

- **Social Council** — "Ask the Girls" is visible and disabled on the result
  screen as a deliberate placeholder. Voting without an app install means a
  public council page, a share surface, and a moderation story; it is a product
  in its own right.
- **AI alternatives** — "find me a cheaper version" needs retailer search, which
  is a commerce surface, and §7 requires the verdict to be computed before and
  independently of one.
- **Richer shopping insights** — the Profile screen shows one derived
  observation once there are ten outcomes. More needs more data than any real
  user has yet.

## 6. P2 — not before the above

Affiliate commerce (note: no commerce signal may become an input to the score),
beauty shelf duplication, receipt import, email purchase detection, price
tracking on saved items, image embeddings for duplicate detection, cost-per-wear.

---

## 7. Before submitting to the App Store

- [ ] Download Apple Root CA G3 and set `APPLE_ROOT_CA_G3_BASE64`. **Production
      will not boot without it**, by design.
- [ ] Create the App Store Server API key and set `APPLE_ISSUER_ID`,
      `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`.
- [ ] Point the Server Notifications V2 URL at
      `/functions/v1/app-store-notifications` and deploy it with
      `--no-verify-jwt`.
- [ ] Replace the generated app icon with a designed one (`docs/ICON.md`).
- [ ] Point `TERMS_URL` and `PRIVACY_URL` at real pages. The placeholders are
      `example.invalid` on purpose — BEFORE does not invent a legal entity.
- [ ] Create the subscription products with the identifiers in
      `AppConfig.Subscription`.
- [ ] Complete the App Privacy questionnaire (`docs/PRIVACY.md` has the map).
- [ ] Verify account deletion and data export end to end on a real account.
- [ ] Re-read `docs/APP_STORE.md` for the claims to avoid.
