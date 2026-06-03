-- 🔌 api (hand-written middleware) — expose pg_graphql over HTTP with a one-line wrapper, in PL/pgSQL.
CREATE OR REPLACE FUNCTION graphql_plpgsql(query text) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
BEGIN RETURN graphql.resolve(query); END;
$fn$;
