#!/usr/bin/env bash
# 📄 document store (replaces MongoDB) — JSONB documents, queried over the API.
# Enable: { "document_store": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/document_store.sh
source "$(dirname "$0")/lib.sh"

echo "# Native REST: every row is a JSON document. Filter by containment — PostgREST 'cs' = @>"
echo "#   (-g stops curl from globbing the {} in the query string):"
curl -sg "$BASE/products?attributes=cs.{\"wireless\":true}&select=name,attributes"; echo

# The same containment query as reusable business logic, exposed at POST /rpc/<name>.
# Defined here in BOTH languages; in a real project these would live in functions/.
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION products_matching_plpgsql(filter jsonb)
RETURNS SETOF products LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY SELECT * FROM products WHERE attributes @> filter;
END;
$fn$;

CREATE OR REPLACE FUNCTION products_matching_plpython(filter jsonb)
RETURNS SETOF products LANGUAGE plpython3u AS $fn$
plan = plpy.prepare("SELECT * FROM products WHERE attributes @> $1", ["jsonb"])
return plpy.execute(plan, [filter])
$fn$;
SQL

echo
echo "# Same query as an /rpc function — PL/pgSQL:"
curl -s -X POST "$BASE/rpc/products_matching_plpgsql" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}'; echo
echo "# …and PL/Python (identical result):"
curl -s -X POST "$BASE/rpc/products_matching_plpython" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}'; echo
