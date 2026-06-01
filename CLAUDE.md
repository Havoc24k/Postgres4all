# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Postgres container (plus a PostgREST sidecar) configured to demonstrate that Postgres can stand in for MongoDB, Redis/RabbitMQ, Elasticsearch, Pinecone, PostGIS GIS stacks, time-series DBs, Snowflake, and a hand-written API layer. There is **no application code** — the entire project is a Dockerfile, a compose file, and four init scripts in `init/`. Behavior is defined by SQL and Docker, not by a running language process. See `README.md` for the capability-to-replaced-system mapping and example queries.

## Commands

```bash
cp .env.example .env          # then change every value
docker compose up --build     # builds the image, runs init/ once, starts db + postgrest
docker compose down           # stop (keeps data volume)
docker compose down -v        # stop AND drop the data volume  <-- needed to re-run init scripts

psql postgres://postgres:<POSTGRES_PASSWORD>@localhost:5432/app   # direct SQL
curl http://localhost:3000/products                              # REST API (PostgREST)
```

Postgres listens on `localhost:5432`, PostgREST on `localhost:3000`.

## The init-script lifecycle (most important thing to know)

The official Postgres entrypoint runs every file in `/docker-entrypoint-initdb.d/` (populated from `init/`) **exactly once, in filename order, and only when the data volume is empty**. Consequences:

- Editing any `init/*` file does **not** take effect on a normal `docker compose up`. You must `docker compose down -v` to wipe the `pgdata` volume, then `up --build` to re-initialize.
- File order matters and is encoded in the numeric prefixes:
  - `00-roles.sh` — creates the PostgREST role chain (`anon`, `authenticated`, `authenticator`). Shell, not SQL, because it injects `AUTHENTICATOR_PASSWORD` from the container environment so no secret lands in a committed file.
  - `01-extensions.sql` — `CREATE EXTENSION` for pg_trgm, btree_gin, vector (pgvector), postgis, pg_graphql.
  - `02-schema.sql` — all demo tables, indexes, the `dequeue_job()` function, and RLS policy on `notes`.
  - `03-api-grants.sql` — grants that expose the schema to the API roles.
- PostGIS's own init `.sh` (from the base image) also lives in this directory and runs before these.

## Architecture

Two containers (`docker-compose.yml`):

- **db** — built from `Dockerfile`. Base is `postgis/postgis:17-3.5` (which carries the PGDG apt repo and contrib modules pg_trgm / btree_gin / btree_gist). The Dockerfile then adds pgvector via apt and pg_graphql via an arch-aware prebuilt `.deb` from the Supabase release (amd64/arm64 selected at build time).
- **postgrest** — `postgrest/postgrest:v12.2.3`. Connects as the `authenticator` login role and switches to `anon` (no JWT) or `authenticated` (valid JWT) per request.

**The PostgREST security model** spans three files and is the trickiest part:
- `00-roles.sh` creates `authenticator` (NOINHERIT LOGIN) which can `SET ROLE` to `anon` or `authenticated`.
- `02-schema.sql` enables row-level security on `notes` with a policy keying `owner` to the JWT `sub` claim (`current_setting('request.jwt.claims', true)::json ->> 'sub'`).
- `03-api-grants.sql` grants `anon` read on the public demo tables and `authenticated` full CRUD on `notes` (RLS then scopes it per user).
- A request authenticates by sending a JWT (HMAC-signed with `JWT_SECRET`) carrying `{"role":"authenticated","sub":"<user>"}` as a Bearer token.

## Versioning

Versions are pinned in `docker-compose.yml` build args (`PG_MAJOR`, `PG_GRAPHQL_VERSION`) and image tags. To move versions, change these args and keep Postgres / PostGIS / pgvector / pg_graphql / PostgREST mutually compatible. Changing `PG_MAJOR` also changes the PostGIS base image tag and the pg_graphql `.deb` URL — both derive from it.

## Conventions

- Everything lives in the `public` schema so PostgREST and pg_graphql expose it with zero extra config.
- Each section of `02-schema.sql` is one self-contained capability, headed by a comment naming the system it replaces, with a runnable example query in the trailing comment.
- Grants in `03-api-grants.sql` are deliberately permissive for a demo (anon reads everything). Tighten before any real use.
