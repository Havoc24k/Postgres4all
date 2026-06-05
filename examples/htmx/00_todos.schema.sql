-- 🧩 htmx over PostgREST: serve HTML straight from the database.
--
-- PostgREST keys a response's Content-Type off the RETURN TYPE NAME of the function. Define a domain
-- literally named "text/html" and any function that `RETURNS "text/html"` is served as HTML (when the
-- request's Accept allows it) instead of JSON. No templating engine, no view layer — just a type.
-- https://docs.postgrest.org/en/v14/how-tos/providing-html-content-using-htmx.html
--
-- Applied (with the rest of this folder) under SET ROLE api_owner, so the domain, table, and functions
-- are owned by the non-superuser api_owner.

-- The media-type handler. CREATE DOMAIN has no IF NOT EXISTS, so guard it for re-apply.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_type WHERE typname = 'text/html') THEN
        CREATE DOMAIN "text/html" AS text;
    END IF;
END $$;

-- Minimal HTML escaper — user input must never be concatenated into HTML raw (XSS). The functions
-- below run every user-supplied value through this before embedding it.
CREATE OR REPLACE FUNCTION escape_html(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(replace(replace(
               t, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

CREATE TABLE IF NOT EXISTS todos (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task text    NOT NULL,
    done boolean NOT NULL DEFAULT false
);

-- A couple of rows so the page isn't empty on first load.
INSERT INTO todos (task)
    SELECT v.t FROM (VALUES ('Buy milk'), ('Read the PostgREST docs')) AS v(t)
    WHERE NOT EXISTS (SELECT 1 FROM todos);

-- anon may READ the table (PostgREST). Inserts go through add_todo (a SECURITY DEFINER function),
-- so no direct write grant is handed out.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT SELECT ON todos TO anon, authenticated;
    END IF;
END $$;
