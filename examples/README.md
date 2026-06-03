# Examples

One example per capability — each one driving the **HTTP API** (PostgREST), and each one showing its
business logic in **both PL/pgSQL and PL/Python**.

The point of the project is that Postgres gives you these capabilities *and* an API for free, so the
examples talk to `http://localhost:3000`, not `psql`. Where a capability is a plain query, that's a
native REST call (`GET /products?attributes=cs.{...}`). Where it needs server-side logic — vector
KNN, GIS distance, a row-locking dequeue — the example ships a small `/rpc` function in **both**
languages so you can compare them side by side.

There are no scripts: the `postgres4all` CLI loads each example's functions, and you call the API with
`curl` (piped through `jq` for readable output).

## Layout

Each example is a self-contained folder you can read top-to-bottom:

```
examples/<capability>/
  README.md              a runbook: prerequisites → load functions → call the API, with real output
  <name>.plpgsql.sql     the /rpc function — PL/pgSQL
  <name>.plpython.sql    the same /rpc function — PL/Python  (a literal diff away)
```

## Setup

1. Enable the capability (plus its deps) **and** PL/Python in `config.json`:

   ```jsonc
   {
     "capabilities": {
       "vector": true,
       "api": true
     },
     "languages": {
       "plpython": true,
       "allow_untrusted": true
     }
   }
   ```

   `api` is required by every example (it's the HTTP layer). `plpython3u` is **untrusted** — it runs
   with the database OS user's privileges — which is why `allow_untrusted` must be set deliberately.
   Languages are installed at build time, so enable them before `install` (changing them later needs
   a fresh build).

2. `./postgres4all install`

3. Load an example's functions with the CLI, then follow its README:

   ```bash
   ./postgres4all apply-functions examples/vector
   ```

You'll also want `curl` and `jq` on your PATH to call the API and pretty-print the responses.

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

## How the `/rpc` functions get loaded

Each example keeps its function pair as two files — `<name>.plpgsql.sql` and `<name>.plpython.sql`.
`./postgres4all apply-functions examples/<capability>` applies both in one transaction and reloads
PostgREST's schema cache. This is the same command a real project uses — there, the SQL lives in
`functions/` and `./postgres4all apply-functions` (no argument) applies it from there. See
[`functions/example_submit.sql`](../functions/example_submit.sql).
