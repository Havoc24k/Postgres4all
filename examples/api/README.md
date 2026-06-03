# 🔌 API

Postgres serves its own HTTP API: PostgREST turns every table into a REST endpoint, and a one-line
wrapper function exposes `pg_graphql` over `/rpc` — so a GraphQL query and a REST read both resolve
straight out of the database, with no application tier in between.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
    "document_store": true,
    "api": true
  },
  "languages": {
    "plpython": true,
    "allow_untrusted": true
  }
}
```

Build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Load the example's functions

Apply this folder's GraphQL-wrapper functions with the CLI and it
reloads PostgREST's schema cache (give it a second before calling):

```bash
./postgres4all apply-functions examples/api
```

That loads [graphql.plpgsql.sql](graphql.plpgsql.sql) and [graphql.plpython.sql](graphql.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**REST for free — every table is an endpoint** (anonymous `GET`, no route or controller to write):

```bash
curl -s "http://localhost:3000/products?select=id,name&limit=3" | jq
```

```json
[
  {
    "id": 1,
    "name": "Mechanical Keyboard"
  },
  {
    "id": 2,
    "name": "USB-C Hub"
  }
]
```

**GraphQL via an `/rpc` function — PL/pgSQL** (`pg_graphql` lives in the database; the wrapper hands
the query string to `graphql.resolve()`):

```bash
curl -s -X POST "http://localhost:3000/rpc/graphql_plpgsql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ productsCollection { edges { node { name } } } }"}' | jq
```

```json
{
  "data": {
    "productsCollection": {
      "edges": [
        {
          "node": {
            "name": "Mechanical Keyboard"
          }
        },
        {
          "node": {
            "name": "USB-C Hub"
          }
        }
      ]
    }
  }
}
```

The PL/Python variant (`/rpc/graphql_plpython`) returns the identical result.
