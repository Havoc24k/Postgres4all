-- 👤 self-service login — login, in PL/pgSQL. Exposed at: POST /rpc/login
--
-- anon-callable. Verifies the bcrypt password, then mints a short-lived HS256 JWT — the SAME token
-- shape `postgres4all mint-token` produces, signed with the SAME JWT_SECRET — so PostgREST accepts it
-- on every later request. SECURITY DEFINER owned by api_owner (to read the credentials table and the
-- sign() helper). The secret comes from the app.jwt_secret GUC (see README prereqs / 01_users.schema.sql).
CREATE OR REPLACE FUNCTION login(email text, pass text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    u      users;
    secret text := current_setting('app.jwt_secret', true);  -- true = NULL if unset, don't error
    token  text;
BEGIN
    IF secret IS NULL OR secret = '' THEN
        RAISE EXCEPTION 'auth is not configured: set the app.jwt_secret GUC (see README prereqs)'
            USING errcode = '55000';  -- object_not_in_prerequisite_state -> PostgREST 500 (operator bug)
    END IF;

    SELECT * INTO u FROM users WHERE users.email = login.email;

    -- Same error whether the email is unknown or the password is wrong (don't leak which).
    IF u.email IS NULL OR u.pwhash <> crypt(login.pass, u.pwhash) THEN
        RAISE EXCEPTION 'invalid email or password'
            USING errcode = '28P01';  -- invalid_password
    END IF;

    token := sign(json_build_object(
        'role', 'authenticated',
        'sub',  u.email,
        'exp',  extract(epoch FROM now() + interval '15 minutes')::int
    ), secret);

    RETURN json_build_object('token', token);
END;
$fn$;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION login(text, text) TO anon, authenticated;
    END IF;
END $$;
