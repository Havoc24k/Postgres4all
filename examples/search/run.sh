#!/usr/bin/env bash
# 🔍 search (replaces Elasticsearch) — see README.md for the walkthrough.
# Run: bash examples/search/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== native REST full-text: wfts = websearch_to_tsquery ('run' matches 'running') =="
curl -s "$BASE/articles?tsv=wfts(english).run&select=title"; echo

echo "== typo-tolerant search for 'postgrez' via /rpc — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/fuzzy_search_plpgsql" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}'; echo
echo "== same via /rpc — PL/Python (identical ranking) =="
curl -s -X POST "$BASE/rpc/fuzzy_search_plpython" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}'; echo
