-- 📬 job queue (Redis/RabbitMQ) — the same atomic dequeue, in PL/Python. Identical behaviour.
CREATE OR REPLACE FUNCTION claim_job_plpython()
RETURNS SETOF jobs LANGUAGE plpython3u SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
return list(plpy.execute("""
    UPDATE jobs SET status = 'processing', locked_at = now()
     WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
                 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING *"""))
$fn$;
