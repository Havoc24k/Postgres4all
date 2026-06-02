FROM postgis/postgis:17-3.5
ARG PG_MAJOR=17
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-17-pgvector ca-certificates wget && rm -rf /var/lib/apt/lists/*
RUN set -eux; arch="$(dpkg --print-architecture)"; url="https://github.com/supabase/pg_graphql/releases/download/v1.5.11/pg_graphql-v1.5.11-pg17-${arch}-linux-gnu.deb"; wget -q -O /tmp/pg_graphql.deb "$url"; apt-get update; apt-get install -y --no-install-recommends /tmp/pg_graphql.deb; rm -f /tmp/pg_graphql.deb; rm -rf /var/lib/apt/lists/*
COPY init/ /docker-entrypoint-initdb.d/
