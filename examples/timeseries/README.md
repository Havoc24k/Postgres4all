# 📈 Time series (replaces a time-series DB)

Postgres stores append-only event data and serves time-windowed reads over HTTP. A BRIN index on `occurred_at` keeps range scans tiny without a dedicated time-series engine, and the whole `events` table is queryable through the REST API — filter by time, select columns, and order, all in the URL.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "timeseries": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/timeseries/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## Read a 5-minute window

PostgREST turns the URL into a range query — `gte`/`lt` bound `occurred_at`, `select` picks columns, and `order` sorts; the BRIN index makes this a tiny scan.

```bash
curl -s "http://localhost:3000/events?occurred_at=gte.2026-06-01&occurred_at=lt.2026-06-01T00:05:00&select=occurred_at,kind&order=occurred_at"; echo
```

```json
[{"occurred_at":"2026-06-01T00:01:00+00:00","kind":"click"}, 
 {"occurred_at":"2026-06-01T00:02:00+00:00","kind":"click"}, 
 {"occurred_at":"2026-06-01T00:03:00+00:00","kind":"click"}, 
 {"occurred_at":"2026-06-01T00:04:00+00:00","kind":"click"}]
```

## Count events for a day — PL/pgSQL

Aggregating across a window needs a function so the caller passes only the bounds and gets a single number back; this one runs the count in PL/pgSQL via `/rpc`.

```bash
curl -s -X POST "http://localhost:3000/rpc/count_events_plpgsql" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}'; echo
```

```json
1000
```

## Count events for a day — PL/Python

The same windowed count, implemented in PL/Python, returns an identical result through `/rpc`.

```bash
curl -s -X POST "http://localhost:3000/rpc/count_events_plpython" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}'; echo
```

```json
1000
```

## The two implementations

[count_events.plpgsql.sql](count_events.plpgsql.sql) and [count_events.plpython.sql](count_events.plpython.sql) implement the same windowed count and return identically. In a real project they'd live in `functions/` and be applied with `./postgres4all apply-functions`.
