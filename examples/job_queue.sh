#!/usr/bin/env bash
# 📬 job queue (replaces Redis/RabbitMQ) — FOR UPDATE SKIP LOCKED, claimed over the API.
# Enable: { "job_queue": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/job_queue.sh
source "$(dirname "$0")/lib.sh"

echo "# The queue, read over native REST (seeded with 10 pending jobs):"
curl -s "$BASE/jobs?select=id,status&order=id&limit=5"; echo

# Dequeue is a WRITE under a row lock, so it must be an /rpc function (anon may only read jobs).
# SECURITY DEFINER lets an unprivileged API caller run exactly this one controlled write.
# Defined in BOTH languages; FOR UPDATE SKIP LOCKED makes concurrent claims contention-free.
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION claim_job_plpgsql()
RETURNS SETOF jobs LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
BEGIN
    RETURN QUERY
    UPDATE jobs SET status = 'processing', locked_at = now()
     WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
                 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING *;
END;
$fn$;

CREATE OR REPLACE FUNCTION claim_job_plpython()
RETURNS SETOF jobs LANGUAGE plpython3u SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
return plpy.execute("""
    UPDATE jobs SET status = 'processing', locked_at = now()
     WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
                 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING *""")
$fn$;
SQL

echo
echo "# Claim the next job atomically — PL/pgSQL:"
curl -s -X POST "$BASE/rpc/claim_job_plpgsql" -H 'Content-Type: application/json'; echo
echo "# Claim another — PL/Python (gets a different row; the lock skips the one above):"
curl -s -X POST "$BASE/rpc/claim_job_plpython" -H 'Content-Type: application/json'; echo

echo
echo "# Two jobs are now 'processing', the rest still 'pending':"
curl -s "$BASE/jobs?select=id,status&order=id"; echo
