#!/bin/bash
set -euo pipefail
: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     --set authpw="$AUTHENTICATOR_PASSWORD" <<-'EOSQL'
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'authpw';
    CREATE ROLE api_owner NOLOGIN NOINHERIT;
    GRANT anon, authenticated TO authenticator;
EOSQL
