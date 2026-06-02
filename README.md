<div align="center">

# 🐘 Postgres4all

**One Postgres that replaces your whole backend stack.** One `config.json`, one command.

It stands in for MongoDB, Redis/RabbitMQ, Elasticsearch, Pinecone, PostGIS stacks, time-series DBs,
Snowflake, and a hand-written API layer — only the capabilities you switch on are provisioned.

![PostgreSQL 17](https://img.shields.io/badge/PostgreSQL-17-336791?logo=postgresql&logoColor=white)
![pgvector](https://img.shields.io/badge/pgvector-HNSW-4169e1)
![PostgREST](https://img.shields.io/badge/PostgREST-v12.2.3-009639)
![Go](https://img.shields.io/badge/built%20with-Go-00add8?logo=go&logoColor=white)

</div>

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

---

## What replaces what

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

The **bold** extensions are the only ones that add weight to the image, installed *only* when you
enable that capability. Everything else is core PostgreSQL.

---

## Configure

`config.json` toggles capabilities. `dashboards` needs `timeseries`, `auth` needs `api` (enforced).

```jsonc
{
  "postgres": { "user": "postgres", "db": "app", "password": "" },
  "seed_demo_data": true,
  "capabilities": { "document_store": true, "job_queue": true, "api": true },
  "api": { "authenticator_password": "", "jwt_secret": "" }
}
```

<details>
<summary>More options (secrets, networking, all keys)</summary>

```jsonc
{
  "postgres": {
    "user": "postgres", "db": "app", "password": "",
    "publish_externally": false        // bind 0.0.0.0 instead of 127.0.0.1
  },
  "seed_demo_data": true,              // load demo rows (default true)
  "capabilities": {
    "document_store": false, "job_queue": false, "search": false,
    "vector": false, "gis": false, "timeseries": false,
    "dashboards": false, "api": false, "auth": false
  },
  "api": { "authenticator_password": "", "jwt_secret": "" },
  "languages": { "plperl": false, "plpython": false, "allow_untrusted": false }
}
```

- **Secrets** (`postgres.password`, `api.authenticator_password`, `api.jwt_secret`) are taken from
  config if set, else auto-generated into `build/.env` (mode `0600`). API users read `JWT_SECRET`
  there to mint tokens. Avoid `@ : / ? #` in a user-set `authenticator_password` (it goes into a URI).
- **Networking:** 5432/3000 bind to `127.0.0.1` only unless `publish_externally: true`.
- `build/` is generated and git-ignored — never hand-edit it.

</details>

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

```bash
./postgres4all apply-functions             # apply functions/*.sql + reload PostgREST
./postgres4all apply-functions --dry-run   # preview the SQL
```

The shipped `functions/example_submit.sql` writes a document **and** enqueues a job in one atomic call.

<details>
<summary>SECURITY DEFINER, and other languages</summary>

- A function doing privileged writes for unprivileged callers (`anon`/`authenticated`, who only have
  `SELECT`) must be `SECURITY DEFINER` with a pinned `search_path` — see the example. Otherwise the
  caller gets `permission denied`.
- Apply is additive (`CREATE OR REPLACE`); deleting a `.sql` file does **not** drop its function —
  run `DROP FUNCTION` yourself.
- Beyond `plpgsql`, enable `plperl` (trusted) or `plpython` (untrusted `plpython3u`, gated behind
  `"allow_untrusted": true`) in the `languages` block at install time.

</details>

---

## The honest caveat

Not a silver bullet. Past millions of events/sec or sub-millisecond caching for millions of concurrent
connections, reach for purpose-built distributed systems. **Below that, one Postgres is the cheaper,
simpler choice.**

---

## Notes

`postgres4all` (Go, under `cmd/` + `internal/`) generates `build/` from `config.json` using embedded
templates + capability SQL fragments, then drives `docker compose`. Run the tests with `go test ./...`.
Pinned: Postgres 17 / PostGIS 3.5 / pgvector / pg_graphql 1.5.11 / PostgREST 12.2.3 (constants in
`internal/generate/generate.go`); builds for amd64 + arm64. Demo grants are permissive (anon reads
everything) — tighten before real use.
