# Config-driven provisioning for postgres-everything

**Date:** 2026-06-02
**Status:** Approved design, pending spec review

## Problem

The repo provisions all nine "replace your stack" capabilities at once: `init/01-extensions.sql` installs every extension and `init/02-schema.sql` creates every table. A user who only wants, say, a document store and a job queue still pays for PostGIS, pgvector, pg_graphql, and a PostgREST container.

We want a flow where:

1. The user writes a `config.json` declaring which capabilities they want.
2. The user (or an agent) runs `./setup.sh`.
3. Setup provisions **only** the selected capabilities — their tables, their extensions, and the API container — entirely via Docker.

## Goals

- One declarative input file (`config.json`) drives the whole stack.
- Only the extensions and tables needed by the enabled capabilities are provisioned.
- The image is lean: skip the heavy PostGIS base image when GIS is off; skip pgvector/pg_graphql apt installs when those capabilities are off.
- The generated artifacts are transparent and inspectable before they run.
- Arbitrary toggle combinations are safe (no grants on non-existent tables, no missing extensions).

## Non-goals

- No change to *what* each capability does — the SQL semantics are copied from the existing `init/02-schema.sql`, only reorganized.
- No multi-node / sharding / production-hardening work. This stays a single-container demo provisioner.
- No web UI or interactive wizard. The interface is `config.json` + `setup.sh`.

## Capability model

Nine capabilities. Each owns a `.schema.sql` (DDL + functions) and, where a runnable demo needs rows, a `.seed.sql`.

| Capability | Extension(s) | Read table(s) | Seed file? |
|---|---|---|---|
| `document_store` | — | `products` | yes |
| `job_queue` | — | `jobs` | yes |
| `search` | `pg_trgm` | `articles` | yes |
| `vector` | `vector` (pgvector, apt) | `documents` | yes |
| `gis` | `postgis` (base image) | `places` | yes |
| `timeseries` | — | `events` | yes |
| `dashboards` | — | `event_daily` | no (matview derives from `events`) |
| `api` | `pg_graphql` (apt) + PostgREST container | — | no |
| `auth` | — | `notes` | no (rows need a JWT `sub` owner) |

Capabilities with no extension use core Postgres features (jsonb+GIN, `FOR UPDATE SKIP LOCKED`, declarative partitioning + BRIN, materialized views, row-level security).

`btree_gin` from the original `01-extensions.sql` is **dropped** — no demo index uses it.

### Dependency rules

Validated by `setup.sh`; a violation is a hard error (exit non-zero, clear message):

- `dashboards` requires `timeseries` — the `event_daily` materialized view aggregates the `events` table.
- `auth` requires `api` — per-user row-level security is enforced through PostgREST switching to the `authenticated` role using the request's JWT. Without PostgREST there is no role switch to scope rows.

## Approach: generate a self-contained `build/` directory

`setup.sh` reads `config.json` (parsed with `jq`) and **generates** a `build/` directory, then runs Compose from it. Generation — rather than runtime `DO`-block guards or Compose profiles — is chosen because the result is fully inspectable (`cat build/init/02-schema.sql` shows exactly what runs), no dead extensions are installed, and the lean base-image swap falls out naturally.

### Source layout (edited by humans)

```
config.example.json            # documented template -> copied to config.json
setup.sh                       # the provisioner
init/capabilities/
  document_store.schema.sql  document_store.seed.sql
  job_queue.schema.sql       job_queue.seed.sql
  search.schema.sql          search.seed.sql
  vector.schema.sql          vector.seed.sql
  gis.schema.sql             gis.seed.sql
  timeseries.schema.sql      timeseries.seed.sql
  dashboards.schema.sql
  auth.schema.sql
```

The original top-level `init/*.sql`, `Dockerfile`, and `docker-compose.yml` are superseded by generated equivalents under `build/`. (Kept in the repo as reference, or removed — decided at implementation time; the generator does not depend on them.)

### Generated layout (produced by `setup.sh`, never hand-edited)

```
build/
  Dockerfile            # base postgis/postgis:17-3.5 IF gis ELSE postgres:17;
                        # apt pgvector IF vector; arch-aware pg_graphql .deb IF api
  docker-compose.yml    # db service always; postgrest service only IF api
  .env                  # POSTGRES_* always; AUTHENTICATOR_PASSWORD + JWT_SECRET only IF api
  init/
    00-roles.sh         # anon/authenticated/authenticator chain -- only IF api
    01-extensions.sql   # only the CREATE EXTENSION lines the enabled set needs
    02-schema.sql       # concatenated <cap>.schema.sql (+ <cap>.seed.sql if seeding)
    03-api-grants.sql   # only IF api; GRANT SELECT scoped to tables that exist
```

## Data flow

```
config.json ── jq ──> setup.sh
                         │  validate (json, >=1 cap, dependency rules, prereqs)
                         │  resolve secrets (from config or openssl rand)
                         ▼
                    build/ (Dockerfile, compose, .env, init/*)
                         │
                         ▼
        docker compose -f build/docker-compose.yml up --build
                         │
            ┌────────────┴─────────────┐
            ▼                          ▼
     db (Postgres)            postgrest (only if api)
     runs init/* once         REST + GraphQL on :3000
     on empty volume
```

## config.json schema

```json
{
  "postgres": {
    "user": "postgres",
    "db": "app",
    "password": "optional - auto-generated if omitted"
  },
  "seed_demo_data": true,
  "capabilities": {
    "document_store": true,
    "job_queue": true,
    "search": false,
    "vector": true,
    "gis": false,
    "timeseries": false,
    "dashboards": false,
    "api": true,
    "auth": true
  },
  "api": {
    "authenticator_password": "optional - auto-generated if omitted",
    "jwt_secret": "optional - auto-generated (>=32 chars) if omitted"
  }
}
```

Defaults applied by `setup.sh`: any capability omitted → `false`; `seed_demo_data` omitted → `true`; `postgres.user` → `postgres`; `postgres.db` → `app`. Any missing secret is generated with `openssl rand` and printed to stdout once.

## setup.sh responsibilities

Ordered steps, fail-fast (`set -euo pipefail`):

1. **Preflight** — verify `docker`, `docker compose`, `jq`, `openssl` are on PATH; clear error + exit if not.
2. **Locate config** — `$1` if given, else `./config.json`; error if absent or invalid JSON.
3. **Read** — extract capability booleans, `seed_demo_data`, postgres settings, and secrets via `jq`.
4. **Validate** — at least one capability enabled; enforce the two dependency rules; error and stop on violation.
5. **Assemble `build/`** — wipe and recreate `build/`; emit `Dockerfile`, `docker-compose.yml`, `init/01-extensions.sql`, `init/02-schema.sql`, and — only if `api` — `init/00-roles.sh` and `init/03-api-grants.sql`. `02-schema.sql` concatenates the enabled capabilities in a fixed **canonical order**, not config order, so output is deterministic and dependency-correct: `document_store, job_queue, search, vector, gis, timeseries, dashboards, auth`. `timeseries` precedes `dashboards` deliberately — the `event_daily` matview is created `WITH DATA` reading the `events` table, so that table must already exist.
6. **Resolve secrets → `.env`** — use config-provided values or generate; write `build/.env`; print generated values once.
7. **Run** — `docker compose -f build/docker-compose.yml up --build`.

### Grant generation detail

`03-api-grants.sql` is generated from the enabled set, never static:

- `GRANT USAGE ON SCHEMA public TO anon, authenticated;`
- `GRANT SELECT ON <enabled read tables> TO anon, authenticated;` — list built from the enabled capabilities' read tables (`products`, `jobs`, `articles`, `documents`, `places`, `events`, `event_daily`). A `GRANT` on a table that was never created would error, so only existing tables are listed.
- If `auth`: `GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;`
- `GRANT USAGE ON SCHEMA graphql ...` and `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql ...` (pg_graphql is always present when `api` is on).
- `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;`

## Error handling

- Missing prerequisite tool → named error, exit 1.
- Missing/invalid `config.json` → error naming the path, exit 1.
- Zero capabilities enabled → error, exit 1.
- Dependency violation → message naming the capability and its requirement (e.g. `capability 'auth' requires 'api'`), exit 1.
- All validation happens before any `build/` file is written, so a failed run leaves no half-generated artifacts beyond a freshly cleared `build/`.

## Testing strategy

- **Smoke matrix** — generate `build/` for representative configs and assert the generated files contain exactly the expected extensions/tables/services:
  - minimal: only `document_store` → no extensions, no postgrest, no roles file.
  - api+auth: asserts `00-roles.sh`, `03-api-grants.sql` with `notes` CRUD, postgrest service present.
  - vector but not gis: Dockerfile base is `postgres:17`, installs pgvector, no postgis.
  - full: all nine → matches the original repo's behavior.
- **Dependency rejection** — `auth` without `api` and `dashboards` without `timeseries` each exit non-zero with the expected message.
- **End-to-end** (manual / optional in CI): bring up the minimal and full configs, run one representative query per enabled capability and a PostgREST `curl` when `api` is on.

## Open implementation choices (non-blocking)

- Whether to delete the original top-level `init/`, `Dockerfile`, `docker-compose.yml` or keep them as reference. Leaning toward removing them once `setup.sh` reproduces the full config, to avoid two sources of truth.
- Whether the smoke matrix is a shell script (`test/` with `bats`-style asserts) or just documented manual checks. Leaning toward a small `test_setup.sh` that runs the generator and greps the output — no Docker needed, fast.
