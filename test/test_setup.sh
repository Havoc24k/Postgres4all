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

# --- extensions: only needed CREATE EXTENSION lines ---
gen '{"capabilities":{"search":true,"vector":true}}'
grep -q 'CREATE EXTENSION IF NOT EXISTS pg_trgm' build/init/01-extensions.sql && ok "search -> pg_trgm" || bad "search ext"
grep -q 'CREATE EXTENSION IF NOT EXISTS vector' build/init/01-extensions.sql && ok "vector -> vector ext" || bad "vector ext"
grep -q 'postgis' build/init/01-extensions.sql && bad "no postgis ext when gis off" || ok "no postgis ext"

# --- schema assembly: only enabled tables ---
gen '{"capabilities":{"document_store":true},"seed_demo_data":true}'
grep -q 'CREATE TABLE products' build/init/02-schema.sql && ok "schema has products" || bad "schema products"
grep -q 'CREATE TABLE jobs' build/init/02-schema.sql && bad "must omit jobs" || ok "schema omits jobs"
grep -q "INSERT INTO products" build/init/02-schema.sql && ok "seed included when on" || bad "seed on"

# --- seed toggle off: schema but no inserts ---
gen '{"capabilities":{"document_store":true},"seed_demo_data":false}'
grep -q 'CREATE TABLE products' build/init/02-schema.sql && ok "schema present, seed off" || bad "schema seed-off"
grep -q 'INSERT INTO products' build/init/02-schema.sql && bad "no inserts when seed off" || ok "no inserts when seed off"

# --- canonical order: timeseries before dashboards ---
gen '{"capabilities":{"timeseries":true,"dashboards":true}}'
awk '/CREATE TABLE events/{e=NR} /event_daily/{d=NR} END{exit !(e && d && e<d)}' build/init/02-schema.sql \
  && ok "timeseries precedes dashboards" || bad "order timeseries/dashboards"

# --- api off: no roles file, no grants file ---
gen '{"capabilities":{"document_store":true}}'
[ -f build/init/00-roles.sh ] && bad "no roles file when api off" || ok "no roles file (api off)"
[ -f build/init/03-api-grants.sql ] && bad "no grants when api off" || ok "no grants (api off)"

# --- api on: roles + grants scoped to enabled tables ---
gen '{"capabilities":{"document_store":true,"search":true,"api":true}}'
[ -f build/init/00-roles.sh ] && ok "roles file present (api on)" || bad "roles file missing"
grep -q 'GRANT SELECT ON products' build/init/03-api-grants.sql && ok "grants products" || bad "grants products"
grep -q 'articles' build/init/03-api-grants.sql && ok "grants articles" || bad "grants articles"
grep -q 'jobs' build/init/03-api-grants.sql && bad "must not grant jobs (off)" || ok "omits jobs grant"

# --- auth on: notes CRUD grant ---
gen '{"capabilities":{"document_store":true,"api":true,"auth":true}}'
grep -q 'GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated' build/init/03-api-grants.sql \
  && ok "notes CRUD grant" || bad "notes CRUD grant"

# --- compose: db always, postgrest only with api ---
gen '{"capabilities":{"document_store":true}}'
grep -q 'services:' build/docker-compose.yml && ok "compose has services" || bad "compose services"
grep -q 'postgrest' build/docker-compose.yml && bad "no postgrest when api off" || ok "no postgrest (api off)"
grep -q 'POSTGRES_PASSWORD=' build/.env && ok ".env has postgres pw" || bad ".env postgres pw"
grep -q 'JWT_SECRET=' build/.env && bad "no JWT_SECRET when api off" || ok ".env omits jwt (api off)"

# --- compose: api on -> postgrest service + secrets ---
gen '{"capabilities":{"document_store":true,"api":true}}'
grep -q 'postgrest' build/docker-compose.yml && ok "postgrest present (api on)" || bad "postgrest missing"
grep -q 'JWT_SECRET=' build/.env && ok ".env has jwt (api on)" || bad ".env jwt"
grep -q 'AUTHENTICATOR_PASSWORD=' build/.env && ok ".env has authenticator pw" || bad ".env authenticator pw"

# --- secrets honored from config when provided ---
gen '{"capabilities":{"document_store":true},"postgres":{"password":"hunter2xyz"}}'
grep -q 'POSTGRES_PASSWORD=hunter2xyz' build/.env && ok "config password honored" || bad "config password"

# --- security: build/.env is chmod 600 and secret values are not printed ---
gen '{"capabilities":{"document_store":true,"api":true}}'
SEC_OUT="$OUT"
perm="$(stat -c '%a' build/.env)"
[ "$perm" = 600 ] && ok ".env is chmod 600" || bad ".env perms ($perm)"
echo "$SEC_OUT" | grep -q 'JWT_SECRET=' && bad "secret value leaked to stdout" || ok "no secret value in stdout"
echo "$SEC_OUT" | grep -q 'written to build/.env' && ok "secret notice printed" || bad "missing secret notice"

# --- security: ports bind to localhost by default, widen on publish_externally ---
gen '{"capabilities":{"document_store":true}}'
grep -q '127.0.0.1:5432:5432' build/docker-compose.yml && ok "db bound to localhost by default" || bad "db not localhost-bound"
gen '{"capabilities":{"document_store":true,"api":true},"postgres":{"publish_externally":true}}'
grep -q '"5432:5432"' build/docker-compose.yml && ok "publish_externally widens db bind" || bad "publish_externally db bind"
grep -q '"3000:3000"' build/docker-compose.yml && ok "publish_externally widens api bind" || bad "publish_externally api bind"
grep -q '127.0.0.1' build/docker-compose.yml && bad "should not localhost-bind when external" || ok "no localhost bind when external"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
