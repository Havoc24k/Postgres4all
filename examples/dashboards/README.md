# 📊 Dashboards (replaces Snowflake / a warehouse)

Pre-aggregate raw events into a materialized rollup once, then serve the small, dashboard-ready result over HTTP — no per-request scan of the raw table, and no separate warehouse to feed. The `event_daily` matview is exposed directly as a REST endpoint, and the same rollup is also reachable as a callable function via `/rpc`.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "dashboards": true, "timeseries": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/dashboards/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## Native REST: the pre-aggregated daily rollup (a materialized view)

PostgREST exposes the `event_daily` materialized view as a table, so the dashboard reads the rolled-up rows directly with `select` and `order` — no aggregation at request time.

```bash
curl -s "http://localhost:3000/event_daily?select=day,kind,n&order=day.asc"; echo
```

```json
[{"day":"2026-06-01T00:00:00+00:00","kind":"click","n":1000}]
```

## Same rollup via /rpc — PL/pgSQL

A function lets you reshape and relabel the rollup (here `n` becomes `events`); calling it over `/rpc` returns the function's table result as JSON.

```bash
curl -s -X POST "http://localhost:3000/rpc/daily_rollup_plpgsql" -H 'Content-Type: application/json'; echo
```

```json
[{"day":"2026-06-01","kind":"click","events":1000}]
```

## Same via /rpc — PL/Python (identical)

The PL/Python implementation runs the same query through `plpy.execute` and returns the same shape — the language is an implementation detail behind the API.

```bash
curl -s -X POST "http://localhost:3000/rpc/daily_rollup_plpython" -H 'Content-Type: application/json'; echo
```

```json
[{"day":"2026-06-01","kind":"click","events":1000}]
```

## The two implementations

[daily_rollup.plpgsql.sql](daily_rollup.plpgsql.sql) and [daily_rollup.plpython.sql](daily_rollup.plpython.sql) return identically. In a real project they'd live in `functions/` and be applied with `./postgres4all apply-functions`.
