DROP TABLE IF EXISTS notes CASCADE;

DELETE FROM p4a_meta.capabilities WHERE cap = 'auth';
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM anon;
DROP OWNED BY authenticator, anon, authenticated;
DROP ROLE IF EXISTS authenticator;
DROP ROLE IF EXISTS authenticated;
DROP ROLE IF EXISTS anon;
DROP EXTENSION IF EXISTS pg_graphql;
DELETE FROM p4a_meta.capabilities WHERE cap = 'api';
