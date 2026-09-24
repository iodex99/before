# AI

How BEFORE uses a model, what it is not allowed to do, and what it costs.

---

## The division of labour

The model produces **signals**. The engine produces the **score**.

```
image + page metadata + user context + relevant wardrobe + relevant history
          │
          ▼
   ShoppingAnalysisProvider      seven signals, 0..100, plus availability flags
          │
          ▼
   validateAnalysis()            schema, ranges, lengths, safety scan
          │
          ▼
   PurchaseScoreEngine           score, verdict, confidence — deterministic
```

A language model is good at "this is a cropped black jacket and it resembles
three things you own", and bad at being consistent about whether that is a 71 or
an 83. Two users with identical inputs must get identical scores.

The model's own `suggested_action` is parsed and kept, but only so
model-vs-engine agreement can be measured offline. It never reaches the verdict.

---

## Providers

| `AI_PROVIDER` | Implementation | Status |
| --- | --- | --- |
| `anthropic` | `@anthropic-ai/sdk` | default, the exercised path |
| `openai` | REST | written, never run against a live key |
| `gemini` | REST | written, never run against a live key |
| — | `MockProvider` | fixtures; enabled by `AI_MOCK_MODE=true` |

The Anthropic adapter is imported lazily, so mock mode and the test suite never
load the SDK.

### Models

`AI_MODEL` is the single override point. Per-provider defaults live in
`backend/shared/config.ts`.

Sonnet is the default on a deliberate cost decision: the analysis is a bounded,
well-structured task with a strict output schema, and this is a high-volume
consumer path. Nothing else changes when you switch — the prompt, the validator,
and the score engine are all model-agnostic.

| Model | Input $/MTok | Output $/MTok | Note |
| --- | --- | --- | --- |
| `claude-sonnet-5` | 2 | 10 | **default** — bounded task, strict schema, high volume |
| `claude-opus-5` | 5 | 25 | more depth per call; set `AI_MODEL` to switch |
| `claude-haiku-4-5` | 1 | 5 | likely too weak for wardrobe reasoning |

Rates as published 2026-06. `backend/shared/ai/pricing.ts` mirrors them for
internal cost logging and returns `null` for an unknown model rather than a
confidently wrong number.

`AI_EFFORT` defaults to `medium`. This is a latency-sensitive consumer path, not
long-horizon agentic work, and `high` buys little here for noticeably more
latency and spend.

---

## Anthropic request shape

- **Structured output via strict tool use.** The schema is passed as a
  `strict: true` tool with `tool_choice: auto`, plus a prompt instruction naming
  the tool. Forced tool choice returns a 400 on several current models, so `auto`
  keeps the provider working across whatever `AI_MODEL` is set to. If the model
  answers in prose anyway, `extractJson` recovers it.
- **Prompt caching on the system prompt.** It is byte-identical for every user,
  so it is marked cacheable. Nothing volatile — no timestamp, no request id — may
  ever be added to it, or the cache silently stops hitting. If costs drift
  upward, check `usage.cache_read_input_tokens` first.
- **Refusal handling.** A fashion photo containing a person can trip a safety
  classifier. A refusal arrives as HTTP 200 with `stop_reason: "refusal"`, so it
  is checked before the content is read. Server-side fallbacks are on by default
  (`AI_REFUSAL_FALLBACKS`), which retries a decline on another model inside the
  same call.

---

## Versioning

Every completed analysis stores both versions.

| Constant | Where | Bump when |
| --- | --- | --- |
| `PROMPT_VERSION` | `ai/schema.ts` | the system prompt or the schema changes |
| `SCORE_ALGORITHM_VERSION` | `scoring/weights.ts` | any weight, threshold, or rule changes |

Without these, changing the prompt silently redefines what every historical score
meant. With them, a corpus can be re-analysed under a new prompt and compared.

Changing weights also means re-deriving `fixtures/score-cases.json` by hand. The
fixture suite asserts that the version matches, so this cannot be forgotten.

---

## Validation — the trust boundary

`validateAnalysis()` treats model output as untrusted input.

**Structural failures throw.** A missing `signals` block, a missing individual
signal, a non-object response. One repair retry, then a typed failure.

**Recoverable problems are corrected and recorded** in `warnings`: out-of-range
numbers clamped, long strings truncated, unknown enum members defaulted,
non-ISO currency codes dropped, zero and negative prices nulled.

**Model-supplied product URLs are discarded outright** (Rule 6).

**A price with no stated provenance is labelled** `confirmed` or `estimated` from
its confidence — never left ambiguous.

### The safety scan

`ai/safety.ts` scans every user-facing string the model produces. The system
prompt already forbids all of this; this file assumes the prompt will eventually
fail to hold, because prompts do.

| Finding | Effect |
| --- | --- |
| appearance judgement, body, weight, protected attribute | **blocks** the analysis |
| age judgement | strips the line |
| fabricated scarcity or certainty | strips the line |

The appearance rule matches the *construction* `makes you look ___` rather than a
list of adjectives. The first version enumerated adjectives and missed "heavier",
which is exactly how a word list fails. There is a regression test for it.

Equally important: 11 legitimate styling phrases are asserted to **pass**. A
filter that fires on "the silhouette matches the trousers you already own" is
unusable in a fashion product.

A safety block is **never retried**. Asking the same model the same question
again is not a fix, and it doubles the cost of a request that is going to fail.

---

## Cost control

- **Relevance filtering** caps the context at 12 wardrobe items and 8 history
  entries, chosen for likelihood of changing the verdict — not simply the most
  recent N.
- **Image normalisation** on device: longest edge 2200px, JPEG, under 6MB.
- **Product metadata caching** for 7 days, shared across users.
- **Idempotency keys**, so a double-tap does not buy a second analysis.
- **`ai_call_log`** records provider, model, tokens, estimated cost, latency,
  error category, and safety and warning counts per call. It never records the
  prompt, the image, or the response.

Cost data is operational. It is never surfaced to users.

---

## Mock mode

```
AI_MOCK_MODE=true
```

Serves `backend/shared/fixtures/ai-responses.json`, selected deterministically by
request id — so a retry gives the same answer, while different analyses cycle
through all three verdicts during UI work.

`backend/tests/mock-provider.test.ts` runs every fixture through the real
validator and the real engine and asserts the documented score exactly. A fixture
cannot claim "WAIT 78" in the docs while scoring 62 in the app.

`loadConfig()` refuses to boot with mock mode enabled and `APP_ENV=production`.
A mocked verdict reaching a paying user is worse than an outage, because it looks
real.
