#!/usr/bin/env bash
# Generator tests. Runs setup.sh --dry-run against fixture configs and asserts
# on the generated build/ tree. No Docker required.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

run() { # run <config-json-string>; populates $OUT, returns exit code
  local cfg; cfg="$(mktemp)"; printf '%s' "$1" >"$cfg"
  OUT="$(./setup.sh --dry-run "$cfg" 2>&1)"; local rc=$?
  rm -f "$cfg"; return $rc
}

gen() { # gen <config>: run setup.sh --dry-run and FAIL loudly if it errors
  run "$1" || bad "setup.sh unexpectedly failed: $OUT"
}

# --- rejection: zero capabilities ---
run '{"capabilities":{}}' && bad "zero caps should fail" || ok "zero caps rejected"

# --- rejection: auth without api ---
run '{"capabilities":{"auth":true}}' \
  && bad "auth without api should fail" \
  || { echo "$OUT" | grep -q "requires 'api'" && ok "auth->api enforced" || bad "auth->api message"; }

# --- rejection: dashboards without timeseries ---
run '{"capabilities":{"dashboards":true}}' \
  && bad "dashboards without timeseries should fail" \
  || { echo "$OUT" | grep -q "requires 'timeseries'" && ok "dashboards->timeseries enforced" || bad "dashboards->timeseries message"; }

# --- Dockerfile: gis off -> plain postgres base, no postgis ---
gen '{"capabilities":{"document_store":true}}'
grep -q '^FROM postgres:17' build/Dockerfile && ok "no-gis uses postgres base" || bad "no-gis base image"
grep -q 'postgis' build/Dockerfile && bad "no-gis must not mention postgis" || ok "no-gis omits postgis"

# --- Dockerfile: gis on -> postgis base ---
gen '{"capabilities":{"gis":true}}'
grep -q '^FROM postgis/postgis:17-3.5' build/Dockerfile && ok "gis uses postgis base" || bad "gis base image"

# --- Dockerfile: vector on -> pgvector apt install ---
gen '{"capabilities":{"vector":true}}'
grep -q 'postgresql-17-pgvector' build/Dockerfile && ok "vector installs pgvector" || bad "vector pgvector install"

# --- Dockerfile: api on -> pg_graphql .deb ---
gen '{"capabilities":{"document_store":true,"api":true}}'
grep -q 'pg_graphql' build/Dockerfile && ok "api fetches pg_graphql" || bad "api pg_graphql"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
