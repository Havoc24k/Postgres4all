-- 📬 job queue (Redis/RabbitMQ) — atomic dequeue under a row lock, in PL/pgSQL.
-- SECURITY DEFINER lets an unprivileged API caller run exactly this one controlled write;
-- FOR UPDATE SKIP LOCKED makes concurrent claims contention-free.
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

-- Run the dequeue UPDATE as a scoped, non-superuser role. api_owner exists only when `api` is
-- enabled; the grant is applied only when jobs exists (job_queue enabled).
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_owner') THEN
        ALTER FUNCTION claim_job_plpgsql() OWNER TO api_owner;
        IF to_regclass('public.jobs') IS NOT NULL THEN
            GRANT SELECT, UPDATE ON jobs TO api_owner;
        END IF;
    END IF;
END $$;
