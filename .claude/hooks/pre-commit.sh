#!/usr/bin/env bash
# BEFORE pre-commit gate (PreToolUse:Bash).
# Reads the hook payload on stdin and only acts on `git commit`.
# Exit 2 blocks the action. Exit 0 allows it.
set -uo pipefail

PAYLOAD="$(cat 2>/dev/null || true)"
# Allow direct invocation (no stdin) for manual runs and for a real git hook.
if [ -n "$PAYLOAD" ]; then
  case "$PAYLOAD" in
    *"git commit"*) : ;;
    *) exit 0 ;;
  esac
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 0

staged() { git diff --cached --name-only --diff-filter=ACM 2>/dev/null; }
fail() { echo "BLOCKED: $1" >&2; exit 2; }

# 1. No secrets, ever.
if staged | grep -qE '(^|/)\.env$|(^|/)\.env\.(local|production|staging)$|AuthKey_.*\.p8$|\.pem$|\.p12$'; then
  fail "a secret-bearing file is staged"
fi
KEYFILES="$(staged | grep -E '^ios/.*\.(swift|plist|json)$' || true)"
if [ -n "$KEYFILES" ]; then
  if git diff --cached -- $KEYFILES | grep -qE '^\+.*(sk-ant-|sk-proj-|service_role|SUPABASE_SERVICE_ROLE_KEY|BEGIN PRIVATE KEY)'; then
    fail "server-side key material is being added to the iOS target"
  fi
fi

# 2. Backend logic must stay green.
if staged | grep -qE '^backend/'; then
  npm run --silent test:backend >/dev/null || fail "backend tests failed"
fi

# 3. Swift tests only where a toolchain exists.
if staged | grep -qE '\.swift$'; then
  if command -v swift >/dev/null 2>&1; then
    swift test --package-path ios/BeforeKit >/dev/null || fail "BeforeKit tests failed"
  else
    echo "note: no swift toolchain on this machine; Swift tests skipped" >&2
  fi
fi

echo "pre-commit checks passed"
exit 0
