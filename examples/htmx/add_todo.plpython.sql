-- 🧩 htmx todo add — add_todo, in PL/Python. Exposed at: POST /rpc/add_todo_plpython
--
-- Identical to add_todo.plpgsql.sql: inserts a todo, returns the new <li>. SECURITY DEFINER owned by
-- api_owner; plpy.prepare/execute parameterise the insert.
CREATE OR REPLACE FUNCTION add_todo_plpython(task text) RETURNS "text/html"
LANGUAGE plpython3u
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
import html
# Don't reassign `task` — PL/Python exposes args as globals, so `task = ...` would shadow it
# as a local and raise UnboundLocalError. Use a fresh name.
text = (task or "").strip()
if not text:
    plpy.error("task is required", sqlstate="22023")  # -> 400
plan = plpy.prepare("INSERT INTO todos (task) VALUES ($1) RETURNING task", ["text"])
saved = plpy.execute(plan, [text])[0]["task"]
return "<li>%s</li>" % html.escape(saved)
$fn$;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION add_todo_plpython(text) TO anon, authenticated;
    END IF;
END $$;
