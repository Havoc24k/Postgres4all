DROP TABLE IF EXISTS articles CASCADE;

DROP EXTENSION IF EXISTS pg_trgm;
DELETE FROM p4a_meta.capabilities WHERE cap = 'search';
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM anon;
DROP OWNED BY authenticator, anon, authenticated, api_owner;
DROP ROLE IF EXISTS authenticator;
DROP ROLE IF EXISTS authenticated;
DROP ROLE IF EXISTS anon;
DROP ROLE IF EXISTS api_owner;
DROP EXTENSION IF EXISTS pg_graphql;
DELETE FROM p4a_meta.capabilities WHERE cap = 'api';
