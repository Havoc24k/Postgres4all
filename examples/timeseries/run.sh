#!/usr/bin/env bash
# 📈 timeseries (replaces a time-series DB) — see README.md for the walkthrough.
# Run: bash examples/timeseries/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== native REST: read a 5-minute window (BRIN makes this a tiny scan) =="
curl -s "$BASE/events?occurred_at=gte.2026-06-01&occurred_at=lt.2026-06-01T00:05:00&select=occurred_at,kind&order=occurred_at"; echo

echo "== count events on 2026-06-01 via /rpc — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/count_events_plpgsql" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}'; echo
echo "== same via /rpc — PL/Python (identical) =="
curl -s -X POST "$BASE/rpc/count_events_plpython" \
  -H 'Content-Type: application/json' -d '{"from_ts":"2026-06-01","to_ts":"2026-06-02"}'; echo
