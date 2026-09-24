---
name: deploy
argument-hint: [staging|production]
---

Deploy the BEFORE backend to $ARGUMENTS.

Pre-flight — stop if any of these fail:
1. `npm run test:backend` is green.
2. `npm run check:secrets` reports no key material under `ios/`.
3. `AI_MOCK_MODE` is not `true` for a production target.
4. Every new migration has an RLS policy for each new user-owned table.

Deploy:
5. `supabase db push --linked` — migrations first, always.
6. `supabase functions deploy analyze-purchase product-metadata \
    subscription-sync account-delete usage me`
7. `supabase secrets set --env-file .env.$ARGUMENTS`

Verify:
8. Hit `/v1/me` and `/v1/usage` with a test token; both must return 200.
9. Run one `AI_MOCK_MODE` analysis end-to-end against the deployed function.
10. Report the deployed function versions. Do not claim success without step 8.
