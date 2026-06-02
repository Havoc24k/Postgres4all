#!/usr/bin/env bash
# 🔌 api (replaces hand-written Node/Python middleware) — PostgREST REST + pg_graphql GraphQL.
# Enable: { "document_store": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/api.sh
source "$(dirname "$0")/lib.sh"

echo "# REST for free: every table is an endpoint (anonymous GET):"
curl -s "$BASE/products?select=id,name&limit=3"; echo

# GraphQL: pg_graphql resolves a query in SQL. Expose it over HTTP with a one-line wrapper —
# and since /rpc functions can be written in any language, here it is in BOTH:
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION graphql_plpgsql(query text) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
BEGIN RETURN graphql.resolve(query); END;
$fn$;

CREATE OR REPLACE FUNCTION graphql_plpython(query text) RETURNS jsonb
LANGUAGE plpython3u AS $fn$
plan = plpy.prepare("SELECT graphql.resolve($1) AS r", ["text"])
return plpy.execute(plan, [query])[0]["r"]
$fn$;
SQL

GQL='{"query":"{ productsCollection { edges { node { name } } } }"}'
echo
echo "# Same GraphQL query, resolved by a PL/pgSQL /rpc function:"
curl -s -X POST "$BASE/rpc/graphql_plpgsql" -H 'Content-Type: application/json' -d "$GQL"; echo
echo "# …and by a PL/Python one (identical):"
curl -s -X POST "$BASE/rpc/graphql_plpython" -H 'Content-Type: application/json' -d "$GQL"; echo

echo
echo "# Your own business logic is POST /rpc/<name> too — see functions/example_submit.sql and the"
echo "# other examples in this folder (each one a PL/pgSQL + PL/Python pair)."
