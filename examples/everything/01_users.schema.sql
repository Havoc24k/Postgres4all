-- 👤 self-service accounts for the tour: a users table + an HS256 JWT signer.
--
-- This is the canonical PostgREST "users + register + login" pattern, which turns the auth capability
-- into a real drop-in auth service: Alice signs up and logs in over HTTP and gets a token, with no CLI
-- (mint-token stays available as an admin shortcut). See register.plpgsql.sql / login.plpgsql.sql.
--
-- Applied (like the rest of this folder) under SET ROLE api_owner, so the table, the signer, and the
-- register/login functions are all owned by the non-superuser api_owner.
--
-- TWO ADMIN PREREQUISITES (operator's job — see README "Let Alice register herself"):
--   1. CREATE EXTENSION pgcrypto;                 -- crypt()/gen_salt() (bcrypt) + hmac() for signing
--   2. ALTER DATABASE <db> SET "app.jwt_secret" = '<JWT_SECRET from build/.env>';  then restart postgrest
--      so login() can sign tokens PostgREST will accept (it verifies against the same JWT_SECRET).

-- Credentials store. No grants to anon/authenticated, so PostgREST never exposes it; only the
-- SECURITY DEFINER register/login functions (owned by api_owner) read or write it.
CREATE TABLE IF NOT EXISTS users (
    email      text PRIMARY KEY,
    pwhash     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- sign(payload, secret): a compact HS256 JWT signer built on pgcrypto's hmac(). Base64URL is standard
-- base64 with '+/'->'-_' and '=' / newlines stripped (translate drops chars past the 2-char target).
-- Not granted to anyone — only login() (a definer function owned by api_owner) calls it.
CREATE OR REPLACE FUNCTION sign(payload json, secret text)
RETURNS text LANGUAGE sql IMMUTABLE AS $sign$
    WITH
      header AS (
        SELECT translate(encode(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'), 'base64'), E'+/=\n', '-_') AS v
      ),
      body AS (
        SELECT translate(encode(convert_to(payload::text, 'utf8'), 'base64'), E'+/=\n', '-_') AS v
      ),
      signables AS (SELECT header.v || '.' || body.v AS v FROM header, body)
    SELECT signables.v || '.' ||
           translate(encode(hmac(signables.v, secret, 'sha256'), 'base64'), E'+/=\n', '-_')
    FROM signables;
$sign$;
