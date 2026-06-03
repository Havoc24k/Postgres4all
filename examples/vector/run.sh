#!/usr/bin/env bash
# 🧠 vector search (replaces Pinecone) — see README.md for the walkthrough.
# Run: bash examples/vector/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== nearest neighbours to [0.10,0.20,0.30], owner 1 only — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/match_documents_plpgsql" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}'; echo
echo "== same via /rpc — PL/Python (identical) =="
curl -s -X POST "$BASE/rpc/match_documents_plpython" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}'; echo
