-- 🛒 the everything-tour's own table: orders.
--
-- This file is applied by `apply-functions examples/everything`, which runs the whole batch under
-- `SET ROLE api_owner`. So this table is CREATED and OWNED by api_owner (a non-superuser) — exactly
-- the role that submit_order runs as (SECURITY DEFINER). That ownership is why the definer function
-- can INSERT here without any extra grant.
--
-- The filename sorts first (00_) so the table exists before submit_order's grants reference it.
--
-- Security shape (the lesson of this example):
--   * RLS scopes reads to the calling user (owner = JWT sub), just like notes.
--   * authenticated is granted SELECT only — NOT INSERT. The single way to create an order is the
--     submit_order /rpc, which validates and writes as api_owner. No client can INSERT directly.
--   * api_owner OWNS this table, so its definer INSERTs bypass RLS (table owners are exempt) — but
--     api_owner has no grant on `notes`, so the same function still cannot touch anyone's wishlist.

CREATE TABLE IF NOT EXISTS orders (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner      text        NOT NULL,
    product_id bigint      NOT NULL,
    qty        int         NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Role-agnostic policy: anyone reading sees only their own orders. anon has no SELECT grant so never
-- reaches it; api_owner owns the table so is exempt; authenticated is scoped to its JWT sub.
DROP POLICY IF EXISTS orders_isolation ON orders;
CREATE POLICY orders_isolation ON orders
    USING (owner = current_setting('request.jwt.claims', true)::json ->> 'sub');

-- Grant SELECT (only) to the PostgREST roles if they exist — mirrors functions/example_submit.sql so
-- the batch still applies cleanly were auth/api somehow absent. Note: no INSERT/UPDATE/DELETE.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT SELECT ON orders TO authenticated;
    END IF;
END $$;
