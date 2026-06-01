-- Expose the schema to the PostgREST roles created in 00-roles.sh.
-- This is the "Postgres IS the backend" part of the video: PostgREST turns
-- these grants + RLS policies into a REST API, pg_graphql into a GraphQL API.

GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Read-only demo tables are public.
GRANT SELECT ON products, jobs, articles, documents, places, events, event_daily
    TO anon, authenticated;

-- notes is private per-user. Only authenticated requests get CRUD, and RLS
-- (set in 02-schema.sql) restricts them to their own rows.
GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;

-- pg_graphql resolver access (grant by schema to avoid pinning the exact signature).
GRANT USAGE ON SCHEMA graphql TO anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql TO anon, authenticated;

-- Default privileges so future tables created by the superuser are also visible
-- to anon for SELECT (convenient for a demo; tighten for production).
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
