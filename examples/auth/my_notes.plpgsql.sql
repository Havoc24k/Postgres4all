-- 🔐 auth (hand-written auth) — read "my" notes, in PL/pgSQL. The bare SELECT is safe because
-- row-level security runs the function as the calling role and scopes rows to the JWT 'sub'.
CREATE OR REPLACE FUNCTION my_notes_plpgsql()
RETURNS SETOF notes LANGUAGE plpgsql STABLE AS $fn$
BEGIN RETURN QUERY SELECT * FROM notes; END;
$fn$;
