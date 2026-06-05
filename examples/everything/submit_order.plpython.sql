-- 🛒 the everything-tour's one new piece of server-side logic — submit_order, in PL/Python.
-- Exposed at: POST /rpc/submit_order_plpython
--
-- A literal translation of submit_order.plpgsql.sql: the same atomic 3-table write (orders + jobs +
-- events) as api_owner, the same NULL-buyer guard, the same response shape. plpython3u is UNTRUSTED,
-- which is why the example requires "allow_untrusted": true.
--
-- search_path is pinned (SECURITY DEFINER requirement). plpy.prepare/execute parameterise every write.
CREATE OR REPLACE FUNCTION submit_order_plpython(product_id bigint, qty int DEFAULT 1)
RETURNS jsonb
LANGUAGE plpython3u
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
import json

# buyer = the JWT sub (None for an anon/unauthenticated call).
claims = plpy.execute("SELECT current_setting('request.jwt.claims', true) AS c")[0]["c"]
buyer = json.loads(claims).get("sub") if claims else None

# (a) Backstop for a token with no `sub` (a token-less call never reaches here — anon has no EXECUTE,
#     so PostgREST already answered 403). sqlstate 28000 -> PostgREST 403, matching PL/pgSQL.
if buyer is None:
    plpy.error("must be authenticated to place an order", sqlstate="28000")

# (b) The order itself; owner = buyer, so RLS later scopes reads to this user.
ins_order = plpy.prepare(
    "INSERT INTO orders (owner, product_id, qty) VALUES ($1, $2, $3) RETURNING id",
    ["text", "bigint", "int"],
)
new_id = plpy.execute(ins_order, [buyer, product_id, qty])[0]["id"]

# (c) Enqueue the confirmation-email job (job_queue).
ins_job = plpy.prepare("INSERT INTO jobs (payload) VALUES ($1)", ["jsonb"])
plpy.execute(ins_job, [json.dumps({"task": "send_order_email", "order_id": new_id, "user": buyer})])

# (d) Record the purchase on the event stream (timeseries); occurred_at has no default.
ins_event = plpy.prepare("INSERT INTO events (occurred_at, kind, data) VALUES (now(), 'purchase', $1)", ["jsonb"])
plpy.execute(ins_event, [json.dumps(
    {"order_id": new_id, "product_id": product_id, "qty": qty, "user": buyer}
)])

# (e) Shape the API response (json.dumps -> valid jsonb; a bare dict would str() to invalid JSON).
return json.dumps({"order_id": new_id, "queued": True})
$fn$;

-- Only `authenticated` may place orders (token-less calls are 403'd before the body runs).
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT EXECUTE ON FUNCTION submit_order_plpython(bigint, int) TO authenticated;
    END IF;
END $$;
