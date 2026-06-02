#!/usr/bin/env bash
# 📈 timeseries (replaces a time-series DB) — declarative partitioning + BRIN, over the API.
# Enable: { "timeseries": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/timeseries.sh
source "$(dirname "$0")/lib.sh"

echo "# Native REST: read a 5-minute window. BRIN makes this a tiny scan, not a full table scan:"
curl -s "$BASE/events?occurred_at=gte.2026-06-01&occurred_at=lt.2026-06-01T00:05:00&select=occurred_at,kind&order=occurred_at"; echo

# A windowed aggregate as business logic — in BOTH languages — returning a single count.
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION count_events_plpgsql(from_ts timestamptz, to_ts timestamptz)
RETURNS bigint LANGUAGE plpgsql STABLE AS $fn$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM events WHERE occurred_at >= from_ts AND occurred_at < to_ts;
    RETURN n;
END;
$fn$;

CREATE OR REPLACE FUNCTION count_events_plpython(from_ts timestamptz, to_ts timestamptz)
RETURNS bigint LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT count(*) AS n FROM events WHERE occurred_at >= $1 AND occurred_at < $2",
    ["timestamptz", "timestamptz"])
return plpy.execute(plan, [from_ts, to_ts])[0]["n"]
$fn$;
SQL

echo
echo "# Count events on 2026-06-01 — PL/pgSQL (1000):"
curl -s -X POST "$BASE/rpc/count_events_plpgsql" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}'; echo
echo "# …and PL/Python (identical):"
curl -s -X POST "$BASE/rpc/count_events_plpython" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}'; echo
