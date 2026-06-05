FROM postgres:17
ARG PG_MAJOR=17
RUN set -eux; apt-get update; apt-get install -y --no-install-recommends pgxnclient build-essential postgresql-server-dev-17; pgxn install safeupdate; apt-get purge -y pgxnclient build-essential postgresql-server-dev-17; apt-get autoremove -y; rm -rf /var/lib/apt/lists/*
COPY init/ /docker-entrypoint-initdb.d/
