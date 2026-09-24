#!/usr/bin/env bash
#
# Applies every migration to a throwaway Postgres and runs the functional RLS
# checks against it.
#
# Needs Docker and nothing else — no Supabase CLI, no local Postgres, no
# network beyond pulling the image once. Runs in about fifteen seconds, which
# is what makes it usable as a pre-push check rather than only in CI.
#
#   ./backend/scripts/verify-migrations.sh
#
# In CI the database is supplied as a service container, so pass its URL:
#
#   DATABASE_URL=postgres://... ./backend/scripts/verify-migrations.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATIONS="$ROOT/backend/supabase/migrations"
TESTS="$ROOT/backend/supabase/tests"
SEED="$ROOT/backend/supabase/seed/seed.sql"

IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
CONTAINER="before-verify-$$"
OWN_CONTAINER=0

cleanup() {
  if [ "$OWN_CONTAINER" = "1" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- Get a database ----------------------------------------------------------

if [ -n "${DATABASE_URL:-}" ]; then
  echo "Using the supplied DATABASE_URL"
  PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --quiet)
  RUN_SQL_FILE() { "${PSQL[@]}" -f "$1"; }
else
  command -v docker >/dev/null 2>&1 || {
    echo "Docker is required, or set DATABASE_URL to an existing database." >&2
    exit 1
  }

  echo "Starting $IMAGE ..."
  OWN_CONTAINER=1
  docker run -d --rm --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=before_test \
    "$IMAGE" >/dev/null

  # The server restarts once during first-time initialisation, so a single
  # pg_isready can succeed against the bootstrap instance and then the real
  # connection fails. Require several consecutive successes.
  printf 'Waiting for Postgres'
  READY=0
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U postgres -d before_test >/dev/null 2>&1; then
      READY=$((READY + 1))
      [ "$READY" -ge 3 ] && break
    else
      READY=0
    fi
    printf '.'
    sleep 1
  done
  echo

  [ "$READY" -ge 3 ] || { echo "Postgres did not become ready" >&2; exit 1; }

  RUN_SQL_FILE() {
    docker exec -i "$CONTAINER" \
      psql -U postgres -d before_test -v ON_ERROR_STOP=1 --quiet < "$1"
  }
fi

# --- Apply -------------------------------------------------------------------

echo
echo "Bootstrapping the Supabase-compatible schema ..."
RUN_SQL_FILE "$TESTS/00_bootstrap.sql"

echo
echo "Applying migrations:"
for file in "$MIGRATIONS"/*.sql; do
  printf '  %s ... ' "$(basename "$file")"
  RUN_SQL_FILE "$file"
  echo "ok"
done

# --- Verify ------------------------------------------------------------------

echo
echo "Running RLS and constraint checks:"
RUN_SQL_FILE "$TESTS/10_rls_checks.sql"

# The seed runs last, against the now-empty database, so a broken seed is
# caught here rather than on someone's first `supabase db reset`.
if [ -f "$SEED" ]; then
  echo
  printf 'Applying development seed ... '
  RUN_SQL_FILE "$SEED"
  echo "ok"
fi

echo
echo "Migrations verified."
