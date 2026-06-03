-- 📄 document store (MongoDB) — JSONB containment query, in PL/pgSQL.
CREATE OR REPLACE FUNCTION products_matching_plpgsql(filter jsonb)
RETURNS SETOF products LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY SELECT * FROM products WHERE attributes @> filter;
END;
$fn$;
