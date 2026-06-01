# Postgres "replace your whole stack" image.
# Base = official PostGIS image (itself built on the official postgres image,
# so the PGDG apt repo and the contrib modules — pg_trgm, btree_gin, btree_gist — are present).
ARG PG_MAJOR=17
FROM postgis/postgis:${PG_MAJOR}-3.5

# Re-declare after FROM so the value is visible in the build stage.
ARG PG_MAJOR=17
ARG PG_GRAPHQL_VERSION=1.5.11

# 1) pgvector (vector search, HNSW) from the PGDG repo already configured in the base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-${PG_MAJOR}-pgvector \
      ca-certificates wget \
 && rm -rf /var/lib/apt/lists/*

# 2) pg_graphql (auto GraphQL API) — prebuilt .deb from the Supabase release, arch-aware.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) pgg_arch="amd64" ;; \
      arm64) pgg_arch="arm64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/supabase/pg_graphql/releases/download/v${PG_GRAPHQL_VERSION}/pg_graphql-v${PG_GRAPHQL_VERSION}-pg${PG_MAJOR}-${pgg_arch}-linux-gnu.deb"; \
    wget -q -O /tmp/pg_graphql.deb "$url"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/pg_graphql.deb; \
    rm -f /tmp/pg_graphql.deb; \
    rm -rf /var/lib/apt/lists/*

# 3) Initialisation scripts. The entrypoint runs everything in this directory,
#    in filename order, the first time the data volume is empty.
#    PostGIS' own *.sh in this dir still runs first (it is copied by the base image).
COPY init/ /docker-entrypoint-initdb.d/

# pg_trgm / btree_gin are contrib modules already shipped in the base image — no extra install needed.
