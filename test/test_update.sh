#!/usr/bin/env bash
# Update-mode tests. Drive setup.sh in `--update --dry-run --installed <csv>` mode,
# which prints a plan + per-phase delta SQL without touching Docker or a database.
set -uo pipefail
cd "$(dirname "$0")/.."
PROJ_ROOT="$PWD"

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

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
