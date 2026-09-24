---
name: pr-review
argument-hint: [pr-number]
---

Review PR #$ARGUMENTS.

1. `gh pr view $ARGUMENTS` and `gh pr diff $ARGUMENTS`.
2. Delegate to the `code-reviewer` agent for correctness and security.
3. Delegate to the `security-auditor` agent if the diff touches migrations,
   storage, auth, analytics, or anything under `backend/`.
4. Check the product rules in `.claude/rules/product-safety.md` yourself —
   these are the ones automation misses.
5. Confirm tests were added for the behaviour that changed.
6. Post a single consolidated review. Lead with CRITICAL items. If there are
   none, say so plainly rather than inventing nits.
