-- 📄 document store (MongoDB) — the same containment query, in PL/Python. Identical result.
CREATE OR REPLACE FUNCTION products_matching_plpython(filter jsonb)
RETURNS SETOF products LANGUAGE plpython3u AS $fn$
plan = plpy.prepare("SELECT * FROM products WHERE attributes @> $1", ["jsonb"])
return list(plpy.execute(plan, [filter]))
$fn$;
