# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Postgres container (plus a PostgREST sidecar) configured to demonstrate that Postgres can stand in for MongoDB, Redis/RabbitMQ, Elasticsearch, Pinecone, PostGIS GIS stacks, time-series DBs, Snowflake, and a hand-written API layer. There is **no application code** — the entire project is `setup.sh`, `config.json`, and per-capability SQL fragments in `init/capabilities/`. Behavior is defined by SQL and Docker, not by a running language process. See `README.md` for the capability-to-replaced-system mapping and example queries.

## Commands

```bash
cp config.example.json config.json   # then enable the capabilities you want
./setup.sh                           # generates build/ and starts Docker
./setup.sh --dry-run                 # generate build/ without starting Docker
docker compose -f build/docker-compose.yml down      # stop (keeps data volume)
docker compose -f build/docker-compose.yml down -v   # stop AND drop the data volume  <-- needed to re-run init scripts

psql postgres://postgres:<POSTGRES_PASSWORD>@localhost:5432/app   # direct SQL
curl http://localhost:3000/products                              # REST API (PostgREST)
```

Postgres listens on `localhost:5432`, PostgREST on `localhost:3000`.

## Provisioning model (most important thing to know)

There is no static Dockerfile/compose/init SQL in the repo root anymore — `setup.sh` GENERATES them
into `build/` from `config.json` plus the per-capability fragments in `init/capabilities/`. The flow:

1. User copies `config.example.json` to `config.json` and toggles capabilities.
2. `./setup.sh` validates the config, assembles `build/` (Dockerfile, docker-compose.yml, .env, and
   `build/init/00-roles.sh` + `01-extensions.sql` + `02-schema.sql` + `03-api-grants.sql` + `04-meta.sql`), then runs
   `docker compose` from it. `./setup.sh --dry-run` stops after generation (used by the test suite).
3. `build/` is generated and git-ignored — NEVER hand-edit it; edit `init/capabilities/*` or `setup.sh`.

The generated init scripts still follow Postgres' rule: they run once, in filename order, only on a
fresh data volume. So on a fresh volume `./setup.sh` provisions everything via those init scripts; on an
existing install, use `./setup.sh --update` (see "Updating in place" below) to change capabilities
without losing data. A full `down -v` + `./setup.sh` is only needed if you want to start over from scratch.

`setup.sh` keeps capability flags in a bash associative array `EN` (`${EN[vector]}` etc). Each
capability owns `init/capabilities/<cap>.schema.sql` and optionally `<cap>.seed.sql`; the assembler
concatenates the enabled ones in a fixed canonical order (`timeseries` before `dashboards`, since the
`event_daily` matview reads the `events` table). Run the generator tests with `./test/test_setup.sh`
(pure bash, no Docker — uses `--dry-run`).

**Updating in place:** `./setup.sh --update` (add) / `--update --allow-drop` (add + remove) changes
capabilities without `down -v`. It reads the installed set from `p4a_meta.capabilities` (a dedicated
schema, never exposed by PostgREST), computes ADD/REMOVE, and applies a delta in phases: Phase 0 creates
the role chain (idempotent, before the rebuild so PostgREST doesn't crash-loop) → Phase 1 drops on the
current image → `up -d --build --remove-orphans` (volume preserved) → Phase 3 adds on the new image,
each a single `psql --single-transaction`. Tables are always granted AFTER they're created; removing
`api` REVOKEs the superuser-owned default-priv ACL before dropping `anon`. Update reuses prior secrets
from `build/.env`. Per-capability teardown is in `init/capabilities/<cap>.drop.sql`. Update logic is
unit-tested by `test/test_update.sh` via `--update --dry-run --installed "<csv>"` (no Docker). Note:
toggling `gis` swaps the postgres/postgis image base (different glibc) and triggers a benign Postgres
collation-version-mismatch warning.

**Custom functions:** user business logic lives in top-level `functions/*.sql` (not generated, not
init — user space). `./setup.sh --apply-functions` concatenates them (LC_ALL=C sorted) and runs one
`psql --single-transaction`, with `NOTIFY pgrst, 'reload schema'` as the last statement so PostgREST
serves the new `/rpc` endpoints live. It is handled in its own branch BEFORE any config read (so it
needs no `config.json`), requires an existing install (pgdata volume), and reads `PG_USER`/`PG_DB`
from `build/.env`. `--apply-functions --dry-run` prints the SQL with no Docker (tested by
`test/test_functions.sh`). A function doing privileged writes for unprivileged callers must be
`SECURITY DEFINER` (see `functions/example_submit.sql`). Procedural languages beyond `plpgsql` are
install-time toggles in the `languages` config: `plperl` (trusted) and `plpython` (untrusted
`plpython3u`, gated behind `allow_untrusted`); they add apt installs (`postgresql-plperl-17` —
lang-then-version) to `build/Dockerfile` and `CREATE EXTENSION` to `01-extensions.sql`. Changing a
language needs a fresh build (down -v); it is not wired into `--update`.

## Architecture

Two containers (defined in the generated `build/docker-compose.yml`):

- **db** — always present; built from the generated `build/Dockerfile`. Base is `postgis/postgis:17-3.5` when the `gis` capability is enabled, otherwise the lighter `postgres:17`. pgvector is added via apt only when `vector` is enabled; pg_graphql via an arch-aware prebuilt `.deb` from the Supabase release (amd64/arm64 selected at build time) only when `api` is enabled. Both base images carry the PGDG apt repo and the contrib modules; of these the assembler only ever activates `pg_trgm` (`CREATE EXTENSION`), and only when `search` is enabled.
- **postgrest** — `postgrest/postgrest:v12.2.3`. Connects as the `authenticator` login role and switches to `anon` (no JWT) or `authenticated` (valid JWT) per request. Only present when the `api` capability is enabled.

**The PostgREST security model** spans three generated init files and is the trickiest part:
- `build/init/00-roles.sh` creates `authenticator` (NOINHERIT LOGIN) which can `SET ROLE` to `anon` or `authenticated`.
- `build/init/02-schema.sql` enables row-level security on `notes` with a policy keying `owner` to the JWT `sub` claim (`current_setting('request.jwt.claims', true)::json ->> 'sub'`).
- `build/init/03-api-grants.sql` grants `anon` read on the public demo tables and `authenticated` full CRUD on `notes` (RLS then scopes it per user).
- A request authenticates by sending a JWT (HMAC-signed with `JWT_SECRET`) carrying `{"role":"authenticated","sub":"<user>"}` as a Bearer token.

## Versioning

Versions are pinned in `setup.sh` (Postgres base image, pg_graphql version, PostgREST image tag). To move versions, change these in `setup.sh` and keep Postgres / PostGIS / pgvector / pg_graphql / PostgREST mutually compatible. Changing `PG_MAJOR` also changes the PostGIS base image tag and the pg_graphql `.deb` URL — both derive from it.

## Conventions

- Everything lives in the `public` schema so PostgREST and pg_graphql expose it with zero extra config.
- Each capability's schema is in `init/capabilities/<cap>.schema.sql`, headed by a comment naming the system it replaces, with a runnable example query in the trailing comment.
- Grants in `init/capabilities/` (assembled into `build/init/03-api-grants.sql`) are deliberately permissive for a demo (anon reads everything). Tighten before any real use.
