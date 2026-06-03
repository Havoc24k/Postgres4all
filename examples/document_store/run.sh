#!/usr/bin/env bash
# 📄 document store (replaces MongoDB) — see README.md for the walkthrough.
# Run: bash examples/document_store/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== native REST: filter JSON documents by containment (cs = @>) =="
curl -sg "$BASE/products?attributes=cs.{\"wireless\":true}&select=name,attributes"; echo

echo "== same query via /rpc — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/products_matching_plpgsql" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}'; echo
echo "== same query via /rpc — PL/Python (identical) =="
curl -s -X POST "$BASE/rpc/products_matching_plpython" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}'; echo
