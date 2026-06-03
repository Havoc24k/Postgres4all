-- 🔍 search (Elasticsearch) — the same typo-tolerant ranking, in PL/Python. Identical ranking.
CREATE OR REPLACE FUNCTION fuzzy_search_plpython(q text)
RETURNS TABLE(title text, score real) LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT title, round(word_similarity($1, title)::numeric, 3)::real AS score "
    "FROM articles WHERE $1 <% title ORDER BY score DESC", ["text"])
return plpy.execute(plan, [q])
$fn$;
