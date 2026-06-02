#!/usr/bin/env bash
# 🔍 search (replaces Elasticsearch) — stemmed full-text + typo-tolerant search over the API.
# Enable: { "search": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/search.sh
source "$(dirname "$0")/lib.sh"

echo "# Native REST full-text: PostgREST 'wfts' = websearch_to_tsquery. 'run' matches 'running':"
curl -s "$BASE/articles?tsv=wfts(english).run&select=title"; echo

# Typo-tolerant ranking (pg_trgm word_similarity) can't be expressed in the URL, so it's an /rpc
# function — shown in BOTH languages. '<%' = "any word in title is similar to the query".
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION fuzzy_search_plpgsql(q text)
RETURNS TABLE(title text, score real) LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY
    SELECT a.title, round(word_similarity(q, a.title)::numeric, 3)::real
    FROM articles a WHERE q <% a.title ORDER BY 2 DESC;
END;
$fn$;

CREATE OR REPLACE FUNCTION fuzzy_search_plpython(q text)
RETURNS TABLE(title text, score real) LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT title, round(word_similarity($1, title)::numeric, 3)::real AS score "
    "FROM articles WHERE $1 <% title ORDER BY score DESC", ["text"])
return plpy.execute(plan, [q])
$fn$;
SQL

echo
echo "# Typo-tolerant search for 'postgrez' — PL/pgSQL (still finds 'Running Postgres…'):"
curl -s -X POST "$BASE/rpc/fuzzy_search_plpgsql" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}'; echo
echo "# …and PL/Python (identical ranking):"
curl -s -X POST "$BASE/rpc/fuzzy_search_plpython" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}'; echo
