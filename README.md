# BEFORE

**Before you buy it, ask BEFORE.**

An AI second opinion for purchases. See something, send it to BEFORE, get a
**BUY / WAIT / BYE** verdict scored against your own style, wardrobe, budget, and
past decisions.

> Shopping platforms help you buy more. BEFORE helps you buy better.

---

## What it does

1. You send a product — a photo, a screenshot, a camera shot, or a link. From
   inside the app or straight from the iOS share sheet.
2. The backend reads what the product page says about itself, pulls the relevant
   slice of your wardrobe and past decisions, and asks a model for **signals**.
3. A deterministic engine turns those signals into a score and a verdict.
4. You get a straight answer, the reasoning behind it, and one practical next
   step — plus an honest list of what BEFORE could not confirm.

The product is allowed to tell you not to buy. If it never did, it would be
worthless.

---

## Architecture

```
iOS app  ──►  Supabase Edge Function  ──►  AI provider
   │               │
   │               ├──►  Postgres (RLS)        analyses, wardrobe, outcomes
   │               ├──►  private Storage       images, signed URLs only
   │               └──►  PurchaseScoreEngine   the score, deterministically
   │
   └──►  SwiftData cache                       history and saved items, offline
```

The app never talks to a model. Every AI key, the service-role key, and the App
Store signing key live server-side. The app knows a project URL and a publishable
anon key, and nothing else — `npm run check:secrets` fails the build otherwise.

| Layer | Choice |
| --- | --- |
| iOS | Swift 6, SwiftUI, SwiftData, StoreKit 2, min **iOS 17.0** |
| Pure logic | `BeforeKit` SwiftPM package — testable without Xcode |
| Backend | Supabase: Postgres + RLS + private Storage + Edge Functions (Deno) |
| Shared logic | Runtime-neutral TypeScript in `backend/shared/` |
| AI | Provider-abstracted. Default `anthropic` / `claude-sonnet-5` |
| Analytics | Provider-neutral abstraction; PostHog is the reference impl |

---

## Repository

```
before/
├── ios/
│   ├── BeforeKit/              pure Swift: models, scoring, formatting (+ tests)
│   ├── BEFORE/
│   │   ├── App/                entry point, composition root, tabs
│   │   ├── Core/               config, analytics, keychain, images, share inbox
│   │   ├── Theme/              BeforeTheme — every colour and metric
│   │   ├── Components/         buttons, cards, verdict badge, score ring, states
│   │   ├── Networking/         APIClient, typed errors
│   │   ├── Persistence/        SwiftData cache
│   │   ├── Repositories/       the seam features depend on
│   │   ├── Services/           auth, subscriptions, storage
│   │   └── Features/           Onboarding, Home, Analysis, Result, Saved,
│   │                           History, Profile, Paywall, Share, Wardrobe
│   ├── BEFOREShareExtension/   share sheet → App Group handoff
│   ├── BEFORETests/            networking, decoding, subscriptions, share
│   ├── BEFOREUITests/          onboarding → analysis → save → paywall → delete
│   ├── StoreKit/               Products.storekit for local purchase testing
│   └── project.yml             XcodeGen spec (the .xcodeproj is generated)
├── backend/
│   ├── shared/                 runtime-neutral logic + the shared fixtures
│   │   └── apple/              DER, X.509, JWS and App Store Server API
│   ├── supabase/
│   │   ├── migrations/         8 migrations, RLS in the same file as the table
│   │   └── functions/          analyze-purchase, analysis, wardrobe, explain,
│   │                           me, usage, product-metadata, subscription-sync,
│   │                           account-delete, account-export,
│   │                           app-store-notifications
│   ├── tests/                  274 tests, run with plain Node 22
│   └── scripts/                secret scan, fixture printer
├── docs/                       API, SETUP, AI, PRIVACY, LIMITS, APP_STORE, ICON
├── .claude/                    agents, commands, hooks, rules, skills
├── CLAUDE.md                   project brain
├── DECISIONS.md                every non-obvious choice and its trade-off
└── TODO.md                     what is deliberately not built yet
```

---

## Getting started

### Backend tests — any machine with Node 22

No Supabase project, no API key, no build step.

```bash
npm install
npm run test:backend     # 274 tests
npm run check:secrets
npm run check:deno       # type-check the edge functions under Deno
npm run test:migrations  # apply migrations to real Postgres + RLS checks (Docker)
npm run parity           # the shared score fixtures both engines must match

npm run test:all         # all of the above
```

Node 22.18+ runs TypeScript natively, which is why there is no transpile step.

### iOS — macOS with Xcode 16

```bash
brew install xcodegen
cp ios/Config.xcconfig.example ios/Config.xcconfig   # then fill it in
make ios-project
swift test --package-path ios/BeforeKit
make ios-test
```

Full setup — Supabase project, App Group, Sign in with Apple, StoreKit products
— is in **[docs/SETUP.md](docs/SETUP.md)**.

### Running without a backend

```bash
# In the Xcode scheme, add the launch argument:
-BEFOREUseMockData
```

Serves deterministic fixtures from `backend/shared/fixtures/ai-responses.json`.
The scores in those fixtures are asserted against the real engine by
`backend/tests/mock-provider.test.ts`, so a preview shows the verdict the server
would actually produce.

`AI_MOCK_MODE=true` does the same server-side. `loadConfig()` refuses to boot if
it is set while `APP_ENV=production`.

---

## The product rules

These are requirements, not preferences. Violating one is a critical review
finding, and most have a test.

1. **BYE must stay reachable.** Tested in both engines.
2. **Never judge the person.** Clothes, wardrobe fit, value — never
   attractiveness, body, weight, age, race, or any protected trait. Enforced by
   the prompt *and* by an output scan that blocks the analysis.
3. **Never fabricate** a price, brand, material, retailer, product name, or a
   shopping URL. Model-supplied URLs are discarded outright.
4. **The verdict is personal**, not objective: "is this good *for you*". With no
   wardrobe data, the app says so.
5. **Trust beats monetisation.** The verdict is computed before, and
   independently of, any commerce surface.
6. **The model never sets the score.** It emits signals; the engine computes.
7. **Entitlement is verified, never claimed.** Every App Store transaction is
   checked against a pinned Apple root before it grants anything.

---

## Testing

| Suite | Command | Runs on |
| --- | --- | --- |
| Backend (274 tests) | `npm run test:backend` | any OS |
| Migrations + RLS | `npm run test:migrations` | any OS with Docker |
| Edge function types | `npm run check:deno` | any OS |
| Score parity (Swift) | `swift test --package-path ios/BeforeKit` | macOS |
| App unit tests | `make ios-test` | macOS |
| UI tests | `make ios-test` | macOS |

The score engine exists in TypeScript and Swift. Both run the **same fixture
file**, and a cross-language contract test compares the two sources directly —
so drift fails a build rather than reaching a user. See DECISIONS.md §2.

---

## Documentation

| | |
| --- | --- |
| [docs/SETUP.md](docs/SETUP.md) | Supabase, Xcode, App Group, StoreKit, deploy |
| [docs/API.md](docs/API.md) | every `/v1` endpoint, request and response |
| [docs/AI.md](docs/AI.md) | providers, models, prompt and score versioning, cost |
| [docs/PRIVACY.md](docs/PRIVACY.md) | what is stored, what is not, deletion order |
| [docs/LIMITS.md](docs/LIMITS.md) | quota, rate limits, what "unlimited" means |
| [docs/APP_STORE.md](docs/APP_STORE.md) | listing draft and review notes |
| [docs/RELEASE.md](docs/RELEASE.md) | TestFlight: the twelve secrets and how to make them |
| [DECISIONS.md](DECISIONS.md) | every non-obvious choice and its trade-off |
| [TODO.md](TODO.md) | what is deliberately not built, and what is unverified |

---

## Status

**274 backend tests pass** on Windows with Node 22, and the Swift now compiles
and runs on CI.

The backend total includes Apple signature verification against a real OpenSSL
ECDSA certificate chain — the suite generates a second, independent chain and
proves the verifier rejects it, so the root pinning is demonstrated rather than
assumed.

| | |
| --- | --- |
| Backend tests, migrations, edge-function types | pass locally and on CI |
| `BeforeKit` + score parity | passes on a macOS runner |
| Xcode build | found eight compile errors over two runs; all fixed |
| App unit tests and UI tests | queued behind the build job |
| TestFlight | written, never run — needs twelve secrets (`docs/RELEASE.md`) |
| Live AI provider call | not executed |

`DECISIONS.md` §35 lists exactly what has and has not been run, and §36 covers
the Swift 6 isolation problem the build found. `TODO.md` §1 is what is left.
