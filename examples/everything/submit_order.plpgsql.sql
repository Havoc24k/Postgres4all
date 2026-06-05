-- 🛒 the everything-tour's one new piece of server-side logic — submit_order, in PL/pgSQL.
-- Exposed at: POST /rpc/submit_order_plpgsql
--
-- This is the step-7 climax of the tour: a single privileged, atomic write across THREE tables that
-- an unprivileged caller could never make directly:
--   1. INSERT the order into `orders`  (api_owner owns it; authenticated has no INSERT grant)
--   2. enqueue a confirmation-email job in `jobs`  (job_queue)
--   3. write a 'purchase' event to `events`  (timeseries)
-- It runs as api_owner (SECURITY DEFINER), which holds exactly those DML rights and nothing more —
-- crucially NO grant on `notes`, so it cannot read or write any user's wishlist.
--
-- search_path is pinned (a SECURITY DEFINER safety requirement); pg_catalog is searched first.
CREATE OR REPLACE FUNCTION submit_order_plpgsql(product_id bigint, qty int DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    buyer   text := current_setting('request.jwt.claims', true)::json ->> 'sub';
    new_id  bigint;
BEGIN
    -- (a) Backstop for a token that switched into `authenticated` but carries no `sub`: an order with
    --     no owner would be invisible under RLS anyway. (A token-LESS call never reaches here — anon
    --     has no EXECUTE on this function, so PostgREST already answered 403; see the GRANT below.)
    IF buyer IS NULL THEN
        RAISE EXCEPTION 'must be authenticated to place an order'
            USING errcode = '28000';   -- invalid_authorization_specification (PostgREST -> 403)
    END IF;

    -- (b) The order itself. owner = the JWT sub, so RLS later scopes reads to this buyer.
    INSERT INTO orders (owner, product_id, qty)
    VALUES (buyer, submit_order_plpgsql.product_id, submit_order_plpgsql.qty)
    RETURNING id INTO new_id;

    -- (c) Enqueue the confirmation-email job for a worker to claim (job_queue).
    INSERT INTO jobs (payload)
    VALUES (jsonb_build_object(
        'task', 'send_order_email',
        'order_id', new_id,
        'user', buyer
    ));

    -- (d) Record the purchase on the event stream (timeseries). occurred_at has no default, so set it.
    --     These keys are what the dashboards rollup can later slice by.
    INSERT INTO events (occurred_at, kind, data)
    VALUES (now(), 'purchase', jsonb_build_object(
        'order_id', new_id,
        'product_id', submit_order_plpgsql.product_id,
        'qty', submit_order_plpgsql.qty,
        'user', buyer
    ));

    -- (e) Shape the API response.
    RETURN jsonb_build_object('order_id', new_id, 'queued', true);
END;
$fn$;

-- Only `authenticated` may place orders. A token-less (anon) call therefore has no EXECUTE here, so
-- PostgREST rejects it 403 before the body even runs (verified) — no order path for anonymous users.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT EXECUTE ON FUNCTION submit_order_plpgsql(bigint, int) TO authenticated;
    END IF;
END $$;
