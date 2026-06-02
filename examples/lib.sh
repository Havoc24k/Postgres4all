#!/usr/bin/env bash
# Shared helpers for the API examples. This file is SOURCED by the others, not run directly.
set -euo pipefail

# PostgREST base URL (override with BASE=... if you mapped a different port).
BASE=${BASE:-http://localhost:3000}

# Resolve the repo root from this file's location, so examples run from anywhere.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPOSE=(docker compose --env-file "$ROOT/build/.env" -f "$ROOT/build/docker-compose.yml")
_DBU=$(grep '^POSTGRES_USER=' "$ROOT/build/.env" | cut -d= -f2-)
_DBD=$(grep '^POSTGRES_DB='   "$ROOT/build/.env" | cut -d= -f2-)

# define_sql: read a SQL function definition from stdin, create it in the database, and tell
# PostgREST to reload its schema cache so the function becomes reachable at /rpc/<name>.
#
# A few capabilities (vector KNN, GIS distance, a row-locking dequeue) can't be expressed in
# PostgREST's URL grammar — they need a function. In a real project that SQL lives in functions/
# and you'd run `./postgres4all apply-functions`; we inline it here so each example stands alone.
define_sql() {
  { cat; printf "\nNOTIFY pgrst, 'reload schema';\n"; } \
    | "${COMPOSE[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$_DBU" -d "$_DBD" -qX >/dev/null
  sleep 1   # give PostgREST a moment to pick up the reload
}
