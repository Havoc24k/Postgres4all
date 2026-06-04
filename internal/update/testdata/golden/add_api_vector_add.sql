CREATE EXTENSION IF NOT EXISTS pg_graphql;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT USAGE ON SCHEMA public TO api_owner;
GRANT SELECT ON products TO anon, authenticated;
GRANT USAGE ON SCHEMA graphql TO anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql TO anon, authenticated;
CREATE EXTENSION IF NOT EXISTS vector;
-- vector: Pinecone -> pgvector + HNSW
CREATE TABLE documents (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id  bigint  NOT NULL DEFAULT 1,
    content   text    NOT NULL,
    embedding vector(3) NOT NULL
);
CREATE INDEX documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops);

INSERT INTO documents (owner_id, content, embedding) VALUES
    (1, 'cat', '[0.10,0.20,0.30]'),
    (1, 'dog', '[0.12,0.19,0.31]'),
    (2, 'car', '[0.90,0.10,0.00]');

GRANT SELECT ON documents TO anon, authenticated;
INSERT INTO p4a_meta.capabilities (cap) VALUES ('vector') ON CONFLICT (cap) DO NOTHING;
INSERT INTO p4a_meta.capabilities (cap) VALUES ('api') ON CONFLICT (cap) DO NOTHING;
