<div align="center">

# 🐘 Postgres4all

**One Postgres container that does the job of your entire backend stack.**

Pick the capabilities you want in a `config.json`, run one script, and get a single
Postgres (plus an optional PostgREST API) that stands in for MongoDB, Redis/RabbitMQ,
Elasticsearch, Pinecone, PostGIS stacks, time-series DBs, Snowflake, and a hand-written API layer.

![PostgreSQL 17](https://img.shields.io/badge/PostgreSQL-17-336791?logo=postgresql&logoColor=white)
![PostGIS 3.5](https://img.shields.io/badge/PostGIS-3.5-4d8b3c)
![pgvector](https://img.shields.io/badge/pgvector-HNSW-4169e1)
![pg_graphql](https://img.shields.io/badge/pg__graphql-1.5.11-e10098)
![PostgREST](https://img.shields.io/badge/PostgREST-v12.2.3-009639)
![License](https://img.shields.io/badge/runs%20on-Docker-2496ed?logo=docker&logoColor=white)

</div>

---

## Contents

- [What replaces what](#what-replaces-what)
- [Quick start](#quick-start)
- [`config.json`](#configjson)
- [Updating an existing install](#updating-an-existing-install)
- [Custom business logic (`/rpc`)](#custom-business-logic-rpc)
- [Go CLI (in progress)](#go-cli-in-progress)
- [Try each capability](#try-each-capability)
- [REST API](#rest-api)
- [The honest caveat](#the-honest-caveat)
- [Notes](#notes)

---

## What replaces what

Each capability is a toggle in `config.json`. Only the ones you enable are provisioned —
their tables, their extensions, and (for the API) the PostgREST container.

| | Capability | Replaces | Mechanism | Extension |
|:--:|---|---|---|:--:|
| 📄 | Document store | MongoDB | `jsonb` + GIN index | core |
| 📬 | Job queue | Redis / RabbitMQ | `FOR UPDATE SKIP LOCKED` | core |
| 🔍 | Search | Elasticsearch | `tsvector`/`tsquery` + trigrams | `pg_trgm` |
| 🧠 | Vector search | Pinecone | `pgvector` + HNSW | **`pgvector`** |
| 🗺️ | Maps / routing | GIS systems | PostGIS + GiST | **`postgis`** |
| 📈 | Telemetry / logs | time-series DB | partitioning + BRIN | core |
| 📊 | Dashboards | Snowflake | materialized views | core |
| 🔌 | REST / GraphQL API | Node / Python middleware | PostgREST + `pg_graphql` | **`pg_graphql`** |
| 🔐 | Auth | hand-written auth code | row-level security | core |

> [!NOTE]
> **core** = built into PostgreSQL, no extension needed. The **bold** extensions are the only
> ones that add weight to the image, and they're installed *only* when you enable that capability.

---

## Quick start

```bash
cp config.example.json config.json   # then enable the capabilities you want
./setup.sh                           # generates build/ and starts Docker
```

`setup.sh` reads `config.json`, generates an inspectable `build/` directory (Dockerfile,
`docker-compose.yml`, `.env`, assembled `init/*`), then runs `docker compose` from it. Only the
selected capabilities are provisioned. See exactly what will run before it does:

```bash
cat build/init/02-schema.sql        # the assembled schema
./setup.sh --dry-run                # generate build/ without starting Docker
```

Once it's up — Postgres on `localhost:5432`, REST API on `localhost:3000`:

```bash
psql postgres://postgres:<POSTGRES_PASSWORD>@localhost:5432/app
```

> [!IMPORTANT]
> **Prerequisites:** `docker`, `docker compose`, `jq`, `openssl`.

---

## `config.json`

`capabilities` is a map of the nine features to booleans; only the enabled ones are provisioned.

- **Dependencies** (enforced — `setup.sh` errors if violated): `dashboards` requires `timeseries`;
  `auth` requires `api`.
- **`seed_demo_data`** (default `true`) controls whether the demo rows are loaded.
- **Secrets** (`postgres.password`, and `api.authenticator_password` / `api.jwt_secret` when `api`
  is on) are taken from `config.json` if set, otherwise auto-generated and written to `build/.env`
  (mode `0600`). API users read `JWT_SECRET` from `build/.env` to mint tokens.
- **Networking:** the database (5432) and REST API (3000) bind to `127.0.0.1` only by default. Set
  `"publish_externally": true` in the `postgres` block to bind on all interfaces.

```jsonc
{
  "postgres": { "user": "postgres", "db": "app", "password": "" },
  "seed_demo_data": true,
  "capabilities": {
    "document_store": true,
    "job_queue":      true,
    "search":         false,
    "vector":         false,
    "gis":            false,
    "timeseries":     false,
    "dashboards":     false,
    "api":            false,
    "auth":           false
  },
  "api": { "authenticator_password": "", "jwt_secret": "" }
}
```

> [!TIP]
> A user-provided `authenticator_password` is interpolated into a connection URI, so avoid the
> characters `@ : / ? #` in it (auto-generated values are hex and safe).

> [!NOTE]
> `docker compose up --build` needs buildx ≥ 0.17.0. On older Docker, build with the legacy builder
> first: `DOCKER_BUILDKIT=0 docker build -t postgres4all:generated build/`, then
> `docker compose --env-file build/.env -f build/docker-compose.yml up -d`.

---

## Updating an existing install

Change capabilities on a **running** install without wiping data — edit `config.json`, then:

```bash
./setup.sh --update              # add newly-enabled capabilities (non-destructive)
./setup.sh --update --allow-drop # also drop capabilities removed from config (destroys their data)
```

`--update` diffs your config against the capabilities recorded in the database
(`p4a_meta.capabilities`) and applies only the difference, in phases — create the API role chain if
needed → drop removed capabilities → rebuild & recreate the container (the `pgdata` volume is
**preserved**, so data survives) → add new capabilities. Each phase is a single transaction, so an
interrupted update never leaves a half-applied state. Existing secrets in `build/.env` are reused,
so the superuser password, the PostgREST authenticator password, and the JWT key stay stable.

Preview a delta without touching anything:

```bash
./setup.sh --update --dry-run --installed "document_store" config.json
```

A plain `./setup.sh` refuses if an install already exists — use `--update`, or
`docker compose -f build/docker-compose.yml down -v` to deliberately start over.

> [!WARNING]
> **Adding/removing `gis`** swaps the image base between the `postgres` and `postgis/postgis`
> images, which ship different glibc versions, so Postgres logs a one-time `collation version
> mismatch` warning after the swap. Data is intact and the demo works as-is; for production-grade
> correctness, `REINDEX` text indexes and run `ALTER DATABASE <db> REFRESH COLLATION VERSION`.

---

## Custom business logic (`/rpc`)

Drop SQL functions into the top-level `functions/` directory and apply them to a running install:

```bash
./setup.sh --apply-functions             # apply functions/*.sql, then reload PostgREST
./setup.sh --apply-functions --dry-run   # print the SQL without applying
```

Each function in the `public` schema becomes a `POST /rpc/<name>` endpoint (or `GET` if `STABLE`).
Files are applied in one transaction (all-or-nothing) using your `CREATE OR REPLACE` definitions, so
re-applying is how you ship edits. A function can leverage any enabled capability — the shipped
`functions/example_submit.sql` writes a document **and** enqueues a job in a single call (it needs
`document_store`, `job_queue`, and `api`). `--apply-functions` reloads an already-running PostgREST;
it does not start the stack.

> [!TIP]
> A function that performs privileged writes (INSERT/UPDATE) on behalf of unprivileged callers
> (`anon`/`authenticated`, who typically only have `SELECT`) should be declared `SECURITY DEFINER`
> with a pinned `search_path` — see `functions/example_submit.sql`. That's the canonical way to expose
> a controlled write as an RPC; without it the caller gets `permission denied`.

> [!NOTE]
> **Deleting a `.sql` file does not drop its function** from the database — `apply-functions` is
> additive (`CREATE OR REPLACE`). Run `DROP FUNCTION <name>(<args>)` yourself to remove one.

**Other languages.** `plpgsql` is always available. Enable more in the `languages` block of
`config.json` *at install time*:

| Language | `languages` key | Trusted? |
|---|---|---|
| PL/pgSQL | (always on) | ✅ |
| PL/Perl | `"plperl": true` | ✅ |
| PL/Python | `"plpython": true` + `"allow_untrusted": true` | ❌ untrusted |

> [!WARNING]
> `plpython` uses `plpython3u`, an **untrusted** language (functions run with the database OS user's
> full privileges). It is gated behind `"allow_untrusted": true` and is unsafe for code you didn't
> write. Languages are **install-time**: enabling one on an already-running install requires a fresh
> build (`docker compose -f build/docker-compose.yml down -v` then `./setup.sh`) — `--update` does not
> pick up language changes.

---

## Go CLI (in progress)

A Go rewrite of `setup.sh` — a single static binary with a subcommand interface. **All commands are
ported**, so the binary is a full replacement for the bash script:

```bash
go build ./cmd/postgres4all
./postgres4all generate         --config config.json    # write build/ (no Docker)
./postgres4all install          --config config.json    # generate + docker compose up
./postgres4all update           --config config.json    # add capabilities to a running install (data-safe)
./postgres4all update --allow-drop --config config.json # also drop removed capabilities
./postgres4all apply-functions                          # apply functions/*.sql + reload PostgREST
```

Each command is a behavioral port of the matching bash path — the update delta engine preserves data,
reuses secrets, and runs the same phased apply; `apply-functions` concatenates `functions/*.sql` and
applies them in one transaction. The bash `setup.sh` is kept as the behavioral reference and produces a
compatible `build/`, so the two coexist (bash can be retired once you've adopted the binary). Internals:
typed config + `Validate()`, `text/template` generation with embedded SQL fragments, `crypto/rand`
secrets, `os/exec` Docker orchestration, and golden-file tests for generation and the delta SQL
(`go test ./...`, byte-checked against the bash output).

## Try each capability

<details>
<summary><b>Show the one-liner that proves each capability works</b></summary>

```sql
-- 📄 Document store — JSONB containment
SELECT name FROM products WHERE attributes @> '{"wireless":true}';

-- 📬 Job queue — concurrency-safe dequeue
SELECT * FROM dequeue_job();

-- 🔍 Search — stemmed full-text ("run" matches "running")
SELECT title FROM articles WHERE tsv @@ websearch_to_tsquery('english','run');

-- 🔍 Search — typo-tolerant (trigram similarity)
SELECT title, similarity(title,'postgrez') AS s
FROM articles WHERE title % 'postgrez' ORDER BY s DESC;

-- 🧠 Vector search + relational filter, in one query
SELECT content FROM documents
WHERE owner_id = 1 ORDER BY embedding <=> '[0.10,0.20,0.30]' LIMIT 3;

-- 🗺️ Spatial nearest-neighbour
SELECT name FROM places
ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-122.41,37.78),4326) LIMIT 5;

-- 📈 Time-series scan over a BRIN-indexed partitioned table
SELECT count(*) FROM events WHERE occurred_at >= '2026-06-01' AND occurred_at < '2026-06-02';

-- 📊 Dashboard rollup, refreshed without blocking readers
REFRESH MATERIALIZED VIEW CONCURRENTLY event_daily;
SELECT * FROM event_daily ORDER BY day;

-- 🔌 GraphQL, in SQL
SELECT graphql.resolve($$ { productsCollection { edges { node { name } } } } $$);
```

</details>

---

## REST API

When `api` is enabled, PostgREST turns the schema into a REST (and GraphQL) API:

```bash
# anonymous read
curl http://localhost:3000/products

# filtered read (PostgREST query syntax)
curl 'http://localhost:3000/products?attributes=cs.{"wireless":true}'
```

The `notes` table is per-user. PostgREST switches to the `authenticated` role when a request carries
a valid JWT signed with `JWT_SECRET`; row-level security then limits every read/write to rows whose
`owner` equals the token's `sub` claim. Mint a test token (any JWT library) with payload
`{"role":"authenticated","sub":"alice"}` and send it as `Authorization: Bearer <token>`.

---

## The honest caveat

> Not a silver bullet. Postgres scales vertically very well; horizontal sharding for extreme scale is
> genuinely complex. Past the point of millions of events/sec or sub-millisecond caching for millions
> of concurrent connections, reach for purpose-built distributed systems. **Below it, one Postgres is
> the cheaper, simpler choice.**

---

## Notes

- **Pinned versions:** Postgres 17 + PostGIS 3.5, pgvector from PGDG, pg_graphql v1.5.11,
  PostgREST v12.2.3. Change `PG_MAJOR` / `POSTGIS_VERSION` / `PG_GRAPHQL_VERSION` in `setup.sh` to
  move versions (keep them mutually compatible).
- **Multi-arch:** the image builds for both amd64 and arm64 (the pg_graphql `.deb` is selected by
  architecture).
- **Security:** demo grants are deliberately permissive (anon can read everything). Tighten them in
  the relevant `init/capabilities/*.sql` fragment and the grants block of `setup.sh` before any real use.
