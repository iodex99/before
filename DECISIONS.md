# DECISIONS

Engineering choices the specification left open, and why they went the way they
did. Each entry names the trade-off, because the alternative usually had a real
case for it.

---

## 1. Minimum iOS version: **17.0**

iOS 17 is the floor for every API this app is built on: SwiftData, `@Observable`,
`PhotosPicker`, `ShareLink`, `ContentUnavailableView`, and the StoreKit 2
subscription-status APIs. Targeting 16 would mean hand-rolling observation and a
second persistence path for one release's worth of devices.

**Trade-off:** a small tail of older devices. For a new consumer app launching in
2026 into US/UK/EU markets, that tail is well under a few percent and not worth
two code paths through the most important screens.

---

## 2. The score engine exists twice, and a shared fixture suite proves they agree

The backend is authoritative — every score a user sees is computed server-side
from validated signals. But the app also needs to score locally for mock mode and
offline previews.

Rather than let the two drift, both implementations run the **same fixture file**
(`backend/shared/fixtures/score-cases.json`):

- `backend/tests/score-engine.test.ts` (Node)
- `ios/BeforeKit/Tests/BeforeKitTests/ScoreParityTests.swift` (Swift)

The expected values in that file were **derived by hand** from
`scoring/weights.ts`, not captured from engine output — otherwise the suite would
just bless whatever the engine happens to do.

There is also `backend/tests/swift-parity-contract.test.ts`, which compares the
two sources as text: enum wire values, weights, thresholds, override constants,
rule identifiers, and exclusion strings. It runs without a Swift toolchain, so
drift is caught on any machine, not only on a Mac.

**Trade-off:** two implementations of one algorithm is duplication. The shared
fixtures plus the contract test make the duplication safe, and the alternative
(no local scoring at all) would mean no offline previews and no mock mode.

---

## 3. Backend logic is runtime-neutral TypeScript, not Deno-only

`backend/shared/` uses no `Deno.*`, no `process.*`, and no `node:` imports, and
its relative imports carry `.ts` extensions. Both Deno (Supabase Edge Functions)
and Node 22's native type stripping can load it unchanged.

That is what makes `npm run test:backend` work on any machine with Node 22 — no
Deno install, no build step, no transpile. 194 tests run in about two seconds.

**Trade-off:** shared code cannot use runtime conveniences. Each edge function
passes `Deno.env.toObject()` into `loadConfig()` instead of the config reading
the environment itself. That is a small cost for a suite that runs everywhere.

---

## 4. The model produces signals; the engine produces the score

`PurchaseScoreEngine` is deterministic and the model never touches the final
number. The model's own `suggested_action` is parsed and stored, but **only** so
model-vs-engine agreement can be measured offline — it is never on the verdict
path.

The reason is consistency. A language model is good at "this is a cropped black
jacket and it resembles three things you own", and bad at being consistent about
whether that is a 71 or an 83. Two users with identical inputs must get identical
scores, and the same user must get the same answer twice.

---

## 5. Unavailable signals are removed from the average, never scored as zero

When there is no wardrobe, the three wardrobe signals are dropped and their
weight is redistributed. When there is no price, value and budget fit are
dropped.

Scoring a missing signal as zero would invent a penalty the data does not
support — a first-time user with no wardrobe would be told to skip everything.
Instead the weights renormalise, confidence drops, and the UI says plainly what
BEFORE could not judge.

---

## 6. Overrides may only downgrade a verdict

Every deterministic rule in the engine can make a verdict more conservative and
none can make it less. The invariant is tested (`overrides only ever downgrade`).

It means one extreme signal — "you already own three of these" — can override a
bland weighted average, without opening a route for anything to talk a user into
a purchase the numbers do not support.

---

## 7. Low confidence blocks BUY, rather than only showing a warning

The spec asks for a "Low confidence" indicator. This goes one step further:
below 0.45 confidence, a BUY is demoted to WAIT (`low_confidence_demotes_buy`).

BEFORE telling someone to spend money on an analysis it is not sure about is the
single fastest way to lose the trust the product depends on. The indicator is
still shown; the demotion is the belt.

---

## 8. Relevance filtering uses a hint, not a two-pass classify

The wardrobe must be filtered *before* the model has classified the product,
which is a genuine ordering problem. Two options:

- **Two-pass:** classify cheaply, then fetch, then analyse. Doubles the AI cost
  and adds a round trip to the most latency-sensitive path in the app.
- **Hint + stratified fallback (chosen):** filter on a category hint from URL
  metadata, the share source, or the user's stated focus. With no hint, send a
  recency-weighted stratified sample across their categories.

The stratified sample is the important part: without it, a 60-item closet comes
back as sixty t-shirts and the duplication signal is useless.

**Upgrade path:** when wardrobes get large enough that the sample dilutes, add a
cheap classify pass for users above a size threshold, or image embeddings with
vector search. Neither is justified at MVP scale.

---

## 9. Images upload in a separate step, before the analysis call

The client uploads to its own storage prefix and sends the **path**, not base64
bytes, to `/v1/analyses`.

- A multi-megabyte base64 JSON body never crosses the wire.
- A failed upload is retried without re-running the analysis or spending a quota
  unit.
- Storage RLS enforces the `<user-id>/` prefix, so a client cannot write into
  someone else's folder even if it tries.

**Trade-off:** two round trips instead of one. Worth it: the failure modes
separate cleanly, which is what makes the "don't lose a pending upload"
requirement (§48) tractable.

---

## 10. Quota is consumed only on success

The `usage_ledger` row is written after an analysis completes. A provider
timeout, a safety block, or a malformed response costs the user nothing.

---

## 11. The calendar month is the user's, not UTC's

"5 analyses per calendar month" is computed in the user's own timezone. In UTC,
someone in Los Angeles would lose most of the last day of every month.

`monthWindow()` handles DST and is tested across six timezones including
`Pacific/Kiritimati` (UTC+14).

---

## 12. Structured output via strict tool use, not a JSON response format

The Anthropic provider passes the analysis schema as a `strict: true` tool with
`tool_choice: auto`, plus a prompt instruction naming the tool.

Forced tool choice (`any`/`tool`) returns a 400 on several current models, so
`auto` keeps the provider working across whatever `AI_MODEL` is set to. If the
model answers in prose anyway, `extractJson` recovers it. The validator is the
real trust boundary either way.

---

## 13. A safety scan runs on model output, not just a prompt instruction

`backend/shared/ai/safety.ts` scans every user-facing string the model produces.
Appearance and protected-attribute judgements **block** the analysis; fabricated
scarcity claims are **stripped**.

The system prompt already forbids all of this. This file assumes the prompt will
eventually fail to hold, because prompts do.

The appearance rule matches the *construction* `makes you look ___` rather than a
list of adjectives — the first version enumerated adjectives and missed
"heavier", which is exactly how a word list fails. There is a regression test for
that, and a set of 11 legitimate styling phrases that must **not** be flagged,
because a filter that fires on "the silhouette matches your trousers" is unusable
in a fashion product.

---

## 14. The Anthropic provider uses the official SDK; OpenAI and Gemini use REST

The spec requires provider-neutral architecture. The default path
(`AI_PROVIDER=anthropic`) uses `@anthropic-ai/sdk` and is imported lazily so mock
mode and the test suite never load it.

The OpenAI and Gemini adapters are REST, to keep the edge function's cold start
proportional to what it actually runs. **They have not been exercised against a
live key** — they exist so the abstraction is real rather than notional.

---

## 15. Default model: `claude-sonnet-5`, overridable

`AI_MODEL` is the single override point. Sonnet is the default on an explicit
cost decision by the project owner: the analysis is a bounded, well-structured
task with a strict output schema, this is a high-volume consumer path, and
Sonnet costs roughly 40% of Opus per call.

Set `AI_MODEL=claude-opus-5` to trade cost for depth. Nothing else changes — the
provider, the prompt, the validator, and the score engine are all model-agnostic,
and the fixture suite pins behaviour that does not depend on the model at all.

`AI_EFFORT` defaults to `medium` rather than `high` for the same reason: this is
a latency-sensitive consumer path, not long-horizon agentic work.

---

## 16. The Xcode project is generated, not committed

`ios/project.yml` (XcodeGen) is the source of truth; `ios/BEFORE.xcodeproj` is
git-ignored.

A hand-maintained `.pbxproj` is the most merge-hostile file in an iOS repo, and
one written without Xcode present could not have been verified anyway.

---

## 17. `BeforeKit` is a SwiftPM package

Models, scoring, and formatting live in a package that builds and tests with
`swift test` — no Xcode, no simulator, no signing identity. The app target
depends on it; it depends on nothing.

---

## 18. Wardrobe photos and analysis images live in private buckets only

There is no public bucket in this project. Reads go through short-lived signed
URLs issued by the backend. Unsaved analysis images are deleted by
`cleanup_unsaved_analysis_images()` after a 24-hour grace period, so saving a
result a minute later still has a thumbnail.

---

## 19. "Do you own something similar?" records the category, not the product

Answering YES creates a wardrobe item with the **category, subcategory, colour,
and style tags** — not the candidate's name or price.

Copying those would record an item the user does not actually own, which would
then be used to judge their next purchase. That is a fabricated fact with
consequences.

---

## 20. Account deletion removes storage first

`delete_user_account()` marks intent, removes storage objects, unlinks
operational logs, then deletes the auth user (which cascades every public row).

Storage goes first because a row cascade cannot reach object storage. If the run
dies midway, what is left behind is rows, not someone's wardrobe photos.

The function does **not** touch the App Store subscription. We cannot cancel it,
and the UI says so rather than implying otherwise.

---

## 21. Analytics properties are a closed enum, not a dictionary

`AnalyticsProperties` has six fixed fields. There is no free-form payload,
because a free-form payload is where raw images, URLs with tokens, and personal
history end up six months later. Scores are bucketed, never exact.

The backend logger uses the same approach: a field allow-list, so
`log.info(event, {...request})` cannot leak a prompt or a bearer token.

---

## 22. In-memory rate limiting on `/v1/product-metadata` is per-isolate

It stops a runaway client; it does not stop a distributed one. This is stated in
the code rather than glossed over. The durable, ledger-backed limit is on the
analysis path, which is where the cost actually is.

---

## 23. A real app icon is generated, not stubbed

`ios/scripts/make-app-icon.mjs` renders a 1024×1024 PNG with no dependencies —
a burgundy **B** on the warm off-white background, geometry derived so the
counters close cleanly and the glyph is optically centred.

It is a placeholder a designer should replace, but it is a **real asset**, so the
project builds and ships a legible icon today rather than a missing file.

---

## 25. Apple signature verification is hand-written, and the root is configured

`backend/shared/apple/` implements DER parsing, X.509 chain verification, and
JWS verification directly, using WebCrypto. No package.

Two reasons. It has to run on Deno and Node unchanged, and a certificate parser
is a small, well-specified thing that is better read than trusted — this one is
about 500 lines and every branch is exercised by the test suite.

**Apple Root CA G3 is NOT hard-coded.** It comes from
`APPLE_ROOT_CA_G3_BASE64`, and production refuses to boot without it. Writing a
certificate fingerprint from memory is exactly the fabricated fact this codebase
refuses to produce, and a wrong one either breaks every purchase or, worse,
trusts the wrong issuer.

The tests generate a **real** OpenSSL ECDSA P-256 chain, plus a second,
completely independent one. The rogue chain is internally consistent and every
check passes for it except the root pin — and a companion test verifies it
against its *own* root, so the pinning test cannot pass merely because the rogue
chain is malformed.

---

## 26. An unverified subscription claim is now impossible

`subscription-sync` previously stored what the client said. It now stores only
what it verified:

- the client's `signedTransaction` is verified against the pinned root;
- the bundle id must be ours — a validly-signed transaction from any other App
  Store app would otherwise verify and could be replayed to grant Plus;
- when Server API credentials are present, Apple is asked for the current state
  and *that* is stored, because renewals, refunds, and revocations are only
  visible that way.

Every other field in the request body is used for logging only. There is an
architecture test asserting the upsert block contains no `body.` reference at
all.

If Apple cannot be reached, the verified transaction is still stored and the
response reports `reconciled: false`. A transient outage must not block a
legitimate purchase; the notification handler corrects it afterwards.

---

## 27. One unauthenticated endpoint, and it is enforced

`/v1/app-store/notifications` has no session — Apple calls it. It uses
`withPublicContext`, a deliberately separate function rather than a
`requiresAuth: false` flag, because a flag is one typo away from opening a user
endpoint to the world.

An architecture test asserts that **exactly one** endpoint uses it, and that
verification happens before anything is written. A bad signature returns 401
rather than 200: this endpoint is public, and a bad signature is the expected
shape of abuse.

---

## 28. The wardrobe lives in the Saved tab, not a fifth tab

Spec §8 fixes the navigation at four tabs. "Owned" already meant "what you own",
so the wardrobe is what that bucket shows. Two separate lists would have meant
two answers to the same question.

The empty state was written before the list: the product promise is that you do
*not* have to digitise your closet, so this screen must never read as a chore
waiting to be done. There is a UI test asserting that copy is present.

**The free cap is 25 items, deliberately generous.** §35 lists "full wardrobe
memory" as a Plus feature, but §35 also forbids gating result quality — and the
wardrobe is precisely what makes a verdict personal. 25 covers a realistic
casual user; Plus removes the cap.

---

## 29. "Deeper explanations" are three fixed questions, not a chat

§35 lists deeper explanations as a Plus feature. Rule 1 says BEFORE is not a
general AI assistant and §8 rules out a chat tab.

The endpoint takes an `angle` from a closed set of three. There is no free-text
field anywhere on the result screen, and two tests enforce that: one asserts the
endpoint rejects a question body, another asserts the result screen contains no
text field at all.

The model is also given nothing new to work from — no image, no metadata fetch,
no wardrobe, only the analysis it already produced. It has nothing to invent a
fact from.

---

## 30. Two notifications, both opt-in per item

Spec §64 says do not request permission during onboarding. This goes further:
permission is requested from exactly one button, which the user pressed for a
stated reason ("Remind me in 48 hours" on a WAIT verdict).

There are two notifications and no others: the 48-hour reminder the user asked
for, and one follow-up a fortnight after they said they bought something —
because outcomes are the only ground truth BEFORE ever gets.

No re-engagement nudge, no streak, no "you haven't checked anything lately". An
app that helps people spend less has no business manufacturing reasons to open
it. Recording an outcome cancels any pending reminder, because being reminded to
decide something already decided is the fastest way to get notifications
switched off.

---

## 32. Prices stay at $6.99 / $59.99 — the cost model says they are right

Measured rather than guessed: `backend/scripts/cost-model.mjs` builds the real
prompt through `buildAnalysisPrompt()` and prices it at Anthropic list rates.

| | |
| --- | --- |
| Cost per analysis (Sonnet 5, 70% cache hit) | **$0.0315** |
| Contribution, $6.99/mo at Apple 15% | **$5.56 — 79.6% margin** |
| Break-even usage, yearly plan | ~130 analyses/month |
| Typical usage | ~12 analyses/month |
| Break-even free→paid conversion | 1.2% |

At 80% margin the AI is not the constraint; CAC and churn are. Raising prices
would buy margin the product does not need and cost conversion it does. The
model is re-runnable with different assumptions rather than being a snapshot in
a document:

```bash
node backend/scripts/cost-model.mjs --usage 25 --monthly 8.99 --image-px 1280
```

**The one number that is an assumption, not a measurement:** output tokens at
`effort=medium`. Output is 62% of the cost, and the 1,400-token estimate for
adaptive thinking could not be verified without a live key. `ai_call_log`
already records real `input_tokens`, `output_tokens` and `estimated_cost_usd`
per call, so the first day of real traffic replaces the estimate.

---

## 33. A fair-use ceiling on Plus, because "unlimited" was a real liability

The cost model surfaced a hole that had nothing to do with pricing. The only
ceiling on a Plus account was `RATE_LIMIT_ANALYSES_PER_DAY=120`, which permits
**3,600 analyses a month — about 27× break-even**. One determined account on the
yearly plan could cost **-$109/month**.

Fixed with a monthly fair-use ceiling of **100**, and the daily limit dropped
from 120 to 40 (a day is not a sensible unit in which to control a monthly
cost). A test asserts the daily limit can never on its own exceed the monthly
one, and another asserts the ceiling stays below break-even.

Three decisions inside that:

- **Fair use is a distinct error code**, `fair_use_exceeded` (429), not
  `quota_exceeded` (402). One is an upgrade offer; the other is someone who
  already pays and must not be upsold. Collapsing them would nag a customer.
- **No counter is shown**, until the remainder drops below ten. A running
  countdown on a plan sold as "unlimited" reads as a lie.
- **It is documented** in `docs/LIMITS.md` with the reasoning, because spec §52
  forbids advertising unlimited over a cap that exists.

---

## 34. Upload resolution is a cost decision: 2200px → 1568px

Claude bills vision at roughly one token per 28×28 patch, so tokens scale with
*area*. At 2200px a product photo was **4,630 tokens — 66% of the entire input**.
Sonnet 5 accepts up to 2576px, so nothing was downsampling it for us; every
extra pixel was billed.

1568px keeps weave, stitching and hardware legible for what BEFORE actually
judges — colour, silhouette, category, duplication — and takes **~19% off the
cost of an analysis**. 1280px would save more and is Claude's own documented
default, but 1568 leaves headroom for material questions.

The share extension's reducer was changed to match, so a shared screenshot and
a picked photo cost the same.

---

## 35. What could not be verified in this environment

Built on Windows with Node 22. No Xcode, no Swift toolchain, no Supabase project.

### Verified by execution — 264 backend tests, plus a real database and type-checker

| Suite | What it actually proves |
| --- | --- |
| `score-engine` | 14 hand-derived fixtures reproduce exactly; BYE stays reachable; overrides only downgrade; scores stay in range across a sweep |
| `schema` | malformed, hostile, and out-of-range model output is rejected or corrected; model URLs discarded |
| `safety` | 10 appearance and protected-attribute phrasings blocked, **11 legitimate styling phrases pass** |
| `mock-provider` | every shipped fixture runs through the real validator and engine and produces its documented score |
| `config` | mock mode cannot boot in production; missing keys fail at boot |
| `relevance` | skincare is not sent when analysing a blazer; median spend needs three data points |
| `quota` | month windows correct across six timezones and a DST transition; errors leak nothing |
| `metadata` | JSON-LD and Open Graph parsing; SSRF refusal for eight private addresses |
| `migrations` | RLS on every table, no `USING (true)`, private buckets, no float money, enum parity with TypeScript |
| `swift-parity-contract` | Swift enums, weights, thresholds, rule ids, and exclusion strings match the TypeScript source |
| `ios-static-checks` | theme tokens resolve, analytics events declared, UI-test identifiers exist, no force-unwraps, no banned copy |
| `architecture` | shared code stays runtime-neutral; the engine is called from exactly one place; quota consumed only after success; exactly one unauthenticated endpoint; no client value reaches a subscription row |
| `apple-jws` | a real ECDSA chain verifies; an independent rogue chain is **rejected**; tampered payloads, tampered signatures, `alg` confusion, foreign bundle ids, and out-of-window certificates all refused |
| `appstore-client` | the App Store JWT is signed and verifies under the matching public key; unknown Apple status codes fail closed |
| `workflows` | CI YAML parses, every `npm run` it names exists, every job has a timeout, no credentials |

The static checks earned their place immediately: they found a real force-unwrap
in `SubscriptionManager` that violated this project's own iOS rules.

The app icon PNG was generated and visually inspected; the first version had
malformed counters and was fixed.

### Also verified, against real infrastructure

**Migrations — Postgres 16 in Docker, 49 assertions.**

`npm run test:migrations` applies all eight migrations to a throwaway database,
then proves RLS *works* rather than merely exists: two real users, real inserts,
and assertions that neither can read, update, or delete the other's rows. A
policy of `using (user_id = user_id)` would satisfy the static lint and leak
every row in the table; it would fail here.

It also covers the storage prefix policies, `is_plus()` across every
subscription state, six check constraints, and that `delete_user_account()`
genuinely removes storage objects. The development seed is applied last, so a
broken seed is caught here rather than on someone's first `db reset`.

A Supabase-compatible bootstrap (`backend/supabase/tests/00_bootstrap.sql`)
stands in for the `auth` and `storage` schemas. That is what lets this run on
any Postgres in about fifteen seconds, with no Supabase CLI.

**Edge functions — type-checked under Deno.**

The Node test runner strips types without checking them, so the functions had
never actually been type-checked. `npm run check:deno` does it under the runtime
that will run them, and it found three real errors on its first run:

- `errors.ts` — a ternary inferred as a union that was not assignable to
  `Record<string, string>`;
- two places where a provider's `number | null` was passed to a logger field
  typed `number | undefined`.

All three are fixed. This is precisely why the check is in CI.

### Still not executed

All Swift — `BeforeKit` tests, app unit tests, UI tests, and the Xcode build —
and any live AI provider call. The contract and static tests narrow what can be
wrong in the Swift, but they cannot type-check it.

`.github/workflows/ios.yml` runs all of it on a macOS runner. `TODO.md` §1 lists
what to run first and the five places a compile error is most likely.
