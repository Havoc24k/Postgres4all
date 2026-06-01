# postgres-everything

A single Postgres container that does the jobs the video ("I replaced my entire stack with Postgres") hands to Redis, RabbitMQ, Elasticsearch, Pinecone, PostGIS systems, time-series DBs, Snowflake, and a hand-written API layer. A companion PostgREST container turns the schema into a REST API.

## What maps to what

| Video claim | Replaces | Mechanism | Needs an extension? |
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
cp .env.example .env      # then edit the values
docker compose up --build
```

First boot builds the image (installs pgvector + pg_graphql) and runs every script in `init/` once. Postgres is on `localhost:5432`, the REST API on `localhost:3000`.

```bash
psql postgres://postgres:<POSTGRES_PASSWORD>@localhost:5432/app
```

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

## The caveat the video itself gives

Not a silver bullet. Postgres scales vertically very well; horizontal sharding for extreme scale is genuinely complex. Past the point of millions of events/sec or sub-millisecond caching for millions of concurrent connections, reach for purpose-built distributed systems. Below it, one Postgres is the cheaper, simpler choice.

## Notes

- Pinned: Postgres 17 + PostGIS 3.5, pgvector from PGDG, pg_graphql v1.5.11, PostgREST v12.2.3. Change `PG_MAJOR` / `PG_GRAPHQL_VERSION` in `docker-compose.yml` to move versions (keep them mutually compatible).
- The image builds for both amd64 and arm64 (pg_graphql `.deb` is selected by architecture).
- Demo grants are deliberately permissive (anon can read everything). Tighten the grants in `init/03-api-grants.sql` before any real use.
