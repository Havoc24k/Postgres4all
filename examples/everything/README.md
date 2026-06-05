# 🍽️ Everything — the all-capabilities tour

The other examples each prove **one** capability in isolation. This one is a single user session that
touches **all nine** in order — the pitch of the whole project in one runbook: *you thought you needed
eight services; you needed one Postgres.*

We follow **Alice** through a small marketplace-style app backed entirely by the demo seed data. Every
step is an HTTP call against PostgREST (`http://localhost:3000`) — there is no application server.

| # | Step | Capability | Replaces |
|---|------|-----------|----------|
| 1 | Mint Alice a token | `auth` | an auth service |
| 2 | Find places near her | `gis` | PostGIS stack |
| 3 | Filter products by attributes | `document_store` | MongoDB |
| 4 | Typo-tolerant article search | `search` | Elasticsearch |
| 5 | Find similar documents | `vector` | Pinecone |
| 6 | Save a private wishlist note | `auth` (RLS) | per-user authz code |
| 7 | **Place an order** (`submit_order`) | this example | app-server business logic |
| 8 | A worker processes the email job | `job_queue` | Redis / RabbitMQ |
| 9 | See the purchase on the event stream | `timeseries` | a TSDB |
| 10 | Read the analytics rollup | `dashboards` | Snowflake |
| — | (every step was an HTTP endpoint) | `api` | a hand-written API tier |

## Prerequisites

This is the one example that turns **everything** on. In `config.json`:

```jsonc
{
  "capabilities": {
    "document_store": true,
    "job_queue": true,
    "search": true,
    "vector": true,
    "gis": true,
    "timeseries": true,
    "dashboards": true,
    "api": true,
    "auth": true
  },
  "languages": {
    "plpython": true,
    "allow_untrusted": true
  },
  "seed_demo_data": true
}
```

`plpython3u` is **untrusted** (runs as the database OS user), so `allow_untrusted` must be set
deliberately. Languages are installed at build time — enable them before `install`. Then:

```bash
./postgres4all install
```

You'll also want `curl` and `jq` on your PATH.

## Load the functions

This tour **reuses** the per-capability examples' `/rpc` functions and adds only its own
(`submit_order` + the `orders` table). `apply-functions` is composable — load each folder; the last
one creates the `orders` table and `submit_order` under `SET ROLE api_owner`:

```bash
./postgres4all apply-functions examples/gis
./postgres4all apply-functions examples/search
./postgres4all apply-functions examples/vector
./postgres4all apply-functions examples/job_queue
./postgres4all apply-functions examples/dashboards
./postgres4all apply-functions examples/everything    # orders table + submit_order
```

(Steps 3, 6, 9, 10's reads are native REST and need no function.)

> ℹ️ The PL/pgSQL halves are created under `SET ROLE api_owner`. The PL/Python halves can't be — an
> **untrusted** language (`plpython3u`) can only be `CREATE`d by a superuser — so `apply-functions`
> creates those as the superuser and then transfers ownership to `api_owner`, leaving every function
> owned by the same non-superuser role. Both languages were verified end-to-end (PL/pgSQL **and**
> PL/Python) against this tour.

## The tour

Run everything **from the repo root in one shell session** — the token variable must persist. JSON is
piped through `jq`.

### 1. Mint Alice a token — `auth`

A request authenticates with a short-lived HS256 JWT signed with the install's auto-generated
`JWT_SECRET`. Its `sub` claim is Alice's identity; its `role` claim is the Postgres role PostgREST
switches into.

```bash
ALICE=$(./postgres4all mint-token --sub alice)
```

### 2. Find places near her — `gis` (PostGIS)

The GiST-indexed `<->` operator answers nearest-neighbour; `ST_DistanceSphere` returns metres.

```bash
curl -s -X POST "http://localhost:3000/rpc/nearby_places_plpgsql" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}' | jq
```

```json
[
  { "name": "Cafe B", "metres": 562.7 },
  { "name": "Cafe A", "metres": 1002.1 }
]
```

### 3. Filter products by attributes — `document_store` (MongoDB)

Products carry schemaless JSONB. A native containment filter (`cs.` = "contains") finds wireless
items — no `/rpc` needed, PostgREST exposes it directly:

```bash
curl -s "http://localhost:3000/products?attributes=cs.%7B%22wireless%22:true%7D&select=name,attributes" | jq
```

```json
[
  {
    "name": "Mechanical Keyboard",
    "attributes": { "brand": "Keychron", "tags": ["typing","gaming"], "switch": "brown", "wireless": true }
  }
]
```

(`%7B…%7D` is just the URL-encoded `{"wireless":true}`.)

### 4. Typo-tolerant article search — `search` (Elasticsearch)

Trigram similarity matches despite the misspelling:

```bash
curl -s -X POST "http://localhost:3000/rpc/fuzzy_search_plpgsql" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}' | jq
```

```json
[
  { "title": "Running Postgres in production", "score": 0.778 }
]
```

### 5. Find similar documents — `vector` (Pinecone)

Cosine KNN (`<=>`) over pgvector embeddings, scoped to owner 1:

```bash
curl -s -X POST "http://localhost:3000/rpc/match_documents_plpgsql" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}' | jq
```

```json
[
  { "content": "cat", "distance": 0 },
  { "content": "dog", "distance": 0.0018 }
]
```

### 6. Save a private wishlist note — `auth` + RLS

Alice posts a note (returns `201`); the `owner` column is filled from her JWT `sub` automatically, and
RLS scopes every later read to her. An anonymous read (no token) is rejected — `anon` was never
granted `notes`.

```bash
curl -s -X POST "http://localhost:3000/notes" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"body":"want the Keychron keyboard"}'

curl -s "http://localhost:3000/notes?select=owner,body" -H "Authorization: Bearer $ALICE" | jq
```

```json
[
  { "owner": "alice", "body": "want the Keychron keyboard" }
]
```

### 7. Place an order — `submit_order` (this example)

The climax: one HTTP call drives a single **atomic write across three tables** — `orders`, `jobs`, and
`events` — performed as the non-superuser `api_owner` (SECURITY DEFINER). Alice has no INSERT grant on
any of them; the only door is this validated function.

```bash
curl -s -X POST "http://localhost:3000/rpc/submit_order_plpgsql" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"product_id":1,"qty":2}' | jq
```

```json
{ "order_id": 1, "queued": true }
```

The order persisted, and RLS scopes it to Alice exactly like her notes — a different user's token sees
nothing here:

```bash
curl -s "http://localhost:3000/orders?select=owner,product_id,qty" -H "Authorization: Bearer $ALICE" | jq
```

```json
[
  { "owner": "alice", "product_id": 1, "qty": 2 }
]
```

> Try it without a token — `curl -s -o /dev/null -w '%{http_code}' -X POST
> .../rpc/submit_order_plpgsql -d '{"product_id":1}'` — and PostgREST answers `403`: `anon` has no
> `EXECUTE` on the function, so the call is rejected before the body runs. (A token that switched into
> `authenticated` but somehow carried no `sub` would hit the in-body guard, also `403`.) The PL/Python
> variant (`/rpc/submit_order_plpython`) is identical.

### 8. A worker processes the email job — `job_queue` (Redis/RabbitMQ)

`submit_order` enqueued a `send_order_email` job. Confirm it's pending (a native containment filter on
the JSONB payload):

```bash
curl -s "http://localhost:3000/jobs?payload=cs.%7B%22task%22:%22send_order_email%22%7D&select=status,payload" | jq -c
```

```json
[{"status":"pending","payload":{"task":"send_order_email","user":"alice","order_id":1}}]
```

A worker then claims the **oldest** pending job with `FOR UPDATE SKIP LOCKED` (safe for many concurrent
workers). `claim_job` returns `SETOF jobs`, so PostgREST renders an **array** of the row(s) it locked:

```bash
curl -s -X POST "http://localhost:3000/rpc/claim_job_plpgsql" | jq -c
```

```json
[{"id":1,"payload":{"task":"send_order_email","order_id":1,"user":"alice"},"status":"processing","locked_at":"…"}]
```

(On the demo install the queue is seeded with other pending jobs too; `claim_job` is strict FIFO by
`created_at`, so it works through that backlog before reaching the order's email job.)

### 9. See the purchase on the event stream — `timeseries`

The same call wrote a `purchase` event into the partitioned `events` table. Read it back natively:

```bash
curl -s "http://localhost:3000/events?kind=eq.purchase&select=kind,data&order=occurred_at.desc&limit=5" | jq
```

```json
[
  { "kind": "purchase", "data": { "user": "alice", "order_id": 1, "product_id": 1, "qty": 2 } }
]
```

### 10. Read the analytics rollup — `dashboards` (Snowflake)

`event_daily` is a **materialized** view — a point-in-time snapshot aggregated by day and kind. Read it
natively, or via `daily_rollup` (which relabels the columns):

```bash
curl -s "http://localhost:3000/event_daily?select=day,kind,n&order=day.desc" | jq -c
```

```json
[{"day":"2026-06-05T00:00:00+00:00","kind":"purchase","n":1},{"day":"2026-06-01T00:00:00+00:00","kind":"click","n":1000}]
```

The OLTP write (step 7) and this "warehouse" read are the same Postgres. **But** a matview is a
snapshot — the purchase only shows up after a refresh:

```bash
docker exec build-db-1 psql -U postgres -d app -c 'REFRESH MATERIALIZED VIEW CONCURRENTLY event_daily;'
```

> ℹ️ Refreshing is an **ops decision the demo leaves to you**, not something the API does: a scheduled
> `REFRESH` (cron / `pg_cron`), or swap the matview for a trigger-maintained summary table for an
> always-current dashboard. See [dashboards → Keeping the rollup fresh](../dashboards/README.md#keeping-the-rollup-fresh).

## What just happened

One container, one config, nine capabilities, one user session — and the only code you wrote was a
single `submit_order` function. Everything else was a native PostgREST endpoint or a `/rpc` reused from
a per-capability example.

The security boundary is the subtle win: `submit_order` writes `orders` + `jobs` + `events` as
`api_owner`, yet **cannot** read or write Alice's wishlist `notes` — `api_owner` holds DML on the
app's capability tables and owns `orders`, but was never granted `notes`. So privileged business logic
and per-user privacy coexist without an application tier mediating either.

See [submit_order.plpgsql.sql](submit_order.plpgsql.sql) / [submit_order.plpython.sql](submit_order.plpython.sql)
for the function, and [00_orders.schema.sql](00_orders.schema.sql) for the table + RLS + grants.
