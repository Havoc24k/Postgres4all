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

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
