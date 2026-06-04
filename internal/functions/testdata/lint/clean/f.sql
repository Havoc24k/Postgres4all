CREATE FUNCTION f() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT 1 $$;
ALTER FUNCTION f() OWNER TO api_owner;
