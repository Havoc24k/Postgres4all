# Examples

One runnable example per capability — each one driving the **HTTP API** (PostgREST), and each one
showing its business logic in **both PL/pgSQL and PL/Python**.

The point of the project is that Postgres gives you these capabilities *and* an API for free, so the
examples talk to `http://localhost:3000`, not `psql`. Where a capability is a plain query, that's a
native REST call (`GET /products?attributes=cs.{...}`). Where it needs server-side logic — vector
KNN, GIS distance, a row-locking dequeue — the example defines a small `/rpc` function in **both**
languages so you can compare them side by side.

## Layout

Each example is a self-contained folder you can read top-to-bottom:

```
examples/<capability>/
  README.md              a runbook: prerequisites, each call, and its real output
  run.sh                 runs the whole example end-to-end
  <name>.plpgsql.sql     the /rpc function — PL/pgSQL
  <name>.plpython.sql    the same /rpc function — PL/Python  (a literal diff away)
```

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

3. Run an example (or read its README and follow along by hand):

   ```bash
   bash examples/vector/run.sh
   ```

## What each example shows

| Example | Capability needed | API surface it demonstrates |
|---|---|---|
| [`document_store/`](document_store/README.md) | `document_store` + `api` | `GET ?attributes=cs.{…}` (containment) + `/rpc` in both languages |
| [`job_queue/`](job_queue/README.md) | `job_queue` + `api` | `GET /jobs` + `SECURITY DEFINER` dequeue `/rpc` in both languages |
| [`search/`](search/README.md) | `search` + `api` | `GET ?tsv=wfts(…)` (full-text) + typo-tolerant `/rpc` in both languages |
| [`vector/`](vector/README.md) | `vector` + `api` | KNN + relational filter `/rpc` in both languages |
| [`gis/`](gis/README.md) | `gis` + `api` | nearest-neighbour distance `/rpc` in both languages |
| [`timeseries/`](timeseries/README.md) | `timeseries` + `api` | `GET` time window + windowed-count `/rpc` in both languages |
| [`dashboards/`](dashboards/README.md) | `dashboards` + `timeseries` + `api` | `GET /event_daily` (rollup) + `/rpc` in both languages |
| [`api/`](api/README.md) | `document_store` + `api` | REST endpoints + GraphQL resolved by `/rpc` in both languages |
| [`auth/`](auth/README.md) | `auth` + `api` | JWT + row-level security; isolation holds through an `/rpc` in both languages |

All examples need `"languages": { "plpython": true, "allow_untrusted": true }` so the PL/Python
halves can run.

## How the `/rpc` functions get defined

Each example keeps its function pair as two files — `<name>.plpgsql.sql` and `<name>.plpython.sql` —
and `run.sh` loads both with the `apply_sql_dir` helper in [`lib.sh`](lib.sh), then tells PostgREST
to reload. In a real project that SQL would live in `functions/` and you'd apply it with
`./postgres4all apply-functions` — see [`functions/example_submit.sql`](../functions/example_submit.sql).
