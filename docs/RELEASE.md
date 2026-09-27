# Releasing to TestFlight

`.github/workflows/testflight.yml` archives, signs and uploads a build.

It does **not** run on push. A TestFlight build costs a build number, a
processing slot and a notification to every tester, so it runs when you ask:

- **Actions → TestFlight → Run workflow**, with a "What to Test" note, or
- **push a version tag**: `git tag v1.0.1 && git push origin v1.0.1`

The build number is `github.run_number`, which only ever increases — the one
thing App Store Connect insists on. The marketing version comes from the tag
(`v1.0.1` → `1.0.1`), or defaults to `1.0` on a manual run.

---

## The twelve secrets

Settings → Secrets and variables → Actions. The workflow checks all of them on
its first step and fails with a list of what is missing, rather than dying on a
signing error forty minutes in.

| Secret | Where it comes from |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer → Membership, the 10-character Team ID |
| `APP_BUNDLE_ID` | e.g. `com.yourcompany.before` — must match `Config.xcconfig` |
| `BUILD_CERTIFICATE_BASE64` | your Apple Distribution certificate, as base64 `.p12` |
| `P12_PASSWORD` | the password you set when exporting that `.p12` |
| `PROVISIONING_PROFILE_BASE64` | App Store profile for the app, base64 |
| `EXTENSION_PROVISIONING_PROFILE_BASE64` | App Store profile for the share extension, base64 |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Integrations → Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | same page, above the key list |
| `APP_STORE_CONNECT_PRIVATE_KEY` | contents of the `AuthKey_XXXX.p8` |
| `SUPABASE_URL` | your project URL |
| `SUPABASE_ANON_KEY` | the publishable anon key |
| `APP_GROUP_IDENTIFIER` | e.g. `group.com.yourcompany.before` |

Optional: `TERMS_URL`, `PRIVACY_URL`, `SUPPORT_EMAIL`.

**Two profiles, not one.** BEFORE ships an app *and* a share extension, and
each needs its own App Store provisioning profile. A build that signs the app
but not the extension fails at export with an unhelpful message.

---

## Producing the signing material

### The distribution certificate

On a Mac, in Keychain Access:

1. **Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority**. Save to disk.
2. Apple Developer → Certificates → **+** → **Apple Distribution** → upload the
   request → download the `.cer` → double-click to install.
3. In Keychain Access, find it under **My Certificates**, right-click →
   **Export** → `.p12`, and set a password. That password is `P12_PASSWORD`.

```bash
base64 -i Certificates.p12 | pbcopy     # → BUILD_CERTIFICATE_BASE64
```

### The two provisioning profiles

Apple Developer → Profiles → **+** → **App Store Connect**, once per bundle id:

- `com.yourcompany.before`
- `com.yourcompany.before.ShareExtension`

```bash
base64 -i BEFORE_AppStore.mobileprovision | pbcopy       # → PROVISIONING_PROFILE_BASE64
base64 -i BEFORE_Ext_AppStore.mobileprovision | pbcopy   # → EXTENSION_PROVISIONING_PROFILE_BASE64
```

### The App Store Connect API key

App Store Connect → Users and Access → **Integrations** → Keys → **+**, with
the **App Manager** role. Download the `.p8` — Apple shows it once.

```bash
cat AuthKey_XXXXXXXXXX.p8 | pbcopy      # → APP_STORE_CONNECT_PRIVATE_KEY
```

This is the same kind of key as the one in `.env` for subscription
verification, but it is **not** the same key: that one needs In-App Purchase
access, this one needs App Manager. Generate two.

---

## What the workflow does

1. **Checks the secrets.** Fails immediately with a list if any are missing.
2. **Creates a throwaway keychain** with a random single-use password, imports
   the certificate, and installs both profiles by UUID (Xcode finds them by
   UUID, not filename).
3. **Writes `Config.xcconfig`** from the secrets and generates the project with
   XcodeGen.
4. **Archives** with manual signing, `MARKETING_VERSION` from the tag and
   `CURRENT_PROJECT_VERSION` from the run number.
5. **Exports** an IPA with an `ExportOptions.plist` naming both profiles.
6. **Uploads** with `xcrun altool` authenticated by the API key — no password,
   no 2FA prompt.
7. **Deletes the keychain, the profiles and the `.p8`**, on success *and* on
   failure. A signing keychain left on a runner is a credential left on a
   runner; there is a test asserting that step runs under `always()`.

---

## Before the first run

- [ ] The app record exists in App Store Connect with the matching bundle id.
      The upload has nowhere to go otherwise.
- [ ] Both subscription products exist (`before.plus.monthly`,
      `before.plus.yearly` in group `before_plus`) — see `docs/SETUP.md`.
- [ ] Export compliance is answered. `ITSAppUsesNonExemptEncryption` is already
      `false` in `Info.plist`, so this should not prompt.
- [ ] The **iOS** workflow is green. There is no point signing a build that
      does not compile.

---

## When it goes wrong

| Symptom | Cause |
| --- | --- |
| `missing secrets: …` on step one | exactly what it says; nothing was attempted |
| `No signing certificate "iOS Distribution" found` | the `.p12` holds a Development certificate, or `P12_PASSWORD` is wrong |
| `Provisioning profile ... doesn't match` | profile is Development or Ad Hoc, not App Store |
| Export fails naming the extension | `EXTENSION_PROVISIONING_PROFILE_BASE64` missing or for the wrong bundle id |
| `The provided entity includes an attribute with a value that has already been used` | that build number was used; re-run, since `run_number` will have moved on |
| Upload succeeds, nothing in TestFlight | processing takes 5–15 minutes; check email for an export-compliance or ITMS rejection |

### A caveat worth knowing

The upload uses `xcrun altool`, which Apple has been moving away from for years
without removing. If it ever stops working, the same upload can be done with
`xcrun iTMSTransporter` or `fastlane pilot`; only the final step changes.

**None of this workflow has been executed.** It is written against Apple's
documented behaviour, but signing is the part of iOS CI that most reliably
surprises you, so expect to iterate on the first run. Everything before the
archive step is cheap to retry.
