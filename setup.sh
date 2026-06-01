#!/usr/bin/env bash
set -euo pipefail

CAPS=(document_store job_queue search vector gis timeseries dashboards api auth)

die() { echo "ERROR: $*" >&2; exit 1; }

DRY_RUN=0
CONFIG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --*) die "unknown option: $arg" ;;
    *) CONFIG="$arg" ;;
  esac
done
[ -n "$CONFIG" ] || CONFIG="config.json"

# --- preflight ---
for tool in jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
if [ "$DRY_RUN" -eq 0 ]; then
  command -v docker >/dev/null 2>&1 || die "missing required tool: docker"
  docker compose version >/dev/null 2>&1 || die "missing required tool: docker compose"
fi

# --- read config ---
[ -f "$CONFIG" ] || die "config file not found: $CONFIG"
jq -e . "$CONFIG" >/dev/null 2>&1 || die "invalid JSON in $CONFIG"

cap() { # cap <name> -> "1" if enabled else "0"
  jq -r --arg k "$1" '.capabilities[$k] // false | if . then 1 else 0 end' "$CONFIG"
}
declare -A EN
for c in "${CAPS[@]}"; do EN[$c]=$(cap "$c"); done

# --- validate ---
any=0; for c in "${CAPS[@]}"; do [ "${EN[$c]}" = 1 ] && any=1; done
[ "$any" = 1 ] || die "no capabilities enabled in $CONFIG"

if [ "${EN[auth]}" = 1 ] && [ "${EN[api]}" = 0 ]; then
  die "capability 'auth' requires 'api'. Enable \"api\": true in $CONFIG."
fi

if [ "${EN[dashboards]}" = 1 ] && [ "${EN[timeseries]}" = 0 ]; then
  die "capability 'dashboards' requires 'timeseries'. Enable \"timeseries\": true in $CONFIG."
fi

echo "config OK: $(for c in "${CAPS[@]}"; do [ "${EN[$c]}" = 1 ] && printf '%s ' "$c"; done)"

PG_MAJOR=17
POSTGIS_VERSION=3.5
PG_GRAPHQL_VERSION=1.5.11

cd "$(dirname "$0")"  # anchor build/ output next to the script; config already read above
rm -rf build
mkdir -p build/init

# --- Dockerfile ---
{
  if [ "${EN[gis]}" = 1 ]; then
    echo "FROM postgis/postgis:${PG_MAJOR}-${POSTGIS_VERSION}"
  else
    echo "FROM postgres:${PG_MAJOR}"
  fi
  echo "ARG PG_MAJOR=${PG_MAJOR}"
  if [ "${EN[vector]}" = 1 ]; then
    cat <<DF
RUN apt-get update \\
 && apt-get install -y --no-install-recommends \\
      postgresql-${PG_MAJOR}-pgvector ca-certificates wget \\
 && rm -rf /var/lib/apt/lists/*
DF
  fi
  if [ "${EN[api]}" = 1 ]; then
    if [ "${EN[vector]}" != 1 ]; then
      echo "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget && rm -rf /var/lib/apt/lists/*"
    fi
    printf 'RUN set -eux; arch="$(dpkg --print-architecture)"; '
    printf 'url="https://github.com/supabase/pg_graphql/releases/download/v%s/pg_graphql-v%s-pg%s-${arch}-linux-gnu.deb"; ' \
      "$PG_GRAPHQL_VERSION" "$PG_GRAPHQL_VERSION" "$PG_MAJOR"
    printf 'wget -q -O /tmp/pg_graphql.deb "$url"; apt-get update; apt-get install -y --no-install-recommends /tmp/pg_graphql.deb; rm -f /tmp/pg_graphql.deb; rm -rf /var/lib/apt/lists/*\n'
  fi
  echo "COPY init/ /docker-entrypoint-initdb.d/"
} > build/Dockerfile

if [ "$DRY_RUN" -eq 1 ]; then echo "dry-run: generated build/ (Dockerfile)"; fi
