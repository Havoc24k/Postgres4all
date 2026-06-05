-- 🧩 htmx todo add — add_todo, in PL/pgSQL. Exposed at: POST /rpc/add_todo_plpgsql
--
-- Inserts a todo and returns ONLY the new <li> as HTML. htmx swaps that fragment into the list
-- (hx-swap="beforeend"). SECURITY DEFINER (owned by api_owner) so the anon caller needs no INSERT grant
-- on todos. htmx posts the form url-encoded; PostgREST maps the `task` field to the argument.
CREATE OR REPLACE FUNCTION add_todo_plpgsql(task text) RETURNS "text/html"
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    saved text;
BEGIN
    IF task IS NULL OR length(trim(task)) = 0 THEN
        RAISE EXCEPTION 'task is required' USING errcode = '22023';  -- -> 400
    END IF;
    INSERT INTO todos (task) VALUES (trim(add_todo_plpgsql.task))
        RETURNING todos.task INTO saved;
    RETURN '<li>' || escape_html(saved) || '</li>';
END
$fn$;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION add_todo_plpgsql(text) TO anon, authenticated;
    END IF;
END $$;
