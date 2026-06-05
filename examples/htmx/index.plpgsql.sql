-- 🧩 htmx todo page — index, in PL/pgSQL. Exposed at: GET /rpc/index_plpgsql
--
-- Returns a full HTML page (RETURNS "text/html", so PostgREST sends Content-Type: text/html). The page
-- loads htmx and renders the current todos; the form posts to add_todo_plpgsql and htmx appends the
-- returned <li> to the list. Open it in a browser (browsers send Accept: text/html) or curl with
-- `-H 'Accept: text/html'`.
CREATE OR REPLACE FUNCTION index_plpgsql() RETURNS "text/html" LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    items text;
BEGIN
    SELECT coalesce(string_agg('<li>' || escape_html(task) || '</li>', '' ORDER BY id), '')
      INTO items FROM todos;

    RETURN
'<!doctype html>
<html>
<head><meta charset="utf-8"><title>todos</title>
<script src="https://unpkg.com/htmx.org@2.0.3"></script></head>
<body hx-headers=''{"Accept": "text/html"}''>
  <h1>Todos</h1>
  <ul id="list">' || items || '</ul>
  <form hx-post="/rpc/add_todo_plpgsql" hx-target="#list" hx-swap="beforeend"
        hx-on::after-request="this.reset()">
    <input name="task" placeholder="new task" required>
    <button type="submit">Add</button>
  </form>
</body>
</html>';
END
$fn$;

-- anon serves the page.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION index_plpgsql() TO anon, authenticated;
    END IF;
END $$;
