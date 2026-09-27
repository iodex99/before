# Setup

Start to finish on a clean machine. Steps 1–2 work on any OS; the rest need macOS.

---

## 1. Backend tests, with nothing installed but Node

```bash
node --version          # must be 22.6 or newer
npm install
npm run test:backend    # 194 tests
```

No Supabase project, no API key, no Deno, no build step. Node 22 runs the
TypeScript directly.

```bash
npm run check:secrets   # fails if key material is anywhere in the repo
npm run parity          # the score fixtures both engines must reproduce
```

---

## 2. Supabase

### Local

```bash
brew install supabase/tap/supabase     # or see supabase.com/docs
supabase start
supabase db reset                      # applies migrations 0001 → 0008
```

`supabase start` prints an API URL, an anon key, and a service-role key. The
first two go in `ios/Config.xcconfig`; the third is server-side only and must
never reach the app.

### Hosted

1. Create a project at supabase.com.
2. Link and push:

   ```bash
   supabase link --project-ref <ref>
   supabase db push
   ```

3. Set the function secrets:

   ```bash
   cp .env.example .env          # fill it in — .env is git-ignored
   supabase secrets set --env-file .env
   ```

4. Deploy:

   ```bash
   supabase functions deploy analyze-purchase analysis me usage wardrobe \
       explain product-metadata subscription-sync account-delete account-export

   # Apple does not send a Supabase JWT, so this one is explicit.
   supabase functions deploy app-store-notifications --no-verify-jwt
   ```

   Getting that last flag wrong means Apple's notifications are rejected at the
   gateway and you never learn about a refund.

### Verify

```bash
curl -s -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $JWT" \
     "$SUPABASE_URL/functions/v1/usage"
```

A `200` with a usage body means auth, RLS, and entitlement resolution all work.

### Scheduled maintenance

Two functions should run on a schedule (pg_cron, or any external scheduler):

```sql
select cron.schedule('before-cleanup-images', '0 3 * * *',
                     $$ select public.cleanup_unsaved_analysis_images(); $$);
select cron.schedule('before-cleanup-cache',  '0 4 * * *',
                     $$ select public.cleanup_expired_cache(); $$);
```

The first is a privacy requirement, not housekeeping: it deletes images for
analyses the user never saved.

---

## 3. Sign in with Apple

1. **Apple Developer → Identifiers → App IDs**: create `com.yourcompany.before`
   and enable **Sign In with Apple**.
2. **Keys**: create a Sign in with Apple key, note the Key ID and Team ID,
   download the `.p8` **once** — Apple will not show it again.
3. **Supabase → Authentication → Providers → Apple**: enable it and enter the
   Services ID, Team ID, Key ID, and the `.p8` contents.

Apple supplies a user's name **only on first authorisation, and only if they
allow it**. `AuthService` captures it there and then; if it is missed, it is gone.
`display_name` being null forever is a normal state the UI handles.

---

## 4. App Group — required for the share extension

1. **Apple Developer → Identifiers → App Groups**: create
   `group.com.yourcompany.before`.
2. Add it to **both** App IDs: the app and `…before.ShareExtension`.
3. Set `APP_GROUP_IDENTIFIER` in `ios/Config.xcconfig`. Both `.entitlements`
   files read it from there, so there is one place to change.

If the identifier does not match across all three, `SharedInbox.isAvailable`
returns false and shares silently go nowhere. That is the first thing to check if
the share extension "does nothing".

---

## 5. Xcode

```bash
brew install xcodegen
cp ios/Config.xcconfig.example ios/Config.xcconfig
```

Fill in `Config.xcconfig`:

```
APP_BUNDLE_ID = com.yourcompany.before
APP_GROUP_IDENTIFIER = group.com.yourcompany.before
SUPABASE_URL = https:$(URL_SLASHES)your-project.supabase.co
SUPABASE_ANON_KEY = eyJ…
TERMS_URL = https:$(URL_SLASHES)yourdomain.com/terms
PRIVACY_URL = https:$(URL_SLASHES)yourdomain.com/privacy
SUPPORT_EMAIL = support@yourdomain.com
```

> `//` starts a comment in xcconfig, which mangles URLs. `$(URL_SLASHES)` is the
> standard workaround and is predefined in the template.

Then:

```bash
make ios-project        # generates ios/BEFORE.xcodeproj
open ios/BEFORE.xcodeproj
```

The `.xcodeproj` is generated and git-ignored — edit `ios/project.yml`, not the
project file (DECISIONS.md §16).

### Signing

Select your team on all four targets. The app and the share extension must share
the App Group capability.

---

## 6. StoreKit

### Local testing — no App Store Connect needed

The scheme already points at `ios/StoreKit/Products.storekit`. Run the app, open
the paywall, and purchase: prices, renewals, and restores all work against the
local configuration.

To drive edge cases, open `Products.storekit` in Xcode → **Editor → Subscription
Options**: expiry, billing retry, grace period, Ask to Buy. `SubscriptionTests`
exercises several of these through `SKTestSession`.

### App Store Connect

Create a subscription group `before_plus` with two auto-renewable products:

| Identifier | Duration | Reference price |
| --- | --- | --- |
| `before.plus.monthly` | 1 month | $6.99 |
| `before.plus.yearly` | 1 year | $69.99 |

The identifiers must match `AppConfig.Subscription`. Prices are **never**
hard-coded in the UI — everything comes from StoreKit, including the annual
saving percentage, which is computed from the two real prices.

### Apple Root CA G3 — required in production

Every signed transaction and every App Store notification is verified against a
**pinned** root certificate. It is configuration, not a constant in the source:
a certificate fingerprint written from memory would either break every purchase
or, worse, trust the wrong issuer.

```bash
curl -sO https://www.apple.com/appleca/AppleRootCA-G3.cer

# Linux
base64 -w0 AppleRootCA-G3.cer
# macOS
base64 -i AppleRootCA-G3.cer
```

Put the output in `APPLE_ROOT_CA_G3_BASE64`. **Production refuses to boot
without it**, because the alternative is silently accepting whatever the client
claims — the exact thing this verification exists to remove.

Also set `APPLE_BUNDLE_ID` to your real bundle identifier. It is checked against
every transaction: without it, a validly-signed transaction from any other App
Store app would verify here and could be replayed to grant Plus.

### App Store Server API — reconciliation

Create an **App Store Connect API key** with In-App Purchase access and set
`APPLE_ISSUER_ID`, `APPLE_KEY_ID`, and `APPLE_PRIVATE_KEY` (all three, or none).

Without them, signatures are still verified but the backend cannot ask Apple for
the current state — so a renewal or a refund is only learned from a notification.

### App Store Server Notifications V2

In App Store Connect → your app → **App Information → App Store Server
Notifications**, set the Production and Sandbox URLs to:

```
https://<project>.supabase.co/functions/v1/app-store-notifications
```

This is the only way BEFORE learns about a refund, a revocation, or a billing
failure that happens while the app is closed. Without it, a refunded
subscription keeps its entitlement until the user next opens the app.

Verify with **Request a Test Notification** in App Store Connect, then:

```sql
select notification_type, processed_at, processing_error
from app_store_notifications order by received_at desc limit 5;
```

---

## 7. Run it

```bash
swift test --package-path ios/BeforeKit    # pure logic, fastest feedback
make ios-test                               # unit + UI tests
```

Without a backend, add the launch argument `-BEFOREUseMockData` to the scheme.
Every screen works against fixtures.

---

## 8. AI provider

```
AI_PROVIDER=anthropic
AI_MODEL=claude-opus-5
ANTHROPIC_API_KEY=sk-ant-…
```

For development, skip the key entirely:

```
AI_MOCK_MODE=true
```

`loadConfig()` **refuses to boot** if that is set while `APP_ENV=production` — a
mocked verdict reaching a paying user is worse than an outage, because it looks
real.

Model choice and cost: `docs/AI.md`.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Info.plist is missing SUPABASE_URL` | `ios/Config.xcconfig` not created, or `make ios-project` not re-run |
| Share extension appears but nothing arrives | App Group mismatch across the two entitlements and the xcconfig |
| Every analysis returns `unauthorized` | the anon key is in the `Authorization` header instead of `apikey` |
| Every request returns empty arrays | RLS is working and the JWT belongs to a different user |
| Paywall shows no products | the `.storekit` file is not selected in the scheme, or the identifiers do not match |
| `url_unreadable` on a real shop | normal — that shop blocks automated readers. The screenshot path is the answer |
| Backend tests fail on `node --test` | Node older than 22.6, which cannot run `.ts` natively |
