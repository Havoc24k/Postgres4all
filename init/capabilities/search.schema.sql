-- search: Elasticsearch -> tsvector + pg_trgm
CREATE TABLE articles (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL,
    body  text NOT NULL,
    tsv   tsvector GENERATED ALWAYS AS
              (to_tsvector('english', title || ' ' || body)) STORED
);
CREATE INDEX articles_tsv_idx        ON articles USING gin (tsv);
CREATE INDEX articles_title_trgm_idx ON articles USING gin (title gin_trgm_ops);
