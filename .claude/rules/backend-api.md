---
paths:
  - "backend/shared/**/*.ts"
  - "backend/supabase/functions/**/*.ts"
---

# Backend / API Rules

- All endpoints are versioned under `/v1`. No unversioned production routes.
- Shared logic in `backend/shared/` stays runtime-neutral: no `Deno.*`, no
  `process.*`, no `node:` imports. Relative imports carry the `.ts` extension so
  both Deno and Node can load them.
- Validate every AI response against the schema before use. Malformed output is
  rejected and retried once, then surfaced as a typed failure — never passed through.
- The model supplies signals. `PurchaseScoreEngine` supplies the score. Never
  let a model-provided number become the displayed score.
- Every response uses explicit enums (`BUY`/`WAIT`/`BYE`), never ad-hoc strings.
- Secrets are read from the environment at the edge of the function, passed in as
  arguments. No module-level secret reads in shared code.
- Log: request id, endpoint, internal user id, latency, status, provider, model,
  error category. Never log images, keys, tokens, or full purchase history.
- Mutating endpoints accept an `Idempotency-Key` and return the existing result
  for a repeat key rather than doing the work twice.
- Rate limits return real `429`s with `Retry-After`.
