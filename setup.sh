#!/usr/bin/env bash
set -euo pipefail

CAPS=(document_store job_queue search vector gis timeseries dashboards api auth)

die() { echo "ERROR: $*" >&2; exit 1; }

declare -A EXT_OF=( [search]=pg_trgm [vector]=vector [gis]=postgis [api]=pg_graphql )
declare -A READ_TABLE=(
  [document_store]=products [job_queue]=jobs [search]=articles
  [vector]=documents [gis]=places [timeseries]=events [dashboards]=event_daily
)

_compose() { docker compose --env-file build/.env -f build/docker-compose.yml "$@"; }
_pgdata_volume_name() { _compose config --format json 2>/dev/null | jq -r '.volumes.pgdata.name // empty'; }
_db_cid() { _compose ps -q db 2>/dev/null; }
_psql_q() { _compose exec -T db psql -tAqc "$1" -U "$PG_USER" -d "$PG_DB"; }
_apply_sql() { _compose exec -T db psql -v ON_ERROR_STOP=1 --single-transaction -U "$PG_USER" -d "$PG_DB"; }

_wait_db_healthy() {
  local i cid
  for i in $(seq 1 30); do
    cid="$(_db_cid)"
    if [ -n "$cid" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = healthy ]; then
      return 0
    fi
    sleep 2
  done
  die "database did not become healthy"
}

# up -d with rebuild + --remove-orphans, with a legacy-builder fallback for buildx < 0.17.
_build_up() {
  local err; err="$(mktemp)"
  trap 'rm -f "$err"' RETURN
  if _compose up -d --build --remove-orphans 2>"$err"; then rm -f "$err"; return 0; fi
  if grep -qi 'buildx' "$err"; then
    DOCKER_BUILDKIT=0 docker build -t postgres4all:generated build/ \
      && _compose up -d --no-build --remove-orphans
  else
    cat "$err" >&2; rm -f "$err"; die "docker build/up failed"
  fi
  rm -f "$err"
}

query_installed() {
  # Start ONLY db (not postgrest, whose role may not exist yet); --remove-orphans clears a
  # now-absent postgrest. Volume already confirmed to exist by the caller.
  _compose up -d --remove-orphans db
  _wait_db_healthy
  local reg; reg="$(_psql_q "SELECT to_regclass('p4a_meta.capabilities')")"
  [ "$reg" = "p4a_meta.capabilities" ] || die "no p4a_meta.capabilities table — this does not look like a managed install."
  _psql_q "SELECT string_agg(cap, ',') FROM p4a_meta.capabilities" | tr -d '[:space:]'
}

emit_pre_sql() {
  # Roles, created idempotently on the CURRENT image BEFORE the rebuild (only when api is newly added),
  # so PostgREST (started in Phase 2) finds the authenticator role.
  local apw apw_esc
  apw="$(grep '^AUTHENTICATOR_PASSWORD=' build/.env | cut -d= -f2-)"
  apw_esc="${apw//\'/\'\'}"
  cat <<SQL
DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF; END \$\$;
DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF; END \$\$;
DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '${apw_esc}'; END IF; END \$\$;
GRANT anon, authenticated TO authenticator;
SQL
  return 0
}

emit_add_sql() {
  local SEED; SEED="$(jq -r 'if .seed_demo_data == null then "true" else (.seed_demo_data|tostring) end' "$CONFIG")"
  local api_added=0; for c in "${ADD[@]}"; do [ "$c" = api ] && api_added=1; done
  local api_eff=0; [ "${EN[api]}" = 1 ] && api_eff=1   # api present after this delta

  if [ "$api_added" = 1 ]; then
    echo "CREATE EXTENSION IF NOT EXISTS pg_graphql;"
    echo "GRANT USAGE ON SCHEMA public TO anon, authenticated;"
    local rt=""
    for c in document_store job_queue search vector gis timeseries dashboards; do
      [ "${INST[$c]:-0}" = 1 ] && rt="${rt:+$rt, }${READ_TABLE[$c]}"
    done
    [ -n "$rt" ] && echo "GRANT SELECT ON $rt TO anon, authenticated;"
    [ "${INST[auth]:-0}" = 1 ] && echo "GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;"
    echo "GRANT USAGE ON SCHEMA graphql TO anon, authenticated;"
    echo "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql TO anon, authenticated;"
    echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;"
  fi

  local SCHEMA_ORDER=(document_store job_queue search vector gis timeseries dashboards auth)
  for c in "${SCHEMA_ORDER[@]}"; do
    local in_add=0; for a in "${ADD[@]}"; do [ "$a" = "$c" ] && in_add=1; done
    [ "$in_add" = 1 ] || continue
    [ -n "${EXT_OF[$c]:-}" ] && echo "CREATE EXTENSION IF NOT EXISTS ${EXT_OF[$c]};"
    cat "init/capabilities/$c.schema.sql"; echo
    if [ "$SEED" = "true" ] && [ -f "init/capabilities/$c.seed.sql" ]; then cat "init/capabilities/$c.seed.sql"; echo; fi
    if [ "$api_eff" = 1 ]; then
      [ -n "${READ_TABLE[$c]:-}" ] && echo "GRANT SELECT ON ${READ_TABLE[$c]} TO anon, authenticated;"
      [ "$c" = auth ] && echo "GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;"
    fi
    echo "INSERT INTO p4a_meta.capabilities (cap) VALUES ('$c') ON CONFLICT (cap) DO NOTHING;"
  done

  [ "$api_added" = 1 ] && echo "INSERT INTO p4a_meta.capabilities (cap) VALUES ('api') ON CONFLICT (cap) DO NOTHING;"
  return 0
}

emit_remove_sql() {
  local api_removed=0; for c in "${REMOVE[@]}"; do [ "$c" = api ] && api_removed=1; done
  local SCHEMA_ORDER=(document_store job_queue search vector gis timeseries dashboards auth)
  local i c r in_rem
  for (( i=${#SCHEMA_ORDER[@]}-1 ; i>=0 ; i-- )); do
    c="${SCHEMA_ORDER[$i]}"
    in_rem=0; for r in "${REMOVE[@]}"; do [ "$r" = "$c" ] && in_rem=1; done
    [ "$in_rem" = 1 ] || continue
    cat "init/capabilities/$c.drop.sql"; echo
    [ -n "${EXT_OF[$c]:-}" ] && echo "DROP EXTENSION IF EXISTS ${EXT_OF[$c]};"
    echo "DELETE FROM p4a_meta.capabilities WHERE cap = '$c';"
  done
  if [ "$api_removed" = 1 ]; then
    echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM anon;"
    echo "DROP OWNED BY authenticator, anon, authenticated;"
    echo "DROP ROLE IF EXISTS authenticator;"
    echo "DROP ROLE IF EXISTS authenticated;"
    echo "DROP ROLE IF EXISTS anon;"
    echo "DROP EXTENSION IF EXISTS pg_graphql;"
    echo "DELETE FROM p4a_meta.capabilities WHERE cap = 'api';"
  fi
  return 0
}

emit_functions_sql() {
  # Concatenate functions/*.sql in deterministic (LC_ALL=C) sorted order; print nothing if none exist.
  local f found=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    found=1
    printf -- '-- %s\n' "$f"
    cat "$f"
    echo
  done < <(printf '%s\n' functions/*.sql | LC_ALL=C sort)
  [ "$found" = 1 ] && echo "NOTIFY pgrst, 'reload schema';"
  return 0
}

DRY_RUN=0
UPDATE=0
ALLOW_DROP=0
INSTALLED_CSV=""
INSTALLED_GIVEN=0
APPLY_FUNCTIONS=0
CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --update) UPDATE=1 ;;
    --allow-drop) ALLOW_DROP=1 ;;
    --installed)
      [ $# -ge 2 ] || die "--installed requires a value"
      case "$2" in --*) die "--installed requires a value (got flag '$2')";; esac
      INSTALLED_CSV="$2"; INSTALLED_GIVEN=1; shift ;;
    --installed=*) INSTALLED_CSV="${1#*=}"; INSTALLED_GIVEN=1 ;;
    --apply-functions) APPLY_FUNCTIONS=1 ;;
    --*) die "unknown option: $1" ;;
    *) CONFIG="$1" ;;
  esac
  shift
done
if [ "$APPLY_FUNCTIONS" = 1 ] && [ "$UPDATE" = 1 ];          then die "--apply-functions cannot be combined with --update"; fi
if [ "$APPLY_FUNCTIONS" = 1 ] && [ "$ALLOW_DROP" = 1 ];      then die "--apply-functions cannot be combined with --allow-drop"; fi
if [ "$APPLY_FUNCTIONS" = 1 ] && [ "$INSTALLED_GIVEN" = 1 ]; then die "--apply-functions cannot be combined with --installed"; fi
if [ "$ALLOW_DROP" = 1 ] && [ "$UPDATE" = 0 ]; then die "--allow-drop requires --update"; fi
if [ "$INSTALLED_GIVEN" = 1 ] && [ "$UPDATE" = 0 ]; then die "--installed requires --update"; fi
if [ "$INSTALLED_GIVEN" = 1 ] && [ -z "$INSTALLED_CSV" ]; then die "--installed requires a non-empty value"; fi
if [ "$APPLY_FUNCTIONS" = 1 ]; then
  cd "$(dirname "$0")"   # resolve functions/*.sql relative to the script
  if ! ls functions/*.sql >/dev/null 2>&1; then
    echo "no functions to apply (functions/ has no .sql files)."
    exit 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    emit_functions_sql
    exit 0
  fi
  # live apply added in Task 4
  die "internal: live apply-functions not implemented"
fi

[ -n "$CONFIG" ] || CONFIG="config.json"
[[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"   # absolutise vs invocation dir, survives the later cd

# --- preflight ---
for tool in jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
if [ "$DRY_RUN" -eq 0 ]; then
  command -v docker >/dev/null 2>&1 || die "missing required tool: docker"
  docker compose version >/dev/null 2>&1 || die "missing required tool: docker compose"
fi

# --- read config ---
[ -f "$CONFIG" ] || die "config file not found: $CONFIG"
jq -e . "$CONFIG" >/dev/null 2>&1 || die "invalid JSON in $CONFIG"

cap() { # cap <name> -> "1" if enabled else "0"
  jq -r --arg k "$1" '.capabilities[$k] // false | if . then 1 else 0 end' "$CONFIG"
}
declare -A EN
for c in "${CAPS[@]}"; do EN[$c]=$(cap "$c"); done

# --- validate ---
any=0; for c in "${CAPS[@]}"; do [ "${EN[$c]}" = 1 ] && any=1; done
[ "$any" = 1 ] || die "no capabilities enabled in $CONFIG"

if [ "${EN[auth]}" = 1 ] && [ "${EN[api]}" = 0 ]; then
  die "capability 'auth' requires 'api'. Enable \"api\": true in $CONFIG."
fi

if [ "${EN[dashboards]}" = 1 ] && [ "${EN[timeseries]}" = 0 ]; then
  die "capability 'dashboards' requires 'timeseries'. Enable \"timeseries\": true in $CONFIG."
fi

echo "config OK: $(for c in "${CAPS[@]}"; do [ "${EN[$c]}" = 1 ] && printf '%s ' "$c"; done)"

# --- languages (plpgsql is always available; plperl trusted; plpython untrusted) ---
LANG_PLPERL="$(jq -r '.languages.plperl // false | if . then 1 else 0 end' "$CONFIG")"
LANG_PLPYTHON="$(jq -r '.languages.plpython // false | if . then 1 else 0 end' "$CONFIG")"
LANG_ALLOW_UNTRUSTED="$(jq -r '.languages.allow_untrusted // false | if . then 1 else 0 end' "$CONFIG")"

if [ "$LANG_PLPYTHON" = 1 ] && [ "$LANG_ALLOW_UNTRUSTED" = 0 ]; then
  die "language 'plpython' is UNTRUSTED (plpython3u runs with the database OS user's full privileges — unsafe for user-supplied code). Set \"allow_untrusted\": true in the languages block of $CONFIG to enable it deliberately."
fi
if [ "$LANG_PLPYTHON" = 1 ]; then
  echo "WARNING: plpython3u is an UNTRUSTED language; only superusers can create functions in it and they run with full OS privileges." >&2
fi

PG_MAJOR=17
POSTGIS_VERSION=3.5
PG_GRAPHQL_VERSION=1.5.11

cd "$(dirname "$0")"  # anchor build/ output next to the script; $CONFIG is absolute so later reads still work

# On update, reuse the existing install's secrets (regenerating them would break the
# stored authenticator password / superuser password / JWT signing key).
OLD_PG_PW=""; OLD_AUTH_PW=""; OLD_JWT=""
if [ "$UPDATE" = 1 ] && [ -f build/.env ]; then
  OLD_PG_PW="$(grep '^POSTGRES_PASSWORD=' build/.env | cut -d= -f2-)" || true
  OLD_AUTH_PW="$(grep '^AUTHENTICATOR_PASSWORD=' build/.env | cut -d= -f2-)" || true
  OLD_JWT="$(grep '^JWT_SECRET=' build/.env | cut -d= -f2-)" || true
fi

rm -rf build
mkdir -p build/init

# --- Dockerfile ---
{
  if [ "${EN[gis]}" = 1 ]; then
    echo "FROM postgis/postgis:${PG_MAJOR}-${POSTGIS_VERSION}"
  else
    echo "FROM postgres:${PG_MAJOR}"
  fi
  echo "ARG PG_MAJOR=${PG_MAJOR}"
  if [ "${EN[vector]}" = 1 ]; then
    cat <<DF
RUN apt-get update \\
 && apt-get install -y --no-install-recommends \\
      postgresql-${PG_MAJOR}-pgvector ca-certificates wget \\
 && rm -rf /var/lib/apt/lists/*
DF
  fi
  if [ "${EN[api]}" = 1 ]; then
    if [ "${EN[vector]}" != 1 ]; then
      echo "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget && rm -rf /var/lib/apt/lists/*"
    fi
    printf 'RUN set -eux; arch="$(dpkg --print-architecture)"; '
    printf 'url="https://github.com/supabase/pg_graphql/releases/download/v%s/pg_graphql-v%s-pg%s-${arch}-linux-gnu.deb"; ' \
      "$PG_GRAPHQL_VERSION" "$PG_GRAPHQL_VERSION" "$PG_MAJOR"
    printf 'wget -q -O /tmp/pg_graphql.deb "$url"; apt-get update; apt-get install -y --no-install-recommends /tmp/pg_graphql.deb; rm -f /tmp/pg_graphql.deb; rm -rf /var/lib/apt/lists/*\n'
  fi
  if [ "$LANG_PLPERL" = 1 ] || [ "$LANG_PLPYTHON" = 1 ]; then
    pkgs=""
    [ "$LANG_PLPERL" = 1 ]   && pkgs="$pkgs postgresql-plperl-${PG_MAJOR}"
    [ "$LANG_PLPYTHON" = 1 ] && pkgs="$pkgs postgresql-plpython3-${PG_MAJOR}"
    echo "RUN apt-get update && apt-get install -y --no-install-recommends${pkgs} && rm -rf /var/lib/apt/lists/*"
  fi
  echo "COPY init/ /docker-entrypoint-initdb.d/"
} > build/Dockerfile

# --- 01-extensions.sql ---
{
  echo "-- generated by setup.sh; do not edit"
  [ "${EN[search]}" = 1 ] && echo "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  [ "${EN[vector]}" = 1 ] && echo "CREATE EXTENSION IF NOT EXISTS vector;"
  [ "${EN[gis]}" = 1 ]    && echo "CREATE EXTENSION IF NOT EXISTS postgis;"
  [ "${EN[api]}" = 1 ]    && echo "CREATE EXTENSION IF NOT EXISTS pg_graphql;"
  [ "$LANG_PLPERL" = 1 ]   && echo "CREATE EXTENSION IF NOT EXISTS plperl;"
  [ "$LANG_PLPYTHON" = 1 ] && echo "CREATE EXTENSION IF NOT EXISTS plpython3u;"
  true
} > build/init/01-extensions.sql

# --- 02-schema.sql (canonical order; api contributes no schema) ---
SEED="$(jq -r 'if .seed_demo_data == null then "true" else (.seed_demo_data | tostring) end' "$CONFIG")"
SCHEMA_ORDER=(document_store job_queue search vector gis timeseries dashboards auth)
{
  echo "-- generated by setup.sh; do not edit"
  for c in "${SCHEMA_ORDER[@]}"; do
    [ "${EN[$c]}" = 1 ] || continue
    cat "init/capabilities/$c.schema.sql"
    echo
    if [ "$SEED" = "true" ] && [ -f "init/capabilities/$c.seed.sql" ]; then
      cat "init/capabilities/$c.seed.sql"
      echo
    fi
  done
} > build/init/02-schema.sql

# --- 04-meta.sql (records installed capabilities; lives in p4a_meta, never exposed by PostgREST) ---
{
  echo "-- generated by setup.sh; do not edit"
  echo "CREATE SCHEMA IF NOT EXISTS p4a_meta;"
  echo "CREATE TABLE IF NOT EXISTS p4a_meta.capabilities ("
  echo "    cap        text PRIMARY KEY,"
  echo "    applied_at timestamptz NOT NULL DEFAULT now()"
  echo ");"
  for c in "${CAPS[@]}"; do
    [ "${EN[$c]}" = 1 ] && echo "INSERT INTO p4a_meta.capabilities (cap) VALUES ('$c') ON CONFLICT (cap) DO NOTHING;"
  done
  true
} > build/init/04-meta.sql

if [ "${EN[api]}" = 1 ]; then
  # --- 00-roles.sh ---
  cat > build/init/00-roles.sh <<'ROLES'
#!/bin/bash
set -euo pipefail
: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     --set authpw="$AUTHENTICATOR_PASSWORD" <<-'EOSQL'
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'authpw';
    GRANT anon, authenticated TO authenticator;
EOSQL
ROLES
  chmod +x build/init/00-roles.sh

  # --- 03-api-grants.sql (read tables scoped to enabled caps) ---
  read_tables=""
  for c in document_store job_queue search vector gis timeseries dashboards; do
    [ "${EN[$c]}" = 1 ] && read_tables="${read_tables:+$read_tables, }${READ_TABLE[$c]}"
  done
  {
    echo "-- generated by setup.sh; do not edit"
    echo "GRANT USAGE ON SCHEMA public TO anon, authenticated;"
    if [ -n "$read_tables" ]; then echo "GRANT SELECT ON $read_tables TO anon, authenticated;"; fi
    if [ "${EN[auth]}" = 1 ]; then echo "GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;"; fi
    echo "GRANT USAGE ON SCHEMA graphql TO anon, authenticated;"
    echo "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql TO anon, authenticated;"
    echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;"
  } > build/init/03-api-grants.sql
fi

# --- secrets: from config or generated ---
rand_secret() { openssl rand -hex 24; }
PG_USER="$(jq -r '.postgres.user // "postgres"' "$CONFIG")"
PG_DB="$(jq -r '.postgres.db // "app"' "$CONFIG")"
PG_PW="$(jq -r '.postgres.password // ""' "$CONFIG")"
[ -n "$PG_PW" ] || PG_PW="${OLD_PG_PW:-}"
[ -n "$PG_PW" ] || { PG_PW="$(rand_secret)"; GEN_PG=1; }

{
  echo "POSTGRES_USER=$PG_USER"
  echo "POSTGRES_PASSWORD=$PG_PW"
  echo "POSTGRES_DB=$PG_DB"
  if [ "${EN[api]}" = 1 ]; then
    AUTH_PW="$(jq -r '.api.authenticator_password // ""' "$CONFIG")"
    [ -n "$AUTH_PW" ] || AUTH_PW="${OLD_AUTH_PW:-}"
    [ -n "$AUTH_PW" ] || { AUTH_PW="$(openssl rand -hex 16)"; GEN_AUTH=1; }
    JWT="$(jq -r '.api.jwt_secret // ""' "$CONFIG")"
    [ -n "$JWT" ] || JWT="${OLD_JWT:-}"
    [ -n "$JWT" ] || { JWT="$(rand_secret)$(rand_secret)"; GEN_JWT=1; }
    echo "AUTHENTICATOR_PASSWORD=$AUTH_PW"
    echo "JWT_SECRET=$JWT"
  fi
} > build/.env
chmod 600 build/.env

PUBLISH_EXT="$(jq -r 'if .postgres.publish_externally == true then 1 else 0 end' "$CONFIG")"
if [ "$PUBLISH_EXT" = 1 ]; then BIND_PREFIX=""; else BIND_PREFIX="127.0.0.1:"; fi

# --- docker-compose.yml ---
{
  echo "services:"
  echo "  db:"
  echo "    build: ."
  echo "    image: postgres4all:generated"
  echo "    restart: unless-stopped"
  echo "    environment:"
  echo "      POSTGRES_USER: \${POSTGRES_USER}"
  echo "      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}"
  echo "      POSTGRES_DB: \${POSTGRES_DB}"
  [ "${EN[api]}" = 1 ] && echo "      AUTHENTICATOR_PASSWORD: \${AUTHENTICATOR_PASSWORD}"
  echo "    ports:"
  echo "      - \"${BIND_PREFIX}5432:5432\""
  echo "    volumes:"
  echo "      - pgdata:/var/lib/postgresql/data"
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}\"]"
  echo "      interval: 5s"
  echo "      timeout: 5s"
  echo "      retries: 12"
  if [ "${EN[api]}" = 1 ]; then
    echo "  postgrest:"
    echo "    image: postgrest/postgrest:v12.2.3"
    echo "    restart: unless-stopped"
    echo "    environment:"
    echo "      PGRST_DB_URI: postgres://authenticator:\${AUTHENTICATOR_PASSWORD}@db:5432/\${POSTGRES_DB}"
    echo "      PGRST_DB_SCHEMAS: public"
    echo "      PGRST_DB_ANON_ROLE: anon"
    echo "      PGRST_JWT_SECRET: \${JWT_SECRET}"
    echo "    ports:"
    echo "      - \"${BIND_PREFIX}3000:3000\""
    echo "    depends_on:"
    echo "      db:"
    echo "        condition: service_healthy"
  fi
  echo "volumes:"
  echo "  pgdata:"
} > build/docker-compose.yml

# --- report generated secrets once (values stay in build/.env only) ---
if [ "${GEN_PG:-0}" = 1 ] || [ "${GEN_AUTH:-0}" = 1 ] || [ "${GEN_JWT:-0}" = 1 ]; then
  echo "Secrets were generated and written to build/.env (mode 0600). Keep that file safe and do not commit it."
fi

if [ "$UPDATE" = 0 ]; then
  # ---------- INSTALL MODE ----------
  if [ "$DRY_RUN" = 1 ]; then echo "dry-run: build/ generated, not starting Docker"; exit 0; fi
  vol="$(_pgdata_volume_name)"
  if [ -n "$vol" ] && docker volume inspect "$vol" >/dev/null 2>&1; then
    die "an install already exists (volume $vol). Use './setup.sh --update' to change capabilities, or 'docker compose -f build/docker-compose.yml down -v' to wipe it first."
  fi
  echo "starting stack..."
  docker compose --env-file build/.env -f build/docker-compose.yml up --build
  exit 0
fi

# ---------- UPDATE MODE ----------
# Dry-run cannot query a live DB for the installed set, so it must be supplied.
if [ "$DRY_RUN" = 1 ] && [ "$INSTALLED_GIVEN" = 0 ]; then
  die "--update --dry-run requires --installed <csv> (no live database is queried in dry-run mode)"
fi

# Determine INSTALLED set.
if [ "$INSTALLED_GIVEN" = 1 ]; then
  installed_list="$INSTALLED_CSV"
else
  vol="$(_pgdata_volume_name)"
  if [ -z "$vol" ] || ! docker volume inspect "$vol" >/dev/null 2>&1; then
    die "no existing install found (no pgdata volume). Run './setup.sh' for a fresh install."
  fi
  installed_list="$(query_installed)"
fi

declare -A INST
IFS=',' read -ra _inst <<< "$installed_list"
for c in "${_inst[@]}"; do [ -n "$c" ] && INST[$c]=1; done

# Compute ADD / REMOVE in canonical order.
ADD=(); REMOVE=()
for c in "${CAPS[@]}"; do
  if [ "${EN[$c]}" = 1 ] && [ "${INST[$c]:-0}" != 1 ]; then ADD+=("$c"); fi
  if [ "${EN[$c]}" != 1 ] && [ "${INST[$c]:-0}" = 1 ]; then REMOVE+=("$c"); fi
done

echo "Update plan:"
echo "  ADD: ${ADD[*]:-(none)}"
echo "  REMOVE: ${REMOVE[*]:-(none)}"

if [ "${#REMOVE[@]}" -gt 0 ] && [ "$ALLOW_DROP" = 0 ]; then
  die "removing capabilities (${REMOVE[*]}) is destructive; re-run with --allow-drop to confirm."
fi
if [ "${#ADD[@]}" -eq 0 ] && [ "${#REMOVE[@]}" -eq 0 ]; then
  echo "already up to date."
  exit 0
fi

# api orchestration flags
api_added=0
for c in "${ADD[@]}"; do if [ "$c" = api ]; then api_added=1; fi; done

if [ "$DRY_RUN" = 1 ]; then
  echo "===== PRE ====="
  if [ "$api_added" = 1 ]; then emit_pre_sql; fi
  echo "===== REMOVE ====="
  if [ "${#REMOVE[@]}" -gt 0 ]; then emit_remove_sql; fi
  echo "===== ADD ====="
  if [ "${#ADD[@]}" -gt 0 ]; then emit_add_sql; fi
  exit 0
fi

# Ensure db is up on the current image (query_installed already did this for the live path;
# harmless to repeat). --remove-orphans removes a now-absent postgrest before we touch roles.
_compose up -d --remove-orphans db
_wait_db_healthy

# Phase 0: roles before the rebuild (only when api is newly added)
if [ "$api_added" = 1 ]; then echo "phase 0: creating role chain..."; emit_pre_sql | _apply_sql; fi

# Phase 1: drops on the current image (binaries still present)
if [ "${#REMOVE[@]}" -gt 0 ]; then echo "phase 1: applying removals..."; emit_remove_sql | _apply_sql; fi

# Phase 2: rebuild + recreate (named volume preserved; orphan postgrest removed)
echo "phase 2: rebuilding image and recreating container..."
_build_up
_wait_db_healthy

# Phase 3: adds on the new image (new binaries present)
if [ "${#ADD[@]}" -gt 0 ]; then
  echo "phase 3: applying additions..."
  emit_add_sql | _apply_sql
  # PostgREST started in Phase 2; make it reload its schema cache for the new grants.
  if [ "$api_added" = 1 ]; then _compose restart postgrest >/dev/null 2>&1 || true; fi
fi

echo "update complete. installed: $(_psql_q "SELECT string_agg(cap, ', ' ORDER BY cap) FROM p4a_meta.capabilities")"
