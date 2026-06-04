-- Example business logic: store a document (document_store) AND enqueue a job (job_queue),
-- atomically, then return the new id. Exposed at: POST /rpc/submit_product
--
-- Requires: document_store + job_queue (the products/jobs tables), AND api enabled for the
-- /rpc endpoint to be reachable. The GRANT below targets PostgREST's anon/authenticated roles,
-- which exist ONLY when api is enabled — so it is guarded with an IF EXISTS check, meaning this
-- file applies cleanly even on a non-api install (the function is created; it just isn't granted).
-- SECURITY DEFINER: this function performs privileged INSERTs, but anon/authenticated have only
-- SELECT on products/jobs. The trailing DO-block reassigns ownership to api_owner — a powerless
-- role granted ONLY INSERT on products/jobs — so an unprivileged caller runs exactly this one
-- controlled write as that scoped role, NOT as the superuser. search_path is pinned (a SECURITY
-- DEFINER safety requirement); pg_catalog is searched first implicitly.
CREATE OR REPLACE FUNCTION submit_product(name text, attributes jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    new_id bigint;
BEGIN
    INSERT INTO products (name, attributes)
    VALUES (submit_product.name, submit_product.attributes)
    RETURNING id INTO new_id;

    INSERT INTO jobs (payload)
    VALUES (jsonb_build_object('task', 'index_product', 'product_id', new_id));

    RETURN jsonb_build_object('product_id', new_id, 'queued', true);
END;
$$;

-- Grant to the PostgREST roles only if they exist (i.e. api is enabled), so a single-transaction
-- apply on a non-api install does not roll back on "role does not exist".
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION submit_product(text, jsonb) TO anon, authenticated;
    END IF;
END $$;

-- Run the privileged INSERTs as a scoped, NON-superuser role rather than the superuser that
-- applied this file. api_owner exists only when `api` is enabled; the table grant is applied
-- only when the target tables exist (document_store + job_queue) so this file still applies
-- cleanly on any install.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_owner') THEN
        ALTER FUNCTION submit_product(text, jsonb) OWNER TO api_owner;
        IF to_regclass('public.products') IS NOT NULL
           AND to_regclass('public.jobs') IS NOT NULL THEN
            GRANT INSERT ON products, jobs TO api_owner;
        END IF;
    END IF;
END $$;
