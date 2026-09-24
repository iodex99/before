---
name: fix-issue
argument-hint: [issue-number]
---

Fix GitHub issue #$ARGUMENTS in BEFORE:

1. `gh issue view $ARGUMENTS` — read the issue and its comments.
2. Locate the relevant source. iOS logic lives in `ios/BeforeKit` or
   `ios/BEFORE/`; server logic in `backend/shared/` or
   `backend/supabase/functions/`.
3. Implement the minimal fix. Do not bundle refactors into a bug fix.
4. Write a regression test that fails without the fix.
5. Run everything that applies:
   - `npm run test:backend`
   - `swift test --package-path ios/BeforeKit`  (macOS only)
   - `xcodebuild test -scheme BEFORE ...`       (macOS only)
6. If scoring or verdict behaviour changed, bump the version constant and
   say so in the commit body.
7. Commit: `fix: <description> (closes #$ARGUMENTS)`
