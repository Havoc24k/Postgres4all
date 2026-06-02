# postgres-everything

A single Postgres container that does the jobs usually handed to Redis, RabbitMQ, Elasticsearch, Pinecone, PostGIS systems, time-series DBs, Snowflake, and a hand-written API layer. A companion PostgREST container turns the schema into a REST API.

## What maps to what

| Capability | Replaces | Mechanism | Needs an extension? |
|---|---|---|---|
| Document store | MongoDB | `jsonb` + GIN index | no (core) |
| Job queue | Redis / RabbitMQ | `FOR UPDATE SKIP LOCKED` | no (core) |
| Search bar | Elasticsearch | `tsvector`/`tsquery` + `pg_trgm` | pg_trgm (contrib) |
| Vector search | Pinecone | `pgvector` + HNSW | **pgvector** |
| Maps / routing | GIS systems | PostGIS + GiST | **postgis** |
| Telemetry / logs | time-series DB | partitioning + BRIN | no (core) |
| Dashboards | Snowflake | materialized views | no (core) |
| REST/GraphQL API | Node/Python middleware | PostgREST + `pg_graphql` | **pg_graphql** + PostgREST |
| Auth | API auth code | row-level security | no (core) |

## Run it

```bash
cp config.example.json config.json   # then enable the capabilities you want
./setup.sh                           # generates build/ and starts Docker
```

`setup.sh` reads `config.json`, generates an inspectable `build/` directory (Dockerfile,
docker-compose.yml, .env, assembled `init/*`), then runs `docker compose` from it. Only the
selected capabilities' extensions, tables, and the PostgREST container are provisioned. Inspect
exactly what will run with `cat build/init/02-schema.sql`. Use `./setup.sh --dry-run` to generate
`build/` without starting Docker.

Re-run `setup.sh` after editing `config.json`. Postgres only runs the init scripts on a fresh data
volume, so to apply schema/capability changes first wipe the volume:
`docker compose -f build/docker-compose.yml down -v`, then `./setup.sh` again.

Prerequisites: `docker`, `docker compose`, `jq`, `openssl`.

### config.json

`capabilities` is a map of the nine features to booleans; only the enabled ones are provisioned.
Two dependencies are enforced (setup errors if violated): `dashboards` requires `timeseries`, and
`auth` requires `api`. `seed_demo_data` (default `true`) controls whether the demo rows are loaded.

Secrets (`postgres.password`, and `api.authenticator_password` / `api.jwt_secret` when `api` is on)
are taken from `config.json` if set, otherwise auto-generated and written to `build/.env` (mode
`0600`). api users read `JWT_SECRET` from `build/.env` to mint tokens. A user-provided
`authenticator_password` is interpolated into a connection URI, so avoid the characters `@ : / ? #`
in it (auto-generated values are hex and safe).

By default the database (5432) and REST API (3000) bind to `127.0.0.1` only. Set
`"publish_externally": true` in the `postgres` block to bind on all interfaces.

> Note: `docker compose up --build` needs buildx >= 0.17.0. On older Docker, build the image with
> the legacy builder first: `DOCKER_BUILDKIT=0 docker build -t postgres-everything:generated build/`,
> then `docker compose --env-file build/.env -f build/docker-compose.yml up -d`.

### Updating an existing install

Change capabilities on a running install WITHOUT wiping data — edit `config.json`, then:

```bash
./setup.sh --update              # add newly-enabled capabilities (non-destructive)
./setup.sh --update --allow-drop # also drop capabilities removed from config (destroys their data)
```

`--update` diffs your config against the capabilities recorded in the database (`p4a_meta.capabilities`)
and applies only the difference: create the API role chain if needed, drop removed capabilities, rebuild
and recreate the container (the `pgdata` volume is preserved, so existing data survives), then add new
capabilities — each step a single transaction. Existing secrets in `build/.env` are reused, so the
superuser password, the PostgREST authenticator password, and the JWT key stay stable across updates.

Preview a delta without touching anything:
`./setup.sh --update --dry-run --installed "document_store" config.json`.

A plain `./setup.sh` refuses if an install already exists — use `--update`, or
`docker compose -f build/docker-compose.yml down -v` to deliberately start over.

> **Caveat — adding/removing `gis`:** this swaps the image base between the `postgres` and
> `postgis/postgis` images, which ship different glibc versions. Postgres will log a one-time
> `collation version mismatch` WARNING after the swap. Data is intact and the demo works as-is; for
> production-grade correctness, `REINDEX` text indexes and run
> `ALTER DATABASE <db> REFRESH COLLATION VERSION` after such a change.

## Try each capability

```sql
-- JSONB containment
SELECT name FROM products WHERE attributes @> '{"wireless":true}';

-- Concurrency-safe queue
SELECT * FROM dequeue_job();

-- Stemmed full-text search ("run" matches "running")
SELECT title FROM articles WHERE tsv @@ websearch_to_tsquery('english','run');

-- Typo-tolerant search
SELECT title, similarity(title,'postgrez') AS s
FROM articles WHERE title % 'postgrez' ORDER BY s DESC;

-- Vector search + relational filter in one query
SELECT content FROM documents
WHERE owner_id = 1 ORDER BY embedding <=> '[0.10,0.20,0.30]' LIMIT 3;

-- Spatial nearest-neighbour
SELECT name FROM places
ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-122.41,37.78),4326) LIMIT 5;

-- Time-series scan over a BRIN-indexed partitioned table
SELECT count(*) FROM events WHERE occurred_at >= '2026-06-01' AND occurred_at < '2026-06-02';

-- Dashboard rollup, refreshed without blocking readers
REFRESH MATERIALIZED VIEW CONCURRENTLY event_daily;
SELECT * FROM event_daily ORDER BY day;

-- GraphQL, in SQL
SELECT graphql.resolve($$ { productsCollection { edges { node { name } } } } $$);
```

## REST API (PostgREST)

```bash
# anonymous read
curl http://localhost:3000/products

# filtered read (PostgREST query syntax)
curl 'http://localhost:3000/products?attributes=cs.{"wireless":true}'
```

The `notes` table is per-user. PostgREST switches to the `authenticated` role when a request carries a valid JWT signed with `JWT_SECRET`; row-level security then limits every read/write to rows whose `owner` equals the token's `sub` claim. Mint a test token (any JWT library) with payload `{"role":"authenticated","sub":"alice"}` and send it as `Authorization: Bearer <token>`.

## The caveat

Not a silver bullet. Postgres scales vertically very well; horizontal sharding for extreme scale is genuinely complex. Past the point of millions of events/sec or sub-millisecond caching for millions of concurrent connections, reach for purpose-built distributed systems. Below it, one Postgres is the cheaper, simpler choice.

## Notes

- Pinned: Postgres 17 + PostGIS 3.5, pgvector from PGDG, pg_graphql v1.5.11, PostgREST v12.2.3. Change `PG_MAJOR` / `POSTGIS_VERSION` / `PG_GRAPHQL_VERSION` in `setup.sh` to move versions (keep them mutually compatible).
- The image builds for both amd64 and arm64 (pg_graphql `.deb` is selected by architecture).
- Demo grants are deliberately permissive (anon can read everything). Tighten them in the relevant `init/capabilities/*.sql` fragment and the grants block of `setup.sh` before any real use.
