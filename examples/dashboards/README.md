# 📊 Dashboards (replaces Snowflake / a warehouse)

Pre-aggregate raw events into a materialized rollup once, then serve the small, dashboard-ready
result over HTTP — no per-request scan of the raw table, and no separate warehouse to feed. The
`event_daily` matview is exposed directly as a REST endpoint, and the same rollup is reachable as a
callable function via `/rpc`.

## Prerequisites

Enable this in `config.json` — `dashboards` needs `timeseries` (PL/Python powers the second
implementation):

```jsonc
{
  "capabilities": {
    "dashboards": true,
    "timeseries": true,
    "api": true
  },
  "languages": {
    "plpython": true,
    "allow_untrusted": true
  }
}
```

Build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Load the example's functions

Apply this folder's `/rpc` functions with the CLI and it reloads
PostgREST's schema cache (give it a second before calling):

```bash
./postgres4all apply-functions examples/dashboards
```

That loads [daily_rollup.plpgsql.sql](daily_rollup.plpgsql.sql) and
[daily_rollup.plpython.sql](daily_rollup.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**Native REST — the pre-aggregated rollup** (a materialized view read directly, no raw scan):

```bash
curl -s "http://localhost:3000/event_daily?select=day,kind,n&order=day.asc" | jq
```

```json
[
  {
    "day": "2026-06-01T00:00:00+00:00",
    "kind": "click",
    "n": 1000
  }
]
```

**Same rollup via an `/rpc` function — PL/pgSQL** (handy when you want to shape or relabel it — here
`n` is returned as `events`):

```bash
curl -s -X POST "http://localhost:3000/rpc/daily_rollup_plpgsql" -H 'Content-Type: application/json' | jq
```

```json
[
  {
    "day": "2026-06-01",
    "kind": "click",
    "events": 1000
  }
]
```

The PL/Python variant (`/rpc/daily_rollup_plpython`) returns the identical result.
