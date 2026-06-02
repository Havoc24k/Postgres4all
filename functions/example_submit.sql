-- Example business logic: store a document (document_store) AND enqueue a job (job_queue),
-- atomically, then return the new id. Exposed at: POST /rpc/submit_product
--
-- Requires: document_store + job_queue (the products/jobs tables), AND api enabled for the
-- /rpc endpoint to be reachable. The GRANT below targets PostgREST's anon/authenticated roles,
-- which exist ONLY when api is enabled — so it is guarded with an IF EXISTS check, meaning this
-- file applies cleanly even on a non-api install (the function is created; it just isn't granted).
-- SECURITY DEFINER: this function performs privileged INSERTs, but anon/authenticated have only
-- SELECT on products/jobs. Running as the function owner lets unprivileged callers perform exactly
-- this one controlled write — the whole point of exposing logic as an RPC. search_path is pinned
-- (a SECURITY DEFINER safety requirement); pg_catalog is searched first implicitly.
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
