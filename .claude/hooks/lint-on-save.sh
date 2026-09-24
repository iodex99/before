#!/usr/bin/env bash
# Runs after Edit/Write. Formats what it can; never blocks the edit.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 0

if command -v swiftformat >/dev/null 2>&1; then
  swiftformat ios --quiet 2>/dev/null || true
fi
if command -v deno >/dev/null 2>&1; then
  deno fmt backend --quiet 2>/dev/null || true
fi
exit 0
