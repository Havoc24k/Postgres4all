-- Every extension the video leans on. The core capabilities it mentions
-- (JSONB, FOR UPDATE SKIP LOCKED, full-text search, BRIN, declarative
-- partitioning, materialized views, row-level security) are built into
-- PostgreSQL itself and need no extension.

CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- fuzzy / typo-tolerant search (trigrams)
CREATE EXTENSION IF NOT EXISTS btree_gin;    -- combine scalar columns inside GIN indexes
CREATE EXTENSION IF NOT EXISTS vector;       -- pgvector: embeddings + HNSW index
CREATE EXTENSION IF NOT EXISTS postgis;      -- spatial types + GiST index
CREATE EXTENSION IF NOT EXISTS pg_graphql;   -- auto-generated GraphQL API

-- Quick visibility check in the container logs.
SELECT extname, extversion FROM pg_extension ORDER BY extname;
