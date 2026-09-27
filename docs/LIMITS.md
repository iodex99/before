# Limits

What a user gets, what the backend enforces, and what "unlimited" honestly means.

---

## Free

**5 analyses per calendar month.**

The month is the **user's own**, computed in their timezone. In UTC, someone in
Los Angeles would lose most of the last day of every month. `monthWindow()`
handles DST and is tested across six timezones, including `Pacific/Kiritimati`
at UTC+14.

The count lives in `usage_ledger`, one row per consumed analysis. A row is
written **only after an analysis completes** — a provider timeout, a safety
block, or a malformed response costs the user nothing.

The app shows "4 of 5 checks remaining" from `GET /v1/usage`, which is the
server's own answer. The display and the limit cannot disagree, because they are
the same number.

---

## BEFORE Plus

**$6.99 per month or $59.99 per year** — reference prices only. The UI always
shows StoreKit's localised strings, and the annual saving percentage is computed
from the two real prices or not shown at all.

No monthly cap. Unlocks unlimited checks, full history, full wardrobe memory,
outcome tracking, personalised insights, and advanced share cards.

Basic result quality is **not** gated. A free user gets the real product.

---

## Free wardrobe cap

**25 items.** Plus removes it.

§35 lists "full wardrobe memory" as a Plus feature, but §35 also forbids gating
result quality — and the wardrobe is precisely what makes a verdict personal.
25 covers a realistic casual user, so the cap is felt by people with genuinely
large wardrobes and nobody else.

Hitting it returns **402** `quota_exceeded`, the same as the monthly analysis
cap: an offer, not an error.

---

## Fair use on Plus — 100 analyses a month

Plus has no *plan* limit: you are not counting down against an allowance, and
the app shows no counter. It does have a **fair-use ceiling of 100 analyses a
month**, and this page exists because spec §52 forbids advertising "unlimited"
over a cap that really exists.

The number is not arbitrary. At the measured unit cost
(`backend/scripts/cost-model.mjs`), a yearly subscriber stops paying for
themselves somewhere above **130 analyses a month**. Typical use is around **12**.
The ceiling sits at 100 — roughly 8× a heavy genuine user, and below the point
where an account costs more than it brings in.

Hitting it returns **429** `fair_use_exceeded` with a `Retry-After` pointing at
the start of next month. It is deliberately *not* an upsell: the person already
pays. The app warns once the remainder drops below ten, and says nothing before
that.

> **Why this exists.** Before it, the daily limit of 120 was the only ceiling,
> which permitted 3,600 analyses a month — about 27× break-even, and a
> three-figure monthly loss on a single determined account.

## Anti-abuse limits — everyone, Plus included

| Limit | Default | Environment variable |
| --- | --- | --- |
| Analyses per minute | 6 | `RATE_LIMIT_ANALYSES_PER_MINUTE` |
| Analyses per day | 40 | `RATE_LIMIT_ANALYSES_PER_DAY` |
| Concurrent analyses | 2 | `MAX_CONCURRENT_ANALYSES` |
| Upload size | 6 MB | `MAX_UPLOAD_BYTES` |
| Metadata fetches per minute | 20 | `RATE_LIMIT_METADATA_PER_MINUTE` |

Each returns a real `429` with a `Retry-After` header. (The wardrobe cap above is
not in this table: it is a plan limit and returns `402`, not `429`.)

The daily limit is **burst protection**, not the financial ceiling — that job
belongs to the monthly fair-use limit above. It was lowered from 120 to 40 when
the monthly ceiling landed, because a day is not a sensible unit in which to
control a monthly cost. A test asserts the daily limit can never on its own
exceed the monthly one.

---

## Two different answers

| Situation | Status | Client behaviour |
| --- | --- | --- |
| Free allowance used up | **402** `quota_exceeded` | show the paywall |
| Plus fair use reached | **429** `fair_use_exceeded` | explain, do NOT upsell |
| Rate limit hit | **429** `rate_limited` | back off using `Retry-After` |

Three different answers. Conflating the first two either nags a paying customer
with an upgrade prompt or hides the upgrade from someone who wants it; conflating
the last two tells someone to wait sixty seconds for something that resets in
three weeks.

---

## A caveat worth knowing

Rate limiting on `/v1/product-metadata` is in-memory and therefore
**per-isolate**. It stops a runaway client; it does not stop a distributed one.

The durable, ledger-backed limit is on the analysis path, which is where the cost
actually is. Moving the metadata limiter to a shared store is worth doing if that
endpoint ever becomes a target.
