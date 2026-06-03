#!/usr/bin/env bash
# 📬 job queue (replaces Redis/RabbitMQ) — see README.md for the walkthrough.
# Run: bash examples/job_queue/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
apply_sql_dir "$HERE"

echo "== native REST: the queue (seeded with 10 pending jobs) =="
curl -s "$BASE/jobs?select=id,status&order=id&limit=5"; echo

echo "== claim the next job atomically via /rpc — PL/pgSQL =="
curl -s -X POST "$BASE/rpc/claim_job_plpgsql" -H 'Content-Type: application/json'; echo
echo "== claim another — PL/Python (a different row; the lock skips the first) =="
curl -s -X POST "$BASE/rpc/claim_job_plpython" -H 'Content-Type: application/json'; echo

echo "== two jobs are now 'processing', the rest still 'pending' =="
curl -s "$BASE/jobs?select=id,status&order=id"; echo
