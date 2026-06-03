-- 🧠 vector search (Pinecone) — KNN + relational filter, in PL/pgSQL. '<=>' = cosine distance.
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
