# BEFORE — project brain

**Before you buy it, ask BEFORE.**

An AI second opinion for purchases. The user sends a product (photo, screenshot,
camera, or link) and gets a **BUY / WAIT / BYE** verdict scored against their own
style, wardrobe, budget, and past decisions.

> Shopping platforms help you buy more. BEFORE helps you buy better.

## Stack

| Layer | Choice |
| --- | --- |
| iOS | Swift 6, SwiftUI, SwiftData, StoreKit 2, min **iOS 17.0** |
| Pure logic | `BeforeKit` SwiftPM package (testable without Xcode) |
| Backend | Supabase — Postgres + RLS + private Storage + Edge Functions (Deno) |
| Shared logic | Runtime-neutral TypeScript in `backend/shared/` |
| AI | Provider-abstracted; `AI_PROVIDER=anthropic`, `AI_MODEL=claude-sonnet-5` |
| Analytics | Provider-neutral abstraction; PostHog reference impl |

## Commands

```bash
npm run test:backend      # Node 22 native TS test runner — works on any OS
npm run test:score        # score-engine fixtures only
npm run check:secrets     # fails if key material appears under ios/
npm run parity            # prints the shared fixture suite both runtimes use

# macOS only
make ios-project          # XcodeGen -> ios/BEFORE.xcodeproj
swift test --package-path ios/BeforeKit
xcodebuild test -scheme BEFORE -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Non-negotiable product rules

1. **BYE must stay reachable.** If everything becomes BUY, the product is worthless.
2. **Never judge the person.** Clothes, fit-to-wardrobe, value — never
   attractiveness, body, weight, age, race, or any protected trait.
3. **Never fabricate** price, brand, material, retailer, product name, or a
   shopping URL. Say `Not confidently identified` or `Estimated from image`.
4. **The verdict is personal**, not objective: "is this good *for you*".
5. **Trust beats monetisation.** Commerce signals can never reach the score.
6. **The model never sets the score.** It emits signals; `PurchaseScoreEngine`
   computes the number deterministically, server-side.

## Conventions

- Architecture: View → ViewModel → Repository → Service. No logic in `View`s.
- Theme tokens only (`BeforeTheme`). No colour, radius, or font-size literals.
- All endpoints under `/v1`. Explicit enums, never bare strings.
- All schema changes are migrations. RLS policy in the same migration as the table.
- Secrets never enter the iOS bundle. The app knows only the Supabase URL + anon key.
- Score or verdict behaviour changes bump `SCORE_ALGORITHM_VERSION` and add fixtures.
- Prompt changes bump `PROMPT_VERSION`. Every analysis records both versions.

## Where things live

```
backend/shared/          runtime-neutral logic + the shared fixture suite
backend/supabase/        migrations, Edge Functions, seed
ios/BeforeKit/           pure Swift logic + tests (runs under `swift test`)
ios/BEFORE/              the app: App, Core, Theme, Components, Features, ...
ios/BEFOREShareExtension/ share sheet target -> App Group handoff
docs/                    API, AI, LIMITS, PRIVACY, APP_STORE, SETUP
DECISIONS.md             every non-obvious engineering choice and its trade-off
TODO.md                  what is deliberately not built yet
```

## Reading order for a new contributor

`README.md` → `DECISIONS.md` → `backend/shared/scoring/engine.ts` →
`ios/BeforeKit/Sources/BeforeKit/Scoring/PurchaseScoreEngine.swift` → `docs/API.md`
