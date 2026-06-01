-- vector: Pinecone -> pgvector + HNSW
CREATE TABLE documents (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id  bigint  NOT NULL DEFAULT 1,
    content   text    NOT NULL,
    embedding vector(3) NOT NULL
);
CREATE INDEX documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops);
