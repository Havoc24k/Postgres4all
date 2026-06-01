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

# Generation + run added in later tasks.
