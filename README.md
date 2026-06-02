<div align="center">

# 🐘 Postgres4all

**One Postgres that does the job of your entire backend stack.**

![PostgreSQL 17](https://img.shields.io/badge/PostgreSQL-17-336791?logo=postgresql&logoColor=white)
![pgvector](https://img.shields.io/badge/pgvector-HNSW-4169e1)
![PostgREST](https://img.shields.io/badge/PostgREST-v12.2.3-009639)
![Go](https://img.shields.io/badge/built%20with-Go-00add8?logo=go&logoColor=white)

</div>

---

## What is it?

A typical product stitches together a pile of services — MongoDB for documents, Redis or RabbitMQ for
queues, Elasticsearch for search, Pinecone for vectors, PostGIS for maps, a time-series database for
telemetry, Snowflake for dashboards, and a hand-written service for the API and auth. That's eight
systems to run, secure, integrate, and keep in sync.

Postgres can do every one of those jobs natively. **Postgres4all** lets you declare which of them you
want in a `config.json`, and provisions a single Postgres container (plus an optional PostgREST API)
that does exactly those — and nothing you didn't ask for.

What you get instead of eight systems:

- **One thing to operate** — one database to back up, secure, monitor, and scale.
- **Transactional consistency for free** — storing a document *and* enqueuing a job is a single
  transaction, not a two-phase dance across services.
- **No glue code** — PostgREST turns your schema (and your own SQL functions) into a REST/GraphQL API
  with no application tier in between.

### What each capability replaces

| | Capability | Replaces | Mechanism | Needs |
|:--:|---|---|---|:--:|
| 📄 | `document_store` | MongoDB | `jsonb` + GIN | core |
| 📬 | `job_queue` | Redis / RabbitMQ | `FOR UPDATE SKIP LOCKED` | core |
| 🔍 | `search` | Elasticsearch | `tsvector` + trigrams | `pg_trgm` |
| 🧠 | `vector` | Pinecone | `pgvector` + HNSW | **`pgvector`** |
| 🗺️ | `gis` | GIS systems | PostGIS + GiST | **`postgis`** |
| 📈 | `timeseries` | time-series DB | partitioning + BRIN | core |
| 📊 | `dashboards` | Snowflake | materialized views | core |
| 🔌 | `api` | Node/Python middleware | PostgREST + `pg_graphql` | **`pg_graphql`** |
| 🔐 | `auth` | hand-written auth | row-level security | core |

The **bold** extensions are the only ones that add weight to the image, and they're installed *only*
when you enable that capability. Everything else is core PostgreSQL.

---

## Quick start

```bash
go build ./cmd/postgres4all            # build the ./postgres4all binary
cp config.example.json config.json     # toggle the capabilities you want
./postgres4all install                 # generate build/ and start Docker
```

That's it — Postgres on `localhost:5432`, REST API on `localhost:3000`. Preview what will run first
with `./postgres4all generate` (writes an inspectable `build/`, no Docker). **Needs:** `go`, `docker`,
`docker compose`.

---

## Examples

Each capability is something Postgres can now do — one line of SQL each:

```sql
-- 📄 document store (MongoDB)      — JSONB containment
SELECT name FROM products WHERE attributes @> '{"wireless":true}';

-- 📬 job queue (Redis/RabbitMQ)    — concurrency-safe dequeue
SELECT * FROM dequeue_job();

-- 🔍 search (Elasticsearch)        — stemmed full-text ("run" matches "running")
SELECT title FROM articles WHERE tsv @@ websearch_to_tsquery('english','run');

-- 🧠 vector search (Pinecone)      — semantic + relational filter, one query
SELECT content FROM documents WHERE owner_id = 1
ORDER BY embedding <=> '[0.10,0.20,0.30]' LIMIT 3;

-- 🗺️ maps (PostGIS)                — nearest neighbour
SELECT name FROM places ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-122.41,37.78),4326) LIMIT 5;

-- 📊 dashboards (Snowflake)        — materialized rollup
SELECT * FROM event_daily ORDER BY day;
```

And with `api` enabled, the schema is a REST + GraphQL API for free:

```bash
curl http://localhost:3000/products                     # anonymous read

curl -X POST http://localhost:3000/rpc/submit_product \ # call your own /rpc business logic
  -H 'Content-Type: application/json' \
  -d '{"name":"Keyboard","attributes":{"wireless":true}}'
```

Runnable, seeded versions live in [`examples/`](examples/) — one per capability, each driving the HTTP API and shown in both PL/pgSQL and PL/Python.

---

## Configure

`config.json` toggles capabilities. `dashboards` needs `timeseries`, `auth` needs `api` (enforced).

```jsonc
{
  "postgres": {
    "user": "postgres",
    "db": "app",
    "password": ""
  },
  "seed_demo_data": true,
  "capabilities": {
    "document_store": true,
    "job_queue":      true,
    "search":         false,
    "vector":         false,
    "gis":            false,
    "timeseries":     false,
    "dashboards":     false,
    "api":            true,
    "auth":           false
  },
  "api": {
    "authenticator_password": "",
    "jwt_secret": ""
  },
  "languages": {
    "plperl": false,
    "plpython": false,
    "allow_untrusted": false
  }
}
```

- **Secrets** (`postgres.password`, `api.authenticator_password`, `api.jwt_secret`) are taken from
  config if set, else auto-generated into `build/.env` (mode `0600`). API users read `JWT_SECRET`
  there to mint tokens.
- **Networking:** 5432/3000 bind to `127.0.0.1` only — set `"publish_externally": true` in `postgres`
  to bind all interfaces.
- `build/` is generated and git-ignored — never hand-edit it.

---

## Change capabilities on a running install (no data loss)

Edit `config.json`, then:

```bash
./postgres4all update                # add newly-enabled capabilities
./postgres4all update --allow-drop   # also drop ones you removed (destroys their data)
```

It diffs your config against what's installed and applies just the delta atomically; the data volume
is preserved, so existing data survives.

<details>
<summary>How it works, and the one gotcha</summary>

`update` reads the installed set from `p4a_meta.capabilities`, then applies a phased delta — create
the API role chain if needed → drop removed capabilities → rebuild & recreate the container (volume
preserved) → add new capabilities. Each phase is one transaction, so an interrupted update never
half-applies; existing secrets in `build/.env` are reused.

> **gotcha:** toggling `gis` swaps the image base (`postgres` ↔ `postgis/postgis`, different glibc),
> so Postgres logs a one-time `collation version mismatch` warning. Data is fine; for production,
> `REINDEX` text indexes + `ALTER DATABASE <db> REFRESH COLLATION VERSION`. Language toggles
> (`plperl`/`plpython`) are install-time — changing them needs a fresh build, not `update`.

</details>

---

## Custom business logic (`/rpc`)

Drop SQL functions in `functions/`; each `public`-schema function becomes a `POST /rpc/<name>` endpoint.
The shipped `functions/example_submit.sql` stores a document **and** enqueues a job in one atomic call:

```sql
-- functions/submit_product.sql   →   POST /rpc/submit_product
CREATE OR REPLACE FUNCTION submit_product(name text, attributes jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp   -- run privileged so anon callers can write
AS $$
DECLARE new_id bigint;
BEGIN
  INSERT INTO products (name, attributes) VALUES (name, attributes) RETURNING id INTO new_id;
  INSERT INTO jobs (payload) VALUES (jsonb_build_object('task','index','product_id',new_id));
  RETURN jsonb_build_object('product_id', new_id, 'queued', true);
END $$;

GRANT EXECUTE ON FUNCTION submit_product(text, jsonb) TO anon, authenticated;
```

Apply it (idempotent; reloads PostgREST so the new endpoint is live immediately):

```bash
./postgres4all apply-functions             # apply functions/*.sql
./postgres4all apply-functions --dry-run   # preview the SQL
```

```bash
curl -X POST http://localhost:3000/rpc/submit_product \
  -H 'Content-Type: application/json' -d '{"name":"Keyboard"}'    # -> {"product_id":3,"queued":true}
```

**Supported languages:** `plpgsql` (always on), `plperl` (trusted), and `plpython` (untrusted
`plpython3u`). Enable the latter two in `config.json`'s `languages` block at install time — `plpython`
also requires `"allow_untrusted": true`. A function in any installed language is exposed by PostgREST
the same way.

<details>
<summary>SECURITY DEFINER and other notes</summary>

- A function doing privileged writes for unprivileged callers (`anon`/`authenticated`, who only have
  `SELECT`) must be `SECURITY DEFINER` with a pinned `search_path`, as above — otherwise the caller
  gets `permission denied`.
- Apply is additive (`CREATE OR REPLACE`); deleting a `.sql` file does **not** drop its function —
  run `DROP FUNCTION` yourself.
- Languages are install-time: enabling one on a running install needs a fresh build, not `update`.

</details>

---

## The honest caveat

Not a silver bullet. Past millions of events/sec or sub-millisecond caching for millions of concurrent
connections, reach for purpose-built distributed systems. **Below that, one Postgres is the cheaper,
simpler choice.**

---

## Notes

- **How it works** — `postgres4all` (Go, under `cmd/` + `internal/`) generates `build/` from your
  `config.json`, then drives `docker compose`.
- **Versions** — Postgres 17, PostGIS 3.5, pgvector, pg_graphql 1.5.11, PostgREST 12.2.3 (pinned in
  `internal/generate/generate.go`). Builds for amd64 and arm64.
- **Security** — demo grants are permissive (anon reads everything); tighten before real use.
- **Tests** — `go test ./...`.
