GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT USAGE, CREATE ON SCHEMA public TO api_owner;
GRANT SELECT ON products TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON products TO api_owner;
INSERT INTO p4a_meta.capabilities (cap) VALUES ('api') ON CONFLICT (cap) DO NOTHING;
