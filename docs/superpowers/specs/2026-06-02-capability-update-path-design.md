# Capability update path for postgres-everything

**Date:** 2026-06-02
**Status:** Approved design, pending spec review
**Builds on:** `2026-06-02-config-driven-provisioning-design.md`

## Problem

The config-driven provisioner only supports **fresh installs**. `setup.sh` runs `docker compose up --build`, which relies on Postgres's entrypoint init scripts — and those run **once, only on an empty data volume**. The capability SQL is also non-idempotent (`CREATE TABLE products`, `CREATE INDEX`, `CREATE POLICY`, `CREATE MATERIALIZED VIEW` with no `IF NOT EXISTS`).

Consequence: adding a capability to a running install (e.g. enabling `gis` on a `document_store` deployment) requires `docker compose down -v`, which **destroys all data**, then a rebuild. There is no in-place update path. This spec adds one.

## Goals

- Add capabilities to an existing, running installation **without data loss**.
- Optionally remove capabilities (destructive), behind an explicit `--allow-drop` flag.
- Keep the delta application **atomic** — a failed update leaves the database exactly as it was.
- Stay testable without Docker, consistent with the existing pure-bash test suite.

## Non-goals

- No data migration of existing rows (only schema objects are added/dropped).
- No version upgrade of Postgres itself or of extensions already installed.
- No rollback of a *successful* update (re-run `--update` with the prior config to reverse additively; removals need `--allow-drop`).
- No change to fresh-install behavior beyond adding the metadata table.

## Command surface

- `./setup.sh` — fresh install (unchanged). **Refuses** with guidance if a managed install already exists (detected via the metadata table on a reachable DB).
- `./setup.sh --update` — apply the config delta to the running stack, **additively** (data preserved). Refuses if there are capabilities to remove, listing them and instructing to pass `--allow-drop`.
- `./setup.sh --update --allow-drop` — additively apply, AND drop capabilities removed from the config (tables + extension).
- `./setup.sh --update --dry-run --installed "<csv>"` — print the computed plan and the generated delta SQL without touching Docker or the DB. Drives the bash test suite. `--installed` supplies the INSTALLED set in place of querying the database.

`--update` and the fresh-install path share all config parsing, validation, and `build/` generation.

## State tracking: `p4a_meta.capabilities`

A new generated init script `build/init/04-meta.sql` (always generated, runs last by filename order) creates:

```sql
CREATE SCHEMA IF NOT EXISTS p4a_meta;
CREATE TABLE IF NOT EXISTS p4a_meta.capabilities (
    cap        text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO p4a_meta.capabilities (cap) VALUES (...enabled caps...)
    ON CONFLICT (cap) DO NOTHING;
```

It lives in a dedicated `p4a_meta` schema (NOT `public`), so PostgREST — which exposes only `public` — never surfaces it, and `anon`/`authenticated` are never granted access to it.

- **Fresh install**: `04-meta.sql` records the installed capabilities as part of init.
- **Update**: `setup.sh` reads `SELECT cap FROM p4a_meta.capabilities` from the running DB to get the INSTALLED set, and amends the table (insert added caps / delete removed caps) inside the delta transaction.
- A reachable DB **without** a `p4a_meta.capabilities` table is treated as "not a managed install" — `--update` errors with guidance (e.g. an install predating this feature).

## Delta computation

```
target    = capabilities enabled in config.json   # validated: >= 1 enabled; deps hold
installed = SELECT cap FROM p4a_meta.capabilities  # or --installed csv in dry-run
ADD       = target  - installed   (canonical order)
REMOVE    = installed - target
```

Dependency validation (the existing `auth`→`api`, `dashboards`→`timeseries` checks) runs on `target` first, so incoherent end states are rejected before any change — including the removal cases (removing `timeseries` while keeping `dashboards`, or removing `api` while keeping `auth`, both fail validation because `target` itself is invalid).

If `REMOVE` is non-empty and `--allow-drop` was not passed: print the would-be-dropped capabilities and exit non-zero without changing anything.

## Execution order (three phases)

Extensions require their binary in the image; `DROP EXTENSION` also requires it. So the image rebuild is sequenced between drops and adds:

1. **Phase 1 — Drops** (only with `--allow-drop`, only if `REMOVE` non-empty). Apply REMOVE SQL on the **currently running** container (binaries still present): for each removed capability in reverse canonical order, its `drop.sql` then `DROP EXTENSION` (if it owns one), and `DELETE FROM p4a_meta.capabilities`. Single `--single-transaction`.
2. **Phase 2 — Rebuild + recreate.** Regenerate `build/` for the `target` config, then `docker compose --env-file build/.env -f build/docker-compose.yml up -d --build`. The named `pgdata` volume is preserved (data survives); the container/image are replaced and the `postgrest` service is added/removed to match `api`. Wait for the db healthcheck.
3. **Phase 3 — Adds** (only if `ADD` non-empty). Apply ADD SQL on the recreated container (new binaries now present): `CREATE EXTENSION` for each added cap that owns one, the added capability `schema.sql` fragments (canonical order), their `seed.sql` if `seed_demo_data` is true, the grant delta (see below), and `INSERT INTO p4a_meta.capabilities`. Single `--single-transaction`.

Postgres DDL (CREATE/DROP TABLE, INDEX, MATERIALIZED VIEW, POLICY, EXTENSION) is transactional, so each phase is atomic: a failure rolls back with metadata intact. Phase 2's rebuild before a failed Phase 3 is harmless (extra binaries available, no schema applied).

SQL is applied via `docker compose exec -T db psql -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"`.

## Grant delta

- **`api` in ADD** (API newly enabled on an existing install): create the role chain (anon/authenticated/authenticator, using `AUTHENTICATOR_PASSWORD` from `build/.env`), `CREATE EXTENSION pg_graphql`, and emit grants for **all** enabled read-tables (same logic as fresh install's `03-api-grants.sql`), plus the graphql-schema grants and `ALTER DEFAULT PRIVILEGES`. Phase 2 brings up the `postgrest` service.
- **`api` already installed, data capability in ADD**: `GRANT SELECT ON <new table> TO anon, authenticated;` for each added read-table; if `auth` in ADD, `GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;`.
- **`api` in REMOVE**: drop the three roles (`DROP OWNED BY` then `DROP ROLE`), `DROP EXTENSION pg_graphql`, delete meta row; Phase 2 regenerates compose without `postgrest`.
- **`api` not involved**: no grant statements.

## New per-capability fragment: `<cap>.drop.sql`

Each capability gains a co-located `init/capabilities/<cap>.drop.sql` mirroring its `schema.sql`, e.g.:

- `document_store.drop.sql`: `DROP TABLE IF EXISTS products CASCADE;`
- `job_queue.drop.sql`: `DROP TABLE IF EXISTS jobs CASCADE; DROP FUNCTION IF EXISTS dequeue_job();`
- `search.drop.sql`: `DROP TABLE IF EXISTS articles CASCADE;`
- `vector.drop.sql`: `DROP TABLE IF EXISTS documents CASCADE;`
- `gis.drop.sql`: `DROP TABLE IF EXISTS places CASCADE;`
- `timeseries.drop.sql`: `DROP TABLE IF EXISTS events CASCADE;` (drops partitions via CASCADE)
- `dashboards.drop.sql`: `DROP MATERIALIZED VIEW IF EXISTS event_daily;`
- `auth.drop.sql`: `DROP TABLE IF EXISTS notes CASCADE;`

`CASCADE` removes dependent indexes/policies/grants. `DROP EXTENSION <ext>` for the owning capability is emitted by `setup.sh` (from the existing extension map), not the fragment, so the fragment stays pure schema-object teardown. The fragments use `IF EXISTS` for safety.

## Data flow (update)

```
config.json ──> setup.sh --update
                  │  parse + validate target (deps)
                  │  generate build/ for target
                  ▼
        query p4a_meta.capabilities (live DB)  ──>  INSTALLED
                  │  ADD = target-INSTALLED, REMOVE = INSTALLED-target
                  │  REMOVE non-empty & no --allow-drop -> refuse
                  ▼
   Phase 1: psql --single-transaction  (drops + DROP EXTENSION + meta delete)   [if --allow-drop]
                  ▼
   Phase 2: docker compose up -d --build   (volume preserved; postgrest added/removed)
                  ▼
   Phase 3: psql --single-transaction  (CREATE EXTENSION + schema + seed + grants + meta insert)
```

## Error handling

- `--update` with no reachable DB / stack not started: error instructing to start it or run a fresh install.
- `--update` on a DB lacking `p4a_meta.capabilities`: error ("not a managed install").
- `REMOVE` non-empty without `--allow-drop`: list the capabilities and exit non-zero, no changes.
- Empty delta (`target == installed`): report "already up to date" and exit 0 without rebuilding.
- `--update` and a fresh `./setup.sh` are mutually exclusive entry points; passing `--allow-drop` without `--update` is an error.
- Each psql phase uses `ON_ERROR_STOP=1 --single-transaction`; a failure aborts the whole phase with no partial application.

## Testing strategy

**Pure-bash unit tests** (extend `test/test_setup.sh`), via `--update --dry-run --installed "<csv>"` which prints a structured plan and the delta SQL:

- ADD computation: installed `document_store`, target `document_store,vector` → plan ADD=vector; delta SQL contains `CREATE EXTENSION IF NOT EXISTS vector` and `CREATE TABLE documents`, and NOT `CREATE TABLE products`.
- REMOVE refusal: installed `document_store,search`, target `document_store`, no `--allow-drop` → exits non-zero, message names `search`, no `DROP` emitted.
- REMOVE with `--allow-drop`: same target → delta contains `DROP TABLE IF EXISTS articles CASCADE` and `DROP EXTENSION` for pg_trgm, and a meta delete.
- Seed toggle on update: ADD=vector with `seed_demo_data:false` → no `INSERT INTO documents`; with true → seeded.
- api-add grants: installed `document_store`, target `document_store,api` → delta creates roles, `CREATE EXTENSION pg_graphql`, grants on `products`.
- api-already-installed table-add grants: installed `document_store,api`, target `+search` → delta grants SELECT on `articles` only (not re-granting products).
- Empty delta: installed == target → "already up to date", exit 0.
- Meta init: a fresh-install generation includes `build/init/04-meta.sql` creating `p4a_meta` and inserting enabled caps.

**Manual Docker e2e** (a plan task): fresh-install `document_store`; `INSERT INTO products` a sentinel row; `./setup.sh --update` with `config.json` now also enabling `vector`; assert the sentinel row still exists AND `documents` table now exists AND `p4a_meta.capabilities` lists both. Then `--update --allow-drop` removing `vector`; assert `documents` gone, `products` + sentinel intact.

## Open implementation choices (non-blocking)

- Whether `setup.sh` should auto-start a stopped stack from the existing volume during `--update`, or require it already running. Leaning toward: bring it up with `up -d` (no `--build`) first if not running, since Phase 2 rebuilds anyway.
- Whether to factor the delta-SQL generation into a separate sourced file (`lib/delta.sh`) as `setup.sh` grows. Leaning toward keeping one file until it exceeds ~350 lines, then splitting.
