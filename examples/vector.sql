-- 🧠 vector  (replaces Pinecone)  — pgvector + HNSW, hybrid search in ONE query
-- Enable: "capabilities": { "vector": true }
-- Run:    psql "$DB_URL" -f examples/vector.sql

-- Nearest neighbours to a query embedding, with a relational filter (owner_id) in the
-- same statement — the thing a standalone vector DB can't do. <=> is cosine distance,
-- matching the HNSW index's vector_cosine_ops opclass.
SELECT content,
       round((embedding <=> '[0.10,0.20,0.30]')::numeric, 4) AS distance
FROM documents
WHERE owner_id = 1
ORDER BY embedding <=> '[0.10,0.20,0.30]'
LIMIT 3;
