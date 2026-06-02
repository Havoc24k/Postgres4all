#!/usr/bin/env bash
# Update-mode tests. Drive setup.sh in `--update --dry-run --installed <csv>` mode,
# which prints a plan + per-phase delta SQL without touching Docker or a database.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

# upd <config-json> <installed-csv> [extra-flags...]; sets $OUT, returns rc
upd() {
  local cfg; cfg="$(mktemp)"; printf '%s' "$1" >"$cfg"; shift
  local installed="$1"; shift
  OUT="$(./setup.sh --update --dry-run --installed "$installed" "$@" "$cfg" 2>&1)"; local rc=$?
  rm -f "$cfg"; return $rc
}
# section <NAME>: extract the body printed between "===== NAME =====" and the next "===== " marker
section() { awk -v s="===== $1 =====" '$0==s{f=1;next} /^===== /{f=0} f' <<<"$OUT"; }

# --- flag wiring: --allow-drop without --update is an error ---
cfg="$(mktemp)"; printf '{"capabilities":{"document_store":true}}' >"$cfg"
out="$(./setup.sh --allow-drop --dry-run "$cfg" 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q 'requires --update'; } && ok "--allow-drop requires --update" || bad "--allow-drop guard"
rm -f "$cfg"

# --- plan: ADD computed from installed vs target ---
upd '{"capabilities":{"document_store":true,"vector":true}}' 'document_store'
echo "$OUT" | grep -q 'ADD: vector' && ok "plan ADD=vector" || bad "plan ADD"
echo "$OUT" | grep -q 'REMOVE: (none)' && ok "plan REMOVE none" || bad "plan REMOVE none"

# --- plan: REMOVE requires --allow-drop ---
upd '{"capabilities":{"document_store":true}}' 'document_store,search'
{ [ $? -ne 0 ] && echo "$OUT" | grep -q 'search'; } && ok "REMOVE without --allow-drop refuses" || bad "REMOVE refusal"

# --- plan: REMOVE allowed with --allow-drop ---
upd '{"capabilities":{"document_store":true}}' 'document_store,search' --allow-drop
echo "$OUT" | grep -q 'REMOVE: search' && ok "plan REMOVE=search" || bad "plan REMOVE allow-drop"

# --- plan: empty delta -> already up to date ---
upd '{"capabilities":{"document_store":true}}' 'document_store'
echo "$OUT" | grep -qi 'up to date' && ok "empty delta up-to-date" || bad "empty delta"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
