#!/bin/bash
# Runs first on a fresh data volume. Creates the PostgREST role chain.
# AUTHENTICATOR_PASSWORD is passed in from the container environment so no
# secret is baked into the SQL files.
set -euo pipefail

: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" \
     --set authpw="$AUTHENTICATOR_PASSWORD" <<-'EOSQL'
    -- anon  = unauthenticated requests
    -- authenticated = logged-in requests (carries a JWT)
    -- authenticator = the login role PostgREST connects as, then switches role
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'authpw';
    GRANT anon, authenticated TO authenticator;
EOSQL
