# 📈 Time series (replaces a time-series DB)

Postgres stores append-only event data and serves time-windowed reads over HTTP. A BRIN index on
`occurred_at` keeps range scans tiny without a dedicated time-series engine, and the whole `events`
table is queryable through the REST API — filter by time, select columns, and order, all in the URL.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
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
./postgres4all apply-functions examples/timeseries
```

That loads [count_events.plpgsql.sql](count_events.plpgsql.sql) and
[count_events.plpython.sql](count_events.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**Native REST — a 5-minute window** (the BRIN index makes this a tiny range scan, not a full table
scan):

```bash
curl -s "http://localhost:3000/events?occurred_at=gte.2026-06-01&occurred_at=lt.2026-06-01T00:05:00&select=occurred_at,kind&order=occurred_at" | jq
```

```json
[
  {
    "occurred_at": "2026-06-01T00:01:00+00:00",
    "kind": "click"
  },
  {
    "occurred_at": "2026-06-01T00:02:00+00:00",
    "kind": "click"
  },
  {
    "occurred_at": "2026-06-01T00:03:00+00:00",
    "kind": "click"
  },
  {
    "occurred_at": "2026-06-01T00:04:00+00:00",
    "kind": "click"
  }
]
```

**Windowed count for a day — PL/pgSQL** (a single aggregate returned as a scalar):

```bash
curl -s -X POST "http://localhost:3000/rpc/count_events_plpgsql" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}' | jq
```

```json
1000
```

The PL/Python variant (`/rpc/count_events_plpython`) returns the identical count.
