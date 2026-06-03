#!/usr/bin/env bash
# 📊 dashboards (replaces Snowflake / a warehouse) — see README.md for the walkthrough.
# Run: bash examples/dashboards/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== native REST: the pre-aggregated daily rollup (a materialized view) =="
curl -s "$BASE/event_daily?select=day,kind,n&order=day.asc"; echo

echo "== same rollup via /rpc — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/daily_rollup_plpgsql" -H 'Content-Type: application/json'; echo
echo "== same via /rpc — PL/Python (identical) =="
curl -s -X POST "$BASE/rpc/daily_rollup_plpython" -H 'Content-Type: application/json'; echo
