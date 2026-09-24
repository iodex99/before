# Privacy

Privacy is a product feature here, not a compliance exercise. BEFORE asks people
to tell it what is in their wardrobe and what they spend. That only works if the
handling is defensible.

This document is the engineering reference. It is also the source material for
the App Privacy questionnaire.

---

## What is stored

| Data | Where | Why | Retention |
| --- | --- | --- | --- |
| Apple user id | `auth.users` | identity | until deletion |
| Display name | `public.users` | greeting | until deletion, often null |
| Locale, currency, timezone | `public.users` | correct prices and dates | until deletion |
| Preferences | `user_preferences` | personalisation | until deletion |
| Analyses, products, factors | `analyses`, `analysis_products`, `analysis_factors` | history, personalisation | until deletion |
| Wardrobe items | `wardrobe_items` | duplication and fit signals | until deletion |
| Saved items, outcomes | `saved_items`, `purchase_outcomes` | the learning loop | until deletion |
| Usage ledger | `usage_ledger` | quota enforcement | until deletion |
| Subscription records | `subscriptions` | entitlement | until deletion |
| Analysis images | private `analyses` bucket | the analysis itself | **deleted after 24h unless saved** |
| Wardrobe images | private `wardrobe` bucket | duplication signals | until deletion |
| AI call log | `ai_call_log` | cost and reliability | user id nulled on deletion |
| Analytics events | `analytics_events` | product metrics, bucketed | user id nulled on deletion |

### What is never stored

- No email address. Sign in with Apple provides one; BEFORE does not copy it.
- No Apple credentials. Only the resulting Supabase session, in the Keychain.
- No payment details. Apple handles all of it.
- No location. Image metadata is stripped during processing.
- No contacts, no photo library access. `PhotosPicker` returns one chosen image.
- No free-form analytics payload. See below.

---

## Images

Both buckets are **private**. There is no public bucket in this project.

Reads go through short-lived signed URLs issued by the backend, so an image URL
that leaks expires rather than becoming a permanent handle on someone's wardrobe.

Analysis images are **deleted 24 hours after the analysis unless the user saved
it** (`cleanup_unsaved_analysis_images`). The grace period exists so saving a
result a minute later still has a thumbnail.

On device, `ImageProcessor` re-encodes every image before upload. It uses
`CGImageSourceCreateThumbnailAtIndex` with the orientation transform applied,
which produces a clean bitmap and drops the original EXIF block — including GPS.
A wardrobe photo carrying the coordinates of someone's bedroom is not something
to upload.

---

## Row Level Security

Every user-owned table has RLS enabled and an explicit policy per operation,
written in the same migration that creates the table.

`backend/tests/migrations.test.ts` enforces this statically on every change:

- every table in `public` enables RLS;
- every policy on a user-owned table references `auth.uid()`;
- no policy uses `USING (true)` on a user-owned table;
- every `security definer` function pins `search_path`;
- storage buckets are private;
- money is `numeric`, never floating point.

Tables with **no** policies (`product_metadata_cache`, `ai_call_log`,
`app_store_notifications`) are deliberate: RLS on with zero policies denies every
client, and they are reachable only with the service role from inside an edge
function.

Storage objects are namespaced `<user-id>/<file>` and the policies match on that
prefix, so the convention is actually enforced rather than merely followed.

---

## Logging

`_shared/log.ts` uses a **field allow-list**. `log.info(event, fields)` emits only
the named fields, so a well-meaning `{ ...request }` cannot put an image, a
bearer token, or a purchase history into the log stream.

Logged: request id, internal user id, endpoint, latency, status, provider, model,
token counts, estimated cost, error category, and counts of safety and schema
findings.

Never logged: images, API keys, auth tokens, prompts, model responses, product
URLs, or purchase history. An unexpected exception is logged by **type only** —
its message may carry a URL, a key fragment, or a row of user data.

---

## Analytics

`AnalyticsProperties` is a closed struct with six fields. There is no free-form
dictionary, because a free-form dictionary is where raw images, tokenised URLs,
and personal history end up six months later.

Scores are **bucketed** (`0-59`, `60-79`, `80-100`), never exact. There is a test
asserting that the exact score is absent and that no unexpected key can appear.

The default sink in release builds is `NoOpAnalyticsSink`. A provider is wired
only when there is consent to do so.

---

## Deletion

`POST /v1/account/delete` with `{"confirmation": "DELETE"}`, behind two
confirmations in the UI.

`delete_user_account()` runs in a deliberate order:

1. **Mark intent** — `users.deleted_at`, so an interrupted run is visible.
2. **Delete storage objects** in both buckets for that user. This goes first
   because a row cascade cannot reach object storage; if the run dies after this
   point, what is left behind is rows, not photos.
3. **Unlink operational logs** — `ai_call_log.user_id` and
   `analytics_events.user_id` are set to null. Aggregate cost history survives;
   the association with a person does not.
4. **Delete the auth user.** Every `public.*` row cascades from there.

The function returns counts so the client can confirm something actually
happened.

### What deletion does not do

It does not cancel an App Store subscription. We cannot, and pretending otherwise
would leave someone paying for an account that no longer exists. The endpoint
returns a notice saying so, the confirmation dialog repeats it, and a UI test
asserts that wording is present.

---

## Export

`export_user_data()` returns everything BEFORE holds about the caller as one JSON
document. It is `security invoker`, so RLS applies and it can only ever return
the caller's own data.

The app currently exports its local cache; the server-side export has no endpoint
in front of it yet (TODO.md §3).

---

## App Privacy questionnaire — the short version

| Category | Collected | Linked to identity | Used for tracking |
| --- | --- | --- | --- |
| Identifiers (user id) | Yes | Yes | No |
| Name | Yes, optional | Yes | No |
| Photos | Yes | Yes | No |
| Purchases | Yes | Yes | No |
| Product interaction | Yes, bucketed | Yes | No |
| Location | No | — | — |
| Contacts | No | — | — |
| Browsing history | No | — | — |

**Nothing is used for tracking, and nothing is sold or shared with data brokers.**
