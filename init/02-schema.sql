-- One small, runnable example of every capability from the video.
-- Everything lives in the public schema so PostgREST and pg_graphql expose it
-- with no extra configuration.

------------------------------------------------------------------------------
-- 1) MongoDB  ->  JSONB + GIN index
------------------------------------------------------------------------------
CREATE TABLE products (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text  NOT NULL,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb
);
-- jsonb_path_ops = compact GIN index optimised for the @> containment operator.
CREATE INDEX products_attrs_gin ON products USING gin (attributes jsonb_path_ops);

INSERT INTO products (name, attributes) VALUES
    ('Mechanical Keyboard', '{"brand":"Keychron","switch":"brown","wireless":true,"tags":["typing","gaming"]}'),
    ('USB-C Hub',           '{"brand":"Anker","ports":7,"wireless":false}');
-- Example:  SELECT name FROM products WHERE attributes @> '{"wireless":true}';

------------------------------------------------------------------------------
-- 2) Redis / RabbitMQ queue  ->  FOR UPDATE SKIP LOCKED
------------------------------------------------------------------------------
CREATE TABLE jobs (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload    jsonb       NOT NULL,
    status     text        NOT NULL DEFAULT 'pending',
    locked_at  timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
-- Partial index so the "next pending job" lookup stays tiny.
CREATE INDEX jobs_pending_idx ON jobs (created_at) WHERE status = 'pending';

INSERT INTO jobs (payload)
SELECT jsonb_build_object('n', g) FROM generate_series(1, 10) AS g;

-- A wait-free dequeue: each concurrent worker grabs a different row.
CREATE OR REPLACE FUNCTION dequeue_job()
RETURNS jobs
LANGUAGE sql AS $$
    UPDATE jobs
       SET status = 'processing', locked_at = now()
     WHERE id = (
         SELECT id FROM jobs
          WHERE status = 'pending'
          ORDER BY created_at
          FOR UPDATE SKIP LOCKED
          LIMIT 1
     )
    RETURNING *;
$$;
-- Example:  SELECT * FROM dequeue_job();

------------------------------------------------------------------------------
-- 3) Elasticsearch  ->  full-text search (tsvector) + pg_trgm fuzzy matching
------------------------------------------------------------------------------
CREATE TABLE articles (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL,
    body  text NOT NULL,
    tsv   tsvector GENERATED ALWAYS AS
              (to_tsvector('english', title || ' ' || body)) STORED
);
CREATE INDEX articles_tsv_idx        ON articles USING gin (tsv);
CREATE INDEX articles_title_trgm_idx ON articles USING gin (title gin_trgm_ops);

INSERT INTO articles (title, body) VALUES
    ('Running Postgres in production', 'Tips for scaling and running your database under load.'),
    ('A guide to full text search',    'Using tsvector and tsquery effectively in Postgres.');
-- Stemmed search:  SELECT title FROM articles WHERE tsv @@ websearch_to_tsquery('english','run');
-- Typo-tolerant:   SELECT title FROM articles
--                  WHERE title % 'postgrez' ORDER BY similarity(title,'postgrez') DESC;

------------------------------------------------------------------------------
-- 4) Pinecone / vector DB  ->  pgvector + HNSW (hybrid search in one query)
------------------------------------------------------------------------------
CREATE TABLE documents (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id  bigint  NOT NULL DEFAULT 1,
    content   text    NOT NULL,
    embedding vector(3) NOT NULL          -- 3 dims to keep the demo readable
);
CREATE INDEX documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops);

INSERT INTO documents (owner_id, content, embedding) VALUES
    (1, 'cat', '[0.10,0.20,0.30]'),
    (1, 'dog', '[0.12,0.19,0.31]'),
    (2, 'car', '[0.90,0.10,0.00]');
-- Hybrid search (semantic + relational filter in a single query):
--   SELECT content FROM documents
--   WHERE owner_id = 1
--   ORDER BY embedding <=> '[0.10,0.20,0.30]'
--   LIMIT 3;

------------------------------------------------------------------------------
-- 5) GIS systems  ->  PostGIS + GiST index
------------------------------------------------------------------------------
CREATE TABLE places (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    geom geometry(Point, 4326) NOT NULL
);
CREATE INDEX places_geom_gist ON places USING gist (geom);

INSERT INTO places (name, geom) VALUES
    ('Cafe A', ST_SetSRID(ST_MakePoint(-122.4194, 37.7749), 4326)),
    ('Cafe B', ST_SetSRID(ST_MakePoint(-122.4084, 37.7849), 4326));
-- Nearest neighbour:  SELECT name FROM places
--   ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-122.41, 37.78), 4326) LIMIT 5;

------------------------------------------------------------------------------
-- 6) Time-series DB  ->  declarative partitioning + BRIN index
------------------------------------------------------------------------------
CREATE TABLE events (
    occurred_at timestamptz NOT NULL,
    kind        text        NOT NULL,
    data        jsonb       NOT NULL DEFAULT '{}'::jsonb
) PARTITION BY RANGE (occurred_at);

CREATE TABLE events_2026_06 PARTITION OF events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE events_2026_07 PARTITION OF events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

-- BRIN is tiny and ideal for append-only, time-ordered data.
CREATE INDEX events_brin ON events USING brin (occurred_at);

INSERT INTO events (occurred_at, kind)
SELECT TIMESTAMPTZ '2026-06-01' + (g || ' minutes')::interval, 'click'
FROM generate_series(1, 1000) AS g;

------------------------------------------------------------------------------
-- 7) Snowflake / warehouse dashboards  ->  materialized view
------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW event_daily AS
    SELECT date_trunc('day', occurred_at) AS day,
           kind,
           count(*) AS n
    FROM events
    GROUP BY 1, 2
    WITH DATA;
-- Unique index is required for the non-blocking refresh below.
CREATE UNIQUE INDEX event_daily_pk ON event_daily (day, kind);
-- Refresh without locking readers:
--   REFRESH MATERIALIZED VIEW CONCURRENTLY event_daily;

------------------------------------------------------------------------------
-- 8) Auth-aware backend  ->  row-level security (granted to API roles in 03)
------------------------------------------------------------------------------
CREATE TABLE notes (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner text NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json ->> 'sub',
    body  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;

-- A request can only see and write rows whose owner == the JWT 'sub' claim.
CREATE POLICY notes_isolation ON notes
    USING      (owner = current_setting('request.jwt.claims', true)::json ->> 'sub')
    WITH CHECK (owner = current_setting('request.jwt.claims', true)::json ->> 'sub');
