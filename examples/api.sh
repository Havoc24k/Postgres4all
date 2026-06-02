#!/usr/bin/env bash
# 🔌 api  (replaces Node/Python middleware)  — PostgREST REST + pg_graphql GraphQL
# Enable: "capabilities": { "document_store": true, "api": true }
# Run:    bash examples/api.sh
set -euo pipefail
BASE=${BASE:-http://localhost:3000}

echo "# REST — read a table (anonymous):"
curl -s "$BASE/products" | head -c 200; echo

echo
echo "# REST — filter with PostgREST query syntax (JSON containment). -g = no curl URL globbing:"
curl -sg "$BASE/products?attributes=cs.{\"wireless\":true}"; echo

echo
echo "# GraphQL — pg_graphql resolves a query in SQL (run inside the db container):"
U=$(grep '^POSTGRES_USER=' build/.env | cut -d= -f2-)
D=$(grep '^POSTGRES_DB=' build/.env | cut -d= -f2-)
docker compose --env-file build/.env -f build/docker-compose.yml exec -T db \
  psql -U "$U" -d "$D" -tAc \
  "SELECT graphql.resolve(\$\$ { productsCollection { edges { node { name } } } } \$\$);"
