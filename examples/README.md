# Examples

One runnable example per capability — each one driving the **HTTP API** (PostgREST), and each one
showing its business logic in **both PL/pgSQL and PL/Python**.

The point of the project is that Postgres gives you these capabilities *and* an API for free, so the
examples talk to `http://localhost:3000`, not `psql`. Where a capability is a plain query, that's a
native REST call (`GET /products?attributes=cs.{...}`). Where it needs server-side logic — vector
KNN, GIS distance, a row-locking dequeue — the example defines a small `/rpc` function in **both**
languages and calls each, so you can compare them side by side.

## Setup

1. Enable the capability (plus its deps) **and** PL/Python in `config.json`:

   ```jsonc
   {
     "capabilities": { "vector": true, "api": true },
     "languages": { "plpython": true, "allow_untrusted": true }
   }
   ```

   `api` is required by every example (it's the HTTP layer). `plpython3u` is **untrusted** — it runs
   with the database OS user's privileges — which is why `allow_untrusted` must be set deliberately.
   Languages are installed at build time, so enable them before `install` (changing them later needs
   a fresh build).

2. `./postgres4all install`

3. Run an example:

   ```bash
   bash examples/vector.sh
   ```

## What each example shows

| Example | Capability needed | API surface it demonstrates |
|---|---|---|
| `document_store.sh` | `document_store` + `api` | `GET ?attributes=cs.{…}` (containment) + `/rpc` in both languages |
| `job_queue.sh` | `job_queue` + `api` | `GET /jobs` + `SECURITY DEFINER` dequeue `/rpc` in both languages |
| `search.sh` | `search` + `api` | `GET ?tsv=wfts(…)` (full-text) + typo-tolerant `/rpc` in both languages |
| `vector.sh` | `vector` + `api` | KNN + relational filter `/rpc` in both languages |
| `gis.sh` | `gis` + `api` | nearest-neighbour distance `/rpc` in both languages |
| `timeseries.sh` | `timeseries` + `api` | `GET` time window + windowed-count `/rpc` in both languages |
| `dashboards.sh` | `dashboards` + `timeseries` + `api` | `GET /event_daily` (rollup) + `/rpc` in both languages |
| `api.sh` | `document_store` + `api` | REST endpoints + GraphQL resolved by `/rpc` in both languages |
| `auth.sh` | `auth` + `api` | JWT + row-level security; isolation holds through an `/rpc` in both languages |

All examples need `"languages": { "plpython": true, "allow_untrusted": true }` so the PL/Python
halves can run.

## How the `/rpc` functions get defined

To keep each example self-contained, the scripts define their functions inline (via
`examples/lib.sh`'s `define_sql`) and tell PostgREST to reload. In a real project that SQL would
live in `functions/` and you'd apply it with `./postgres4all apply-functions` — see
`functions/example_submit.sql`.
