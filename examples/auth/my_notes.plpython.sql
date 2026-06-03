-- 🔐 auth (hand-written auth) — the same "my notes" read, in PL/Python. Same isolation: the
-- database enforces it via RLS, not the function.
CREATE OR REPLACE FUNCTION my_notes_plpython()
RETURNS SETOF notes LANGUAGE plpython3u AS $fn$
return plpy.execute("SELECT * FROM notes")
$fn$;
