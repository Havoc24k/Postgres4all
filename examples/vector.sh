#!/usr/bin/env bash
# 🧠 vector search (replaces Pinecone) — pgvector KNN + a relational filter, over the API.
# Enable: { "vector": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/vector.sh
source "$(dirname "$0")/lib.sh"

# KNN ranks by ORDER BY embedding <=> $query — a parametrized expression PostgREST's URL grammar
# can't express, so it's an /rpc function (in BOTH languages). The owner filter shows the headline
# trick: semantic similarity AND a relational WHERE in one query. '<=>' = cosine distance.
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION match_documents_plpgsql(query text, k int DEFAULT 3, owner bigint DEFAULT NULL)
RETURNS TABLE(content text, distance real) LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY
    SELECT d.content, round((d.embedding <=> query::vector)::numeric, 4)::real
    FROM documents d
    WHERE owner IS NULL OR d.owner_id = owner
    ORDER BY d.embedding <=> query::vector
    LIMIT k;
END;
$fn$;

CREATE OR REPLACE FUNCTION match_documents_plpython(query text, k int DEFAULT 3, owner bigint DEFAULT NULL)
RETURNS TABLE(content text, distance real) LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT content, round((embedding <=> $1::vector)::numeric, 4)::real AS distance "
    "FROM documents WHERE $3 IS NULL OR owner_id = $3 "
    "ORDER BY embedding <=> $1::vector LIMIT $2", ["text", "int", "bigint"])
return plpy.execute(plan, [query, k, owner])
$fn$;
SQL

echo "# Nearest neighbours to [0.10,0.20,0.30], owner 1 only — PL/pgSQL (cat=0, dog≈0.0018):"
curl -s -X POST "$BASE/rpc/match_documents_plpgsql" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}'; echo
echo "# …and PL/Python (identical):"
curl -s -X POST "$BASE/rpc/match_documents_plpython" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}'; echo
