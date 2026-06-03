CREATE EXTENSION IF NOT EXISTS pg_graphql;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON products TO anon, authenticated;
GRANT USAGE ON SCHEMA graphql TO anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graphql TO anon, authenticated;
INSERT INTO p4a_meta.capabilities (cap) VALUES ('api') ON CONFLICT (cap) DO NOTHING;
