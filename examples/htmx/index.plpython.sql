-- 🧩 htmx todo page — index, in PL/Python. Exposed at: GET /rpc/index_plpython
--
-- Identical to index.plpgsql.sql; its form posts to add_todo_plpython. plpython3u is UNTRUSTED, which
-- is why the example needs "allow_untrusted": true.
CREATE OR REPLACE FUNCTION index_plpython() RETURNS "text/html"
LANGUAGE plpython3u
STABLE
AS $fn$
import html
rows = plpy.execute("SELECT task FROM todos ORDER BY id")
items = "".join("<li>%s</li>" % html.escape(r["task"]) for r in rows)
return """<!doctype html>
<html>
<head><meta charset="utf-8"><title>todos</title>
<script src="https://unpkg.com/htmx.org@2.0.3"></script></head>
<body hx-headers='{"Accept": "text/html"}'>
  <h1>Todos</h1>
  <ul id="list">%s</ul>
  <form hx-post="/rpc/add_todo_plpython" hx-target="#list" hx-swap="beforeend"
        hx-on::after-request="this.reset()">
    <input name="task" placeholder="new task" required>
    <button type="submit">Add</button>
  </form>
</body>
</html>""" % items
$fn$;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION index_plpython() TO anon, authenticated;
    END IF;
END $$;
