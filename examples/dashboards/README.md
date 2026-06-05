# 📊 Dashboards

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

## Keeping the rollup fresh

`event_daily` is a **materialized** view — a point-in-time snapshot. New events written after the last
refresh don't appear until you refresh it, and *how* you do that is a workload decision this demo
deliberately leaves to you (the matview is the starting point, not a policy):

- **Scheduled `REFRESH`** — a cron job or [`pg_cron`](https://github.com/citusdata/pg_cron) running
  `REFRESH MATERIALIZED VIEW CONCURRENTLY event_daily;` every few minutes. Closest to the warehouse
  model: cheap writes, eventually-consistent reads. (The unique index `event_daily_pk` already exists,
  so `CONCURRENTLY` works — refreshes don't block reads.) `REFRESH` requires ownership, so run it as a
  superuser / the view's owner, not over the API.
- **Trigger-maintained summary table** — if you want an always-current dashboard, replace the matview
  with a real `event_daily` table and an `AFTER INSERT` trigger on `events` that does an incremental
  `INSERT … ON CONFLICT (day, kind) DO UPDATE SET n = n + 1`. O(1) per event, no refresh. Trades a
  little write-path cost for real-time reads.

Pick the one that fits your freshness-vs-write-cost needs.
