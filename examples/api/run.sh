#!/usr/bin/env bash
# 🔌 api (replaces hand-written Node/Python middleware) — see README.md for the walkthrough.
# Run: bash examples/api/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== REST for free: every table is an endpoint (anonymous GET) =="
curl -s "$BASE/products?select=id,name&limit=3"; echo

GQL='{"query":"{ productsCollection { edges { node { name } } } }"}'
echo "== same GraphQL query resolved by a /rpc function — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/graphql_plpgsql" -H 'Content-Type: application/json' -d "$GQL"; echo
echo "== …and PL/Python (identical) =="
curl -s -X POST "$BASE/rpc/graphql_plpython" -H 'Content-Type: application/json' -d "$GQL"; echo
