-- 🔍 search (Elasticsearch) — typo-tolerant ranking via pg_trgm, in PL/pgSQL.
-- '<%' = "any word in title is similar to the query" (word_similarity above the threshold).
CREATE OR REPLACE FUNCTION fuzzy_search_plpgsql(q text)
RETURNS TABLE(title text, score real) LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY
    SELECT a.title, round(word_similarity(q, a.title)::numeric, 3)::real
    FROM articles a WHERE q <% a.title ORDER BY 2 DESC;
END;
$fn$;
