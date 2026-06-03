-- 🔌 api (hand-written middleware) — the same GraphQL wrapper, in PL/Python. Identical result.
CREATE OR REPLACE FUNCTION graphql_plpython(query text) RETURNS jsonb
LANGUAGE plpython3u AS $fn$
plan = plpy.prepare("SELECT graphql.resolve($1) AS r", ["text"])
return plpy.execute(plan, [query])[0]["r"]
$fn$;
