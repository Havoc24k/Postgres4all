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

# --- ADD: new data cap, api not involved ---
upd '{"capabilities":{"document_store":true,"vector":true},"seed_demo_data":true}' 'document_store'
section ADD | grep -q 'CREATE EXTENSION IF NOT EXISTS vector' && ok "add: vector ext" || bad "add vector ext"
section ADD | grep -q 'CREATE TABLE documents' && ok "add: documents schema" || bad "add documents"
section ADD | grep -q 'INSERT INTO documents' && ok "add: vector seed" || bad "add vector seed"
section ADD | grep -q 'CREATE TABLE products' && bad "add must not recreate products" || ok "add omits installed products"
section ADD | grep -q "INSERT INTO p4a_meta.capabilities (cap) VALUES ('vector')" && ok "add: meta insert vector" || bad "add meta vector"

# --- ADD: seed off ---
upd '{"capabilities":{"document_store":true,"vector":true},"seed_demo_data":false}' 'document_store'
section ADD | grep -q 'INSERT INTO documents' && bad "seed off must omit inserts" || ok "add: seed off"

# --- ADD: api already installed, add data cap -> grant the NEW table, AFTER its CREATE ---
upd '{"capabilities":{"document_store":true,"search":true,"api":true}}' 'document_store,api'
section ADD | grep -q 'GRANT SELECT ON articles TO anon, authenticated' && ok "add: grant new table" || bad "add grant new table"
section ADD | awk '/CREATE TABLE articles/{c=NR} /GRANT SELECT ON articles/{g=NR} END{exit !(c&&g&&c<g)}' && ok "add: create-before-grant" || bad "add ordering"
section PRE | grep -q 'CREATE ROLE' && bad "no role create when api already installed" || ok "add: no role recreate"

# --- ADD: api itself newly added -> Phase-0 idempotent roles; Phase-3 pg_graphql + grants on installed tables ---
upd '{"capabilities":{"document_store":true,"api":true},"api":{"authenticator_password":"apw"}}' 'document_store'
section PRE | grep -q "pg_roles WHERE rolname='authenticator'" && ok "add api: idempotent role create in PRE" || bad "add api roles"
section ADD | grep -q 'CREATE EXTENSION IF NOT EXISTS pg_graphql' && ok "add api: pg_graphql" || bad "add api pg_graphql"
section ADD | grep -q 'GRANT SELECT ON products TO anon, authenticated' && ok "add api: grants installed table" || bad "add api grants installed"
section ADD | grep -q "INSERT INTO p4a_meta.capabilities (cap) VALUES ('api')" && ok "add api: meta insert" || bad "add api meta"

# --- ADD: api + brand-new data cap together -> new table granted in ADD loop AFTER its create ---
upd '{"capabilities":{"document_store":true,"vector":true,"api":true},"api":{"authenticator_password":"apw"}}' 'document_store'
section ADD | awk '/CREATE TABLE documents/{c=NR} /GRANT SELECT ON documents/{g=NR} END{exit !(c&&g&&c<g)}' && ok "add api+new cap: documents create-before-grant" || bad "add api+new cap ordering"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
