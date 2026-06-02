#!/usr/bin/env bash
# Functions-apply tests. Drive setup.sh --apply-functions --dry-run (prints the SQL it would apply,
# no Docker/DB, no config.json needed).
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

OUT="$(./setup.sh --apply-functions --dry-run 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "apply-functions --dry-run exits 0" || bad "apply dry-run rc=$RC ($OUT)"
echo "$OUT" | grep -q 'CREATE OR REPLACE FUNCTION submit_product' && ok "includes example function" || bad "example function missing"
echo "$OUT" | grep -q "NOTIFY pgrst, 'reload schema'" && ok "includes schema reload" || bad "reload missing"

# multiple files concatenated in deterministic sorted order
t1="functions/00_aaa_test.sql"; t2="functions/zz_zzz_test.sql"
printf -- '-- MARKER_AAA\n' > "$t1"; printf -- '-- MARKER_ZZZ\n' > "$t2"
O2="$(./setup.sh --apply-functions --dry-run 2>&1)"
{ echo "$O2" | grep -q 'MARKER_AAA' && echo "$O2" | grep -q 'MARKER_ZZZ'; } && ok "multi-file: both present" || bad "multi-file presence"
echo "$O2" | awk '/MARKER_AAA/{a=NR} /MARKER_ZZZ/{z=NR} END{exit !(a&&z&&a<z)}' && ok "multi-file: sorted order" || bad "multi-file order"
rm -f "$t1" "$t2"

# combination guards: apply-functions cannot combine with --update / --allow-drop / --installed
for combo in "--update" "--allow-drop" "--installed x"; do
  # shellcheck disable=SC2086
  o="$(./setup.sh --apply-functions $combo --dry-run 2>&1)"; r=$?
  { [ $r -ne 0 ] && echo "$o" | grep -qi 'cannot be combined'; } && ok "apply+$combo rejected" || bad "apply+$combo guard ($o)"
done

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
