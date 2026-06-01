# Config-driven provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user declare which of the nine Postgres capabilities they want in `config.json`, run `./setup.sh`, and get a Docker stack that provisions only those capabilities (their tables, extensions, and the PostgREST API container).

**Architecture:** `setup.sh` parses `config.json` with `jq`, validates it, and **generates** a self-contained `build/` directory (Dockerfile, docker-compose.yml, .env, and assembled `init/*` scripts) from per-capability SQL fragments, then runs `docker compose` from it. A `--dry-run` flag stops after generation so the generator is testable without Docker.

**Tech Stack:** Bash, `jq`, `openssl`, Docker Compose, PostgreSQL 17 (PostGIS / pgvector / pg_graphql), PostgREST. Tests are a plain bash harness (`test/test_setup.sh`) that runs the generator in `--dry-run` mode and asserts on generated files with `grep`.

**Reference:** `docs/superpowers/specs/2026-06-02-config-driven-provisioning-design.md`

---

## File Structure

Created:
- `config.example.json` — documented template the user copies to `config.json`.
- `setup.sh` — the provisioner (validation + generation + run).
- `init/capabilities/<cap>.schema.sql` (8 files) and `<cap>.seed.sql` (6 files) — per-capability SQL fragments.
- `test/test_setup.sh` — generator smoke + rejection tests (no Docker).
- `.gitignore` — excludes `build/`, `.env`, `config.json`, `.remember/`.

Modified:
- `README.md` — document the config-driven flow.
- `CLAUDE.md` — replace the "init-script lifecycle" section to describe generation into `build/`.

Removed at the end (superseded by generated equivalents):
- `init/00-roles.sh`, `init/01-extensions.sql`, `init/02-schema.sql`, `init/03-api-grants.sql`, top-level `Dockerfile`, top-level `docker-compose.yml`.

Canonical capability order (used everywhere assembly happens):
`document_store, job_queue, search, vector, gis, timeseries, dashboards, api, auth`
(`api` contributes no schema; `timeseries` must precede `dashboards`.)

---

### Task 1: Split capability SQL into per-capability fragments

Mechanical extraction from the current `init/02-schema.sql`. No tests (pure content move; Task 8 verifies assembly).

**Files:**
- Create: `init/capabilities/document_store.schema.sql`, `init/capabilities/document_store.seed.sql`
- Create: `init/capabilities/job_queue.schema.sql`, `init/capabilities/job_queue.seed.sql`
- Create: `init/capabilities/search.schema.sql`, `init/capabilities/search.seed.sql`
- Create: `init/capabilities/vector.schema.sql`, `init/capabilities/vector.seed.sql`
- Create: `init/capabilities/gis.schema.sql`, `init/capabilities/gis.seed.sql`
- Create: `init/capabilities/timeseries.schema.sql`, `init/capabilities/timeseries.seed.sql`
- Create: `init/capabilities/dashboards.schema.sql`
- Create: `init/capabilities/auth.schema.sql`

- [ ] **Step 1: Create document_store fragments**

`init/capabilities/document_store.schema.sql`:
```sql
-- document_store: MongoDB -> jsonb + GIN index
CREATE TABLE products (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text  NOT NULL,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX products_attrs_gin ON products USING gin (attributes jsonb_path_ops);
```

`init/capabilities/document_store.seed.sql`:
```sql
INSERT INTO products (name, attributes) VALUES
    ('Mechanical Keyboard', '{"brand":"Keychron","switch":"brown","wireless":true,"tags":["typing","gaming"]}'),
    ('USB-C Hub',           '{"brand":"Anker","ports":7,"wireless":false}');
```

- [ ] **Step 2: Create job_queue fragments**

`init/capabilities/job_queue.schema.sql`:
```sql
-- job_queue: Redis/RabbitMQ -> FOR UPDATE SKIP LOCKED
CREATE TABLE jobs (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload    jsonb       NOT NULL,
    status     text        NOT NULL DEFAULT 'pending',
    locked_at  timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_pending_idx ON jobs (created_at) WHERE status = 'pending';

CREATE OR REPLACE FUNCTION dequeue_job()
RETURNS jobs
LANGUAGE sql AS $$
    UPDATE jobs
       SET status = 'processing', locked_at = now()
     WHERE id = (
         SELECT id FROM jobs
          WHERE status = 'pending'
          ORDER BY created_at
          FOR UPDATE SKIP LOCKED
          LIMIT 1
     )
    RETURNING *;
$$;
```

`init/capabilities/job_queue.seed.sql`:
```sql
INSERT INTO jobs (payload)
SELECT jsonb_build_object('n', g) FROM generate_series(1, 10) AS g;
```

- [ ] **Step 3: Create search fragments**

`init/capabilities/search.schema.sql`:
```sql
-- search: Elasticsearch -> tsvector + pg_trgm
CREATE TABLE articles (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL,
    body  text NOT NULL,
    tsv   tsvector GENERATED ALWAYS AS
              (to_tsvector('english', title || ' ' || body)) STORED
);
CREATE INDEX articles_tsv_idx        ON articles USING gin (tsv);
CREATE INDEX articles_title_trgm_idx ON articles USING gin (title gin_trgm_ops);
```

`init/capabilities/search.seed.sql`:
```sql
INSERT INTO articles (title, body) VALUES
    ('Running Postgres in production', 'Tips for scaling and running your database under load.'),
    ('A guide to full text search',    'Using tsvector and tsquery effectively in Postgres.');
```

- [ ] **Step 4: Create vector fragments**

`init/capabilities/vector.schema.sql`:
```sql
-- vector: Pinecone -> pgvector + HNSW
CREATE TABLE documents (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id  bigint  NOT NULL DEFAULT 1,
    content   text    NOT NULL,
    embedding vector(3) NOT NULL
);
CREATE INDEX documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops);
```

`init/capabilities/vector.seed.sql`:
```sql
INSERT INTO documents (owner_id, content, embedding) VALUES
    (1, 'cat', '[0.10,0.20,0.30]'),
    (1, 'dog', '[0.12,0.19,0.31]'),
    (2, 'car', '[0.90,0.10,0.00]');
```

- [ ] **Step 5: Create gis fragments**

`init/capabilities/gis.schema.sql`:
```sql
-- gis: PostGIS + GiST
CREATE TABLE places (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    geom geometry(Point, 4326) NOT NULL
);
CREATE INDEX places_geom_gist ON places USING gist (geom);
```

`init/capabilities/gis.seed.sql`:
```sql
INSERT INTO places (name, geom) VALUES
    ('Cafe A', ST_SetSRID(ST_MakePoint(-122.4194, 37.7749), 4326)),
    ('Cafe B', ST_SetSRID(ST_MakePoint(-122.4084, 37.7849), 4326));
```

- [ ] **Step 6: Create timeseries fragments**

`init/capabilities/timeseries.schema.sql`:
```sql
-- timeseries: declarative partitioning + BRIN
CREATE TABLE events (
    occurred_at timestamptz NOT NULL,
    kind        text        NOT NULL,
    data        jsonb       NOT NULL DEFAULT '{}'::jsonb
) PARTITION BY RANGE (occurred_at);

CREATE TABLE events_2026_06 PARTITION OF events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE events_2026_07 PARTITION OF events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

CREATE INDEX events_brin ON events USING brin (occurred_at);
```

`init/capabilities/timeseries.seed.sql`:
```sql
INSERT INTO events (occurred_at, kind)
SELECT TIMESTAMPTZ '2026-06-01' + (g || ' minutes')::interval, 'click'
FROM generate_series(1, 1000) AS g;
```

- [ ] **Step 7: Create dashboards schema (no seed — derives from events)**

`init/capabilities/dashboards.schema.sql`:
```sql
-- dashboards: Snowflake -> materialized view (requires timeseries' events table)
CREATE MATERIALIZED VIEW event_daily AS
    SELECT date_trunc('day', occurred_at) AS day,
           kind,
           count(*) AS n
    FROM events
    GROUP BY 1, 2
    WITH DATA;
CREATE UNIQUE INDEX event_daily_pk ON event_daily (day, kind);
```

- [ ] **Step 8: Create auth schema (no seed — rows need a JWT owner)**

`init/capabilities/auth.schema.sql`:
```sql
-- auth: row-level security (exposed via PostgREST role switch)
CREATE TABLE notes (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner text NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json ->> 'sub',
    body  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;

CREATE POLICY notes_isolation ON notes
    USING      (owner = current_setting('request.jwt.claims', true)::json ->> 'sub')
    WITH CHECK (owner = current_setting('request.jwt.claims', true)::json ->> 'sub');
```

- [ ] **Step 9: Commit**

```bash
git add init/capabilities/
git commit -m "refactor: split schema into per-capability SQL fragments"
```

---

### Task 2: Create config.example.json

**Files:**
- Create: `config.example.json`

- [ ] **Step 1: Write the template**

`config.example.json`:
```json
{
  "postgres": {
    "user": "postgres",
    "db": "app",
    "password": ""
  },
  "seed_demo_data": true,
  "capabilities": {
    "document_store": true,
    "job_queue": true,
    "search": false,
    "vector": false,
    "gis": false,
    "timeseries": false,
    "dashboards": false,
    "api": false,
    "auth": false
  },
  "api": {
    "authenticator_password": "",
    "jwt_secret": ""
  }
}
```

Empty-string secrets mean "auto-generate". Dependency rules: `dashboards` requires `timeseries`; `auth` requires `api`.

- [ ] **Step 2: Commit**

```bash
git add config.example.json
git commit -m "feat: add config.example.json template"
```

---

### Task 3: setup.sh — preflight, config read, validation (TDD)

Build the validation core first, behind a `--dry-run` flag so it is testable without Docker. The test harness drives it.

**Files:**
- Create: `setup.sh`
- Test: `test/test_setup.sh`

- [ ] **Step 1: Write the failing test harness**

`test/test_setup.sh`:
```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x test/test_setup.sh && ./test/test_setup.sh`
Expected: FAIL — `setup.sh` does not exist yet (every `run` errors, messages won't match).

- [ ] **Step 3: Write setup.sh with preflight + validation**

`setup.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

CAPS=(document_store job_queue search vector gis timeseries dashboards api auth)

die() { echo "ERROR: $*" >&2; exit 1; }

DRY_RUN=0
CONFIG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) CONFIG="$arg" ;;
  esac
done
[ -n "$CONFIG" ] || CONFIG="config.json"

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
for c in "${CAPS[@]}"; do eval "EN_$c=$(cap "$c")"; done

# --- validate ---
any=0; for c in "${CAPS[@]}"; do [ "$(eval echo \$EN_$c)" = 1 ] && any=1; done
[ "$any" = 1 ] || die "no capabilities enabled in $CONFIG"
[ "$EN_auth" = 1 ] && [ "$EN_api" = 0 ] && die "capability 'auth' requires 'api'. Enable \"api\": true in $CONFIG."
[ "$EN_dashboards" = 1 ] && [ "$EN_timeseries" = 0 ] && die "capability 'dashboards' requires 'timeseries'. Enable \"timeseries\": true in $CONFIG."

echo "config OK: $(for c in "${CAPS[@]}"; do [ "$(eval echo \$EN_$c)" = 1 ] && printf '%s ' "$c"; done)"

# Generation + run added in later tasks.
```

- [ ] **Step 4: Run the test to verify validation passes**

Run: `./test/test_setup.sh`
Expected: PASS — all three rejection cases print `ok`, `PASS=3 FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add setup.sh test/test_setup.sh
git commit -m "feat: setup.sh preflight and capability validation"
```

---

### Task 4: Generate build/ skeleton + Dockerfile (TDD)

**Files:**
- Modify: `setup.sh`
- Modify: `test/test_setup.sh`

- [ ] **Step 1: Add failing tests for Dockerfile generation**

Append to `test/test_setup.sh` before the summary block:
```bash
# --- Dockerfile: gis off -> plain postgres base, no postgis ---
run '{"capabilities":{"document_store":true}}'
grep -q '^FROM postgres:17' build/Dockerfile && ok "no-gis uses postgres base" || bad "no-gis base image"
grep -q 'postgis' build/Dockerfile && bad "no-gis must not mention postgis" || ok "no-gis omits postgis"

# --- Dockerfile: gis on -> postgis base ---
run '{"capabilities":{"gis":true}}'
grep -q '^FROM postgis/postgis:17-3.5' build/Dockerfile && ok "gis uses postgis base" || bad "gis base image"

# --- Dockerfile: vector on -> pgvector apt install ---
run '{"capabilities":{"vector":true}}'
grep -q 'postgresql-17-pgvector' build/Dockerfile && ok "vector installs pgvector" || bad "vector pgvector install"

# --- Dockerfile: api on -> pg_graphql .deb ---
run '{"capabilities":{"document_store":true,"api":true}}'
grep -q 'pg_graphql' build/Dockerfile && ok "api fetches pg_graphql" || bad "api pg_graphql"
```

- [ ] **Step 2: Run to verify new tests fail**

Run: `./test/test_setup.sh`
Expected: FAIL — `build/Dockerfile` does not exist yet.

- [ ] **Step 3: Add build/ reset + Dockerfile generation to setup.sh**

Replace the final comment line `# Generation + run added in later tasks.` in `setup.sh` with:
```bash
PG_MAJOR=17
POSTGIS_VERSION=3.5
PG_GRAPHQL_VERSION=1.5.11

rm -rf build
mkdir -p build/init

# --- Dockerfile ---
{
  if [ "$EN_gis" = 1 ]; then
    echo "FROM postgis/postgis:${PG_MAJOR}-${POSTGIS_VERSION}"
  else
    echo "FROM postgres:${PG_MAJOR}"
  fi
  echo "ARG PG_MAJOR=${PG_MAJOR}"
  if [ "$EN_vector" = 1 ]; then
    cat <<'DF'
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-${PG_MAJOR}-pgvector ca-certificates wget \
 && rm -rf /var/lib/apt/lists/*
DF
  fi
  if [ "$EN_api" = 1 ]; then
    echo "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget && rm -rf /var/lib/apt/lists/*"
    printf 'RUN set -eux; arch="$(dpkg --print-architecture)"; '
    printf 'url="https://github.com/supabase/pg_graphql/releases/download/v%s/pg_graphql-v%s-pg%s-${arch}-linux-gnu.deb"; ' \
      "$PG_GRAPHQL_VERSION" "$PG_GRAPHQL_VERSION" "$PG_MAJOR"
    printf 'wget -q -O /tmp/pg_graphql.deb "$url"; apt-get update; apt-get install -y --no-install-recommends /tmp/pg_graphql.deb; rm -f /tmp/pg_graphql.deb; rm -rf /var/lib/apt/lists/*\n'
  fi
  echo "COPY init/ /docker-entrypoint-initdb.d/"
} > build/Dockerfile

if [ "$DRY_RUN" -eq 1 ]; then echo "dry-run: generated build/ (Dockerfile)"; fi
```

Note: `dpkg --print-architecture` already prints `amd64`/`arm64`, matching pg_graphql's release asset names, so no arch translation is needed.

- [ ] **Step 4: Run to verify Dockerfile tests pass**

Run: `./test/test_setup.sh`
Expected: PASS — all Dockerfile assertions print `ok`.

- [ ] **Step 5: Commit**

```bash
git add setup.sh test/test_setup.sh
git commit -m "feat: generate build/Dockerfile from capability set"
```

---

### Task 5: Generate extensions + assembled schema (TDD)

**Files:**
- Modify: `setup.sh`
- Modify: `test/test_setup.sh`

- [ ] **Step 1: Add failing tests for extensions + schema assembly**

Append to `test/test_setup.sh` before the summary:
```bash
# --- extensions: only needed CREATE EXTENSION lines ---
run '{"capabilities":{"search":true,"vector":true}}'
grep -q 'CREATE EXTENSION IF NOT EXISTS pg_trgm' build/init/01-extensions.sql && ok "search -> pg_trgm" || bad "search ext"
grep -q 'CREATE EXTENSION IF NOT EXISTS vector' build/init/01-extensions.sql && ok "vector -> vector ext" || bad "vector ext"
grep -q 'postgis' build/init/01-extensions.sql && bad "no postgis ext when gis off" || ok "no postgis ext"

# --- schema assembly: only enabled tables ---
run '{"capabilities":{"document_store":true},"seed_demo_data":true}'
grep -q 'CREATE TABLE products' build/init/02-schema.sql && ok "schema has products" || bad "schema products"
grep -q 'CREATE TABLE jobs' build/init/02-schema.sql && bad "must omit jobs" || ok "schema omits jobs"
grep -q "INSERT INTO products" build/init/02-schema.sql && ok "seed included when on" || bad "seed on"

# --- seed toggle off: schema but no inserts ---
run '{"capabilities":{"document_store":true},"seed_demo_data":false}'
grep -q 'CREATE TABLE products' build/init/02-schema.sql && ok "schema present, seed off" || bad "schema seed-off"
grep -q 'INSERT INTO products' build/init/02-schema.sql && bad "no inserts when seed off" || ok "no inserts when seed off"

# --- canonical order: timeseries before dashboards ---
run '{"capabilities":{"timeseries":true,"dashboards":true}}'
awk '/CREATE TABLE events/{e=NR} /event_daily/{d=NR} END{exit !(e && d && e<d)}' build/init/02-schema.sql \
  && ok "timeseries precedes dashboards" || bad "order timeseries/dashboards"
```

- [ ] **Step 2: Run to verify new tests fail**

Run: `./test/test_setup.sh`
Expected: FAIL — `build/init/01-extensions.sql` and `02-schema.sql` not generated yet.

- [ ] **Step 3: Add extensions + schema assembly to setup.sh**

Insert into `setup.sh` immediately after the Dockerfile generation block (before the `if [ "$DRY_RUN" -eq 1 ]` Dockerfile echo):
```bash
# --- 01-extensions.sql ---
{
  echo "-- generated by setup.sh; do not edit"
  [ "$EN_search" = 1 ] && echo "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  [ "$EN_vector" = 1 ] && echo "CREATE EXTENSION IF NOT EXISTS vector;"
  [ "$EN_gis" = 1 ]    && echo "CREATE EXTENSION IF NOT EXISTS postgis;"
  [ "$EN_api" = 1 ]    && echo "CREATE EXTENSION IF NOT EXISTS pg_graphql;"
  true
} > build/init/01-extensions.sql

# --- 02-schema.sql (canonical order; api contributes no schema) ---
SEED="$(jq -r '.seed_demo_data // true' "$CONFIG")"
SCHEMA_ORDER=(document_store job_queue search vector gis timeseries dashboards auth)
{
  echo "-- generated by setup.sh; do not edit"
  for c in "${SCHEMA_ORDER[@]}"; do
    [ "$(eval echo \$EN_$c)" = 1 ] || continue
    cat "init/capabilities/$c.schema.sql"
    echo
    if [ "$SEED" = "true" ] && [ -f "init/capabilities/$c.seed.sql" ]; then
      cat "init/capabilities/$c.seed.sql"
      echo
    fi
  done
} > build/init/02-schema.sql
```

- [ ] **Step 4: Run to verify schema/extension tests pass**

Run: `./test/test_setup.sh`
Expected: PASS — extension, assembly, seed-toggle, and order assertions all `ok`.

- [ ] **Step 5: Commit**

```bash
git add setup.sh test/test_setup.sh
git commit -m "feat: generate extensions and assembled schema"
```

---

### Task 6: Generate roles + grants (api only) (TDD)

**Files:**
- Modify: `setup.sh`
- Modify: `test/test_setup.sh`

- [ ] **Step 1: Add failing tests for roles/grants**

Append to `test/test_setup.sh` before the summary:
```bash
# --- api off: no roles file, no grants file ---
run '{"capabilities":{"document_store":true}}'
[ -f build/init/00-roles.sh ] && bad "no roles file when api off" || ok "no roles file (api off)"
[ -f build/init/03-api-grants.sql ] && bad "no grants when api off" || ok "no grants (api off)"

# --- api on: roles + grants scoped to enabled tables ---
run '{"capabilities":{"document_store":true,"search":true,"api":true}}'
[ -f build/init/00-roles.sh ] && ok "roles file present (api on)" || bad "roles file missing"
grep -q 'GRANT SELECT ON products' build/init/03-api-grants.sql && ok "grants products" || bad "grants products"
grep -q 'articles' build/init/03-api-grants.sql && ok "grants articles" || bad "grants articles"
grep -q 'jobs' build/init/03-api-grants.sql && bad "must not grant jobs (off)" || ok "omits jobs grant"

# --- auth on: notes CRUD grant ---
run '{"capabilities":{"document_store":true,"api":true,"auth":true}}'
grep -q 'GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated' build/init/03-api-grants.sql \
  && ok "notes CRUD grant" || bad "notes CRUD grant"
```

- [ ] **Step 2: Run to verify new tests fail**

Run: `./test/test_setup.sh`
Expected: FAIL — roles/grants not generated yet.

- [ ] **Step 3: Add roles + grants generation to setup.sh**

Insert into `setup.sh` after the `02-schema.sql` block:
```bash
if [ "$EN_api" = 1 ]; then
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
  declare -A READ_TABLE=(
    [document_store]=products [job_queue]=jobs [search]=articles
    [vector]=documents [gis]=places [timeseries]=events [dashboards]=event_daily
  )
  read_tables=""
  for c in document_store job_queue search vector gis timeseries dashboards; do
    [ "$(eval echo \$EN_$c)" = 1 ] && read_tables="${read_tables:+$read_tables, }${READ_TABLE[$c]}"
  done
  {
    echo "-- generated by setup.sh; do not edit"
    echo "GRANT USAGE ON SCHEMA public TO anon, authenticated;"
    [ -n "$read_tables" ] && echo "GRANT SELECT ON $read_tables TO anon, authenticated;"
    [ "$EN_auth" = 1 ] && echo "GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;"
    echo "GRANT USAGE ON SCHEMA graphql TO anon, authenticated;"
    echo "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql TO anon, authenticated;"
    echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;"
  } > build/init/03-api-grants.sql
fi
```

- [ ] **Step 4: Run to verify roles/grants tests pass**

Run: `./test/test_setup.sh`
Expected: PASS — all roles/grants assertions `ok`.

- [ ] **Step 5: Commit**

```bash
git add setup.sh test/test_setup.sh
git commit -m "feat: generate PostgREST roles and scoped grants"
```

---

### Task 7: Generate docker-compose.yml + .env + run (TDD for generation)

**Files:**
- Modify: `setup.sh`
- Modify: `test/test_setup.sh`

- [ ] **Step 1: Add failing tests for compose + env**

Append to `test/test_setup.sh` before the summary:
```bash
# --- compose: db always, postgrest only with api ---
run '{"capabilities":{"document_store":true}}'
grep -q 'services:' build/docker-compose.yml && ok "compose has services" || bad "compose services"
grep -q 'postgrest' build/docker-compose.yml && bad "no postgrest when api off" || ok "no postgrest (api off)"
grep -q 'POSTGRES_PASSWORD=' build/.env && ok ".env has postgres pw" || bad ".env postgres pw"
grep -q 'JWT_SECRET=' build/.env && bad "no JWT_SECRET when api off" || ok ".env omits jwt (api off)"

# --- compose: api on -> postgrest service + secrets ---
run '{"capabilities":{"document_store":true,"api":true}}'
grep -q 'postgrest' build/docker-compose.yml && ok "postgrest present (api on)" || bad "postgrest missing"
grep -q 'JWT_SECRET=' build/.env && ok ".env has jwt (api on)" || bad ".env jwt"
grep -q 'AUTHENTICATOR_PASSWORD=' build/.env && ok ".env has authenticator pw" || bad ".env authenticator pw"

# --- secrets honored from config when provided ---
run '{"capabilities":{"document_store":true},"postgres":{"password":"hunter2xyz"}}'
grep -q 'POSTGRES_PASSWORD=hunter2xyz' build/.env && ok "config password honored" || bad "config password"
```

- [ ] **Step 2: Run to verify new tests fail**

Run: `./test/test_setup.sh`
Expected: FAIL — compose/.env not generated yet.

- [ ] **Step 3: Add compose + env generation and final run to setup.sh**

Insert into `setup.sh` after the roles/grants block:
```bash
# --- secrets: from config or generated ---
gen() { openssl rand -hex 24; }
PG_USER="$(jq -r '.postgres.user // "postgres"' "$CONFIG")"
PG_DB="$(jq -r '.postgres.db // "app"' "$CONFIG")"
PG_PW="$(jq -r '.postgres.password // ""' "$CONFIG")"; [ -n "$PG_PW" ] || { PG_PW="$(gen)"; GEN_PG=1; }

{
  echo "POSTGRES_USER=$PG_USER"
  echo "POSTGRES_PASSWORD=$PG_PW"
  echo "POSTGRES_DB=$PG_DB"
  if [ "$EN_api" = 1 ]; then
    AUTH_PW="$(jq -r '.api.authenticator_password // ""' "$CONFIG")"; [ -n "$AUTH_PW" ] || { AUTH_PW="$(openssl rand -hex 16 | tr -dc 'a-zA-Z0-9')"; GEN_AUTH=1; }
    JWT="$(jq -r '.api.jwt_secret // ""' "$CONFIG")"; [ -n "$JWT" ] || { JWT="$(gen)$(gen)"; GEN_JWT=1; }
    echo "AUTHENTICATOR_PASSWORD=$AUTH_PW"
    echo "JWT_SECRET=$JWT"
  fi
} > build/.env

# --- docker-compose.yml ---
{
  echo "services:"
  echo "  db:"
  echo "    build: ."
  echo "    image: postgres-everything:generated"
  echo "    restart: unless-stopped"
  echo "    environment:"
  echo "      POSTGRES_USER: \${POSTGRES_USER}"
  echo "      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}"
  echo "      POSTGRES_DB: \${POSTGRES_DB}"
  [ "$EN_api" = 1 ] && echo "      AUTHENTICATOR_PASSWORD: \${AUTHENTICATOR_PASSWORD}"
  echo "    ports:"
  echo "      - \"5432:5432\""
  echo "    volumes:"
  echo "      - pgdata:/var/lib/postgresql/data"
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}\"]"
  echo "      interval: 5s"
  echo "      timeout: 5s"
  echo "      retries: 12"
  if [ "$EN_api" = 1 ]; then
    echo "  postgrest:"
    echo "    image: postgrest/postgrest:v12.2.3"
    echo "    restart: unless-stopped"
    echo "    environment:"
    echo "      PGRST_DB_URI: postgres://authenticator:\${AUTHENTICATOR_PASSWORD}@db:5432/\${POSTGRES_DB}"
    echo "      PGRST_DB_SCHEMAS: public"
    echo "      PGRST_DB_ANON_ROLE: anon"
    echo "      PGRST_JWT_SECRET: \${JWT_SECRET}"
    echo "    ports:"
    echo "      - \"3000:3000\""
    echo "    depends_on:"
    echo "      db:"
    echo "        condition: service_healthy"
  fi
  echo "volumes:"
  echo "  pgdata:"
} > build/docker-compose.yml

# --- report generated secrets once ---
[ "${GEN_PG:-0}" = 1 ]   && echo "generated POSTGRES_PASSWORD=$PG_PW"
[ "${GEN_AUTH:-0}" = 1 ] && echo "generated AUTHENTICATOR_PASSWORD=$AUTH_PW"
[ "${GEN_JWT:-0}" = 1 ]  && echo "generated JWT_SECRET=$JWT"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: build/ generated, not starting Docker"
  exit 0
fi

echo "starting stack..."
docker compose --env-file build/.env -f build/docker-compose.yml up --build
```

Remove the earlier temporary Dockerfile dry-run echo line (`echo "dry-run: generated build/ (Dockerfile)"`) added in Task 4 Step 3, since this block now owns the dry-run exit.

- [ ] **Step 4: Run to verify compose/env tests pass**

Run: `./test/test_setup.sh`
Expected: PASS — `PASS=<n> FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add setup.sh test/test_setup.sh
git commit -m "feat: generate compose + .env and run the stack"
```

---

### Task 8: End-to-end verification with Docker

Manual verification that a generated stack actually boots and serves queries.

**Files:** none (verification only)

- [ ] **Step 1: Generate and boot a representative config**

```bash
cat > config.json <<'JSON'
{ "seed_demo_data": true,
  "capabilities": { "document_store": true, "job_queue": true, "vector": true, "api": true, "auth": true } }
JSON
./setup.sh
```
Expected: image builds (pgvector + pg_graphql, no postgis), both `db` and `postgrest` come up, init logs show products/jobs/documents/notes created.

- [ ] **Step 2: Verify each enabled capability**

In another terminal (substitute the printed `POSTGRES_PASSWORD`):
```bash
psql "postgres://postgres:<PW>@localhost:5432/app" -c "SELECT name FROM products WHERE attributes @> '{\"wireless\":true}';"
psql "postgres://postgres:<PW>@localhost:5432/app" -c "SELECT * FROM dequeue_job();"
psql "postgres://postgres:<PW>@localhost:5432/app" -c "SELECT content FROM documents ORDER BY embedding <=> '[0.10,0.20,0.30]' LIMIT 1;"
curl -s http://localhost:3000/products | head -c 200
```
Expected: each returns rows; the `curl` returns the products JSON array.

- [ ] **Step 3: Verify a disabled capability is absent**

```bash
psql "postgres://postgres:<PW>@localhost:5432/app" -c "SELECT * FROM places;" 2>&1 | grep -q 'does not exist' \
  && echo "gis correctly absent"
```
Expected: prints `gis correctly absent`.

- [ ] **Step 4: Tear down**

```bash
docker compose --env-file build/.env -f build/docker-compose.yml down -v
```

---

### Task 9: Remove superseded files, add .gitignore, update docs

**Files:**
- Delete: `init/00-roles.sh`, `init/01-extensions.sql`, `init/02-schema.sql`, `init/03-api-grants.sql`, `Dockerfile`, `docker-compose.yml`
- Create: `.gitignore`
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Create .gitignore**

`.gitignore`:
```
build/
.env
config.json
.remember/
```

- [ ] **Step 2: Remove superseded top-level files**

```bash
git rm init/00-roles.sh init/01-extensions.sql init/02-schema.sql init/03-api-grants.sql Dockerfile docker-compose.yml
```
The capability fragments under `init/capabilities/` remain.

- [ ] **Step 3: Update README "Run it" section**

Replace the `## Run it` section of `README.md` with:
````markdown
## Run it

```bash
cp config.example.json config.json   # then enable the capabilities you want
./setup.sh                           # generates build/ and starts Docker
```

`setup.sh` reads `config.json`, generates an inspectable `build/` directory (Dockerfile,
docker-compose.yml, .env, assembled `init/*`), then runs `docker compose` from it. Only the
selected capabilities' extensions, tables, and the PostgREST container are provisioned. Inspect
what will run with `cat build/init/02-schema.sql`. Re-run `setup.sh` after editing `config.json`
(use `docker compose -f build/docker-compose.yml down -v` first to wipe the data volume).

Prerequisites: `docker`, `docker compose`, `jq`, `openssl`.
````

- [ ] **Step 4: Update CLAUDE.md lifecycle section**

In `CLAUDE.md`, replace the `## The init-script lifecycle` section so it describes generation: `setup.sh` assembles `build/init/*` from `init/capabilities/*` per `config.json`; the generated scripts still run once on an empty volume; to change capabilities, edit `config.json`, `down -v`, and re-run `setup.sh`. Note `build/` is generated and git-ignored — never hand-edit it.

- [ ] **Step 5: Run the generator tests once more**

Run: `./test/test_setup.sh`
Expected: PASS — `FAIL=0` (removing the old top-level files does not affect the generator, which reads `init/capabilities/`).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: remove static init files, add .gitignore, update docs"
```

---

## Self-Review

**Spec coverage:** capability model + extension mapping (Task 1, 5), dependency rules (Task 3), lean base image (Task 4), `build/` generation with all six artifacts (Tasks 4–7), scoped grants (Task 6), secret generation (Task 7), seed toggle (Task 5), `--dry-run` testability (Task 3+), removal of superseded files (Task 9). All spec sections map to a task.

**Placeholder scan:** no TBD/TODO; every code step contains complete bash/SQL. `<PW>` in Task 8 is an intentional runtime substitution, not a plan placeholder.

**Type/name consistency:** capability flags `EN_<cap>` and the `CAPS`/`SCHEMA_ORDER` arrays use the same nine names throughout; `--dry-run` flag, `build/` paths, and generated filenames (`00-roles.sh`, `01-extensions.sql`, `02-schema.sql`, `03-api-grants.sql`) are consistent across tasks and tests.

**Note on git:** this repo is not yet a git repository. Either run `git init` before Task 1 (recommended, so the per-task commits work) or treat the `git commit`/`git rm` steps as no-ops and remove files with plain `rm`.
