-- 👤 self-service signup — register, in PL/pgSQL. Exposed at: POST /rpc/register
--
-- anon-callable (it's how you get an account in the first place). SECURITY DEFINER owned by api_owner,
-- so it can write the `users` table that no PostgREST role has direct grants on. The password is
-- stored only as a bcrypt hash (pgcrypto's crypt() + gen_salt('bf')) — never in plaintext.
CREATE OR REPLACE FUNCTION register(email text, pass text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
    IF email IS NULL OR pass IS NULL OR length(pass) < 6 THEN
        RAISE EXCEPTION 'email required and password must be at least 6 characters'
            USING errcode = '22023';  -- invalid_parameter_value -> PostgREST 400
    END IF;

    INSERT INTO users (email, pwhash)
    VALUES (register.email, crypt(register.pass, gen_salt('bf')));

    RETURN json_build_object('registered', true, 'email', register.email);
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'email % is already registered', register.email
        USING errcode = '23505';  -- unique_violation -> PostgREST 409
END;
$fn$;

-- anon must be able to call it (you have no token yet when you sign up).
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT EXECUTE ON FUNCTION register(text, text) TO anon, authenticated;
    END IF;
END $$;
