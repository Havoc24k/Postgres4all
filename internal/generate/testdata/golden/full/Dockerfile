FROM postgis/postgis:17-3.5
ARG PG_MAJOR=17
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-17-pgvector ca-certificates wget && rm -rf /var/lib/apt/lists/*
RUN set -eux; apt-get update; apt-get install -y --no-install-recommends pgxnclient build-essential postgresql-server-dev-17; pgxn install safeupdate; apt-get purge -y pgxnclient build-essential postgresql-server-dev-17; apt-get autoremove -y; rm -rf /var/lib/apt/lists/*
COPY init/ /docker-entrypoint-initdb.d/
