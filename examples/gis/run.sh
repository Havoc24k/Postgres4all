#!/usr/bin/env bash
# 🗺️ maps (replaces a PostGIS GIS stack) — see README.md for the walkthrough.
# Run: bash examples/gis/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== nearest cafes to (-122.41, 37.78) via /rpc — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/nearby_places_plpgsql" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}'; echo
echo "== same via /rpc — PL/Python (identical) =="
curl -s -X POST "$BASE/rpc/nearby_places_plpython" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}'; echo
