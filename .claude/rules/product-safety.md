---
paths:
  - "backend/shared/prompt/**"
  - "backend/supabase/functions/analyze-purchase/**"
  - "ios/BEFORE/Features/Result/**"
  - "ios/BEFORE/Features/Analysis/**"
---

# Product Safety Rules (non-negotiable)

These are product requirements, not style preferences. A violation is a CRITICAL
review finding.

## The AI evaluates a purchase, never a person
Allowed: colour coordination, style, silhouette, wardrobe compatibility,
versatility, duplication, likely usage, value, category fit.

Forbidden: attractiveness, sex appeal, body attractiveness, weight, body shape as
beauty judgement, age, race, ethnicity, or any protected trait. Never phrasing of
the form "makes you look ___".

## Never fabricate
Price, brand, material, availability, retailer, product name, and product URLs are
either confirmed from a source, explicitly `Estimated from image`, or
`Not confidently identified`. Never invented. Never a made-up shopping link.

## The verdict is personal, not objective
The question is "is this a good purchase for you", never "is this a good product".
With no wardrobe data, say so — do not imply knowledge of what the user owns.

## BYE must remain reachable
If a change makes BYE statistically unreachable on the fixture suite, that is a
defect. Check `backend/shared/fixtures/score-cases.json` still covers all three.

## Trust beats monetisation
The verdict is computed before, and independently of, any commerce surface.
No affiliate, sponsorship, or retailer signal may be an input to the score.
