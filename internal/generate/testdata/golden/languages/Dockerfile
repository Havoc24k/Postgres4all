FROM postgres:17
ARG PG_MAJOR=17
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-plperl-17 postgresql-plpython3-17 && rm -rf /var/lib/apt/lists/*
COPY init/ /docker-entrypoint-initdb.d/
