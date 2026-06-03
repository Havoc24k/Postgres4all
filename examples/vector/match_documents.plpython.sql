-- 🧠 vector search (Pinecone) — the same KNN + relational filter, in PL/Python. Identical result.
CREATE OR REPLACE FUNCTION match_documents_plpython(query text, k int DEFAULT 3, owner bigint DEFAULT NULL)
RETURNS TABLE(content text, distance real) LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT content, round((embedding <=> $1::vector)::numeric, 4)::real AS distance "
    "FROM documents WHERE $3 IS NULL OR owner_id = $3 "
    "ORDER BY embedding <=> $1::vector LIMIT $2", ["text", "int", "bigint"])
return list(plpy.execute(plan, [query, k, owner]))
$fn$;
