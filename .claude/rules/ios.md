---
paths:
  - "ios/**/*.swift"
---

# iOS Rules

## Architecture
- View → ViewModel → Repository → Service. No HTTP, JSON, or scoring in a `View`.
- ViewModels are `@Observable` final classes, `@MainActor`, with injected
  dependencies. No singletons reached for inside a ViewModel body.
- Anything pure and testable (models, scoring, formatting, validation) belongs in
  the `BeforeKit` package, not the app target, so it runs under `swift test`.

## SwiftUI
- Style through `BeforeTheme` tokens only. No literal `Color(...)`, no literal
  corner radii, no literal font sizes in feature code.
- Use the components in `Components/` before writing new styling.
- Lists use `LazyVStack`/`List` with pagination. Never load full history at once.
- Every screen defines all four of: loading, empty, success, failure.

## Concurrency
- `async/await` only. No completion handlers, no `DispatchQueue` for new code.
- Image decode, resize, compression, and JSON work run off the main actor.
- Long-running work is cancellable and cancelled in `onDisappear` where relevant.

## Safety
- No force-unwrap and no `try!` outside test targets.
- No secrets in source, `Info.plist`, or `UserDefaults`. Tokens go to the Keychain.
- `UserDefaults` may cache UI state but never grants entitlement. `isPlus` comes
  from verified StoreKit entitlements.

## Accessibility
- Dynamic Type must not clip. Verdicts are conveyed by text, not colour alone.
- Every interactive element has an accessibility label and a ≥44pt target.
