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
   `build/init/00-roles.sh` + `01-extensions.sql` + `02-schema.sql` + `03-api-grants.sql`), then runs
   `docker compose` from it. `./setup.sh --dry-run` stops after generation (used by the test suite).
3. `build/` is generated and git-ignored — NEVER hand-edit it; edit `init/capabilities/*` or `setup.sh`.

The generated init scripts still follow Postgres' rule: they run once, in filename order, only on a
fresh data volume. To change capabilities you must edit `config.json`, wipe the volume
(`docker compose -f build/docker-compose.yml down -v`), and re-run `./setup.sh`.

`setup.sh` keeps capability flags in a bash associative array `EN` (`${EN[vector]}` etc). Each
capability owns `init/capabilities/<cap>.schema.sql` and optionally `<cap>.seed.sql`; the assembler
concatenates the enabled ones in a fixed canonical order (`timeseries` before `dashboards`, since the
`event_daily` matview reads the `events` table). Run the generator tests with `./test/test_setup.sh`
(pure bash, no Docker — uses `--dry-run`).

## Architecture

Two containers (defined in the generated `build/docker-compose.yml`):

- **db** — built from the generated `build/Dockerfile`. Base is `postgis/postgis:17-3.5` (which carries the PGDG apt repo and contrib modules pg_trgm / btree_gin / btree_gist). The Dockerfile then adds pgvector via apt and pg_graphql via an arch-aware prebuilt `.deb` from the Supabase release (amd64/arm64 selected at build time). Only present when the `api` capability is enabled.
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
