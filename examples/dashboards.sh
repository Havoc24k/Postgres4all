#!/usr/bin/env bash
# 📊 dashboards (replaces Snowflake / a warehouse) — a materialized rollup, over the API.
# Enable: { "dashboards": true, "timeseries": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/dashboards.sh
source "$(dirname "$0")/lib.sh"

echo "# Native REST: the pre-aggregated daily rollup is just a (materialized) view — read it directly:"
curl -s "$BASE/event_daily?select=day,kind,n&order=day.asc"; echo

# The same rollup as business logic — in BOTH languages — handy when you want to shape/relabel it.
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION daily_rollup_plpgsql()
RETURNS TABLE(day date, kind text, events bigint) LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY SELECT e.day::date, e.kind, e.n FROM event_daily e ORDER BY e.day, e.kind;
END;
$fn$;

CREATE OR REPLACE FUNCTION daily_rollup_plpython()
RETURNS TABLE(day date, kind text, events bigint) LANGUAGE plpython3u AS $fn$
return plpy.execute("SELECT day::date, kind, n AS events FROM event_daily ORDER BY day, kind")
$fn$;
SQL

echo
echo "# Daily rollup via /rpc — PL/pgSQL (2026-06-01, click, 1000):"
curl -s -X POST "$BASE/rpc/daily_rollup_plpgsql" -H 'Content-Type: application/json'; echo
echo "# …and PL/Python (identical):"
curl -s -X POST "$BASE/rpc/daily_rollup_plpython" -H 'Content-Type: application/json'; echo
