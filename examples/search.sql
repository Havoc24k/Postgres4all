-- 🔍 search  (replaces Elasticsearch)  — tsvector full-text + pg_trgm fuzzy matching
-- Enable: "capabilities": { "search": true }
-- Run:    psql "$DB_URL" -f examples/search.sql

-- Stemmed full-text: "run" matches "running" (the tsv column is a GIN-indexed tsvector):
SELECT title
FROM articles
WHERE tsv @@ websearch_to_tsquery('english', 'run');

-- Typo-tolerant: the misspelled "postgrez" still finds the article about "Postgres"
-- (word_similarity via the <% operator, backed by the trigram index on title):
SELECT title, round(word_similarity('postgrez', title)::numeric, 3) AS score
FROM articles
WHERE 'postgrez' <% title
ORDER BY score DESC;
