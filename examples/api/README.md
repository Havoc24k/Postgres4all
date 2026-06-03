# 🔌 API (replaces hand-written Node/Python middleware)

Postgres serves its own HTTP API: PostgREST turns every table into a REST endpoint, and a one-line wrapper function exposes `pg_graphql` over `/rpc` — so a GraphQL query and a REST read both resolve straight out of the database, with no application tier in between.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "document_store": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/api/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## REST for free: every table is an endpoint

PostgREST exposes each table as a REST resource, so an anonymous `GET` reads `products` directly — no route, controller, or serializer to write.

```bash
curl -s "http://localhost:3000/products?select=id,name&limit=3"; echo
```

```json
[{"id":1,"name":"Mechanical Keyboard"}, 
 {"id":2,"name":"USB-C Hub"}]
```

## Same GraphQL query via a /rpc function — PL/pgSQL

`pg_graphql` lives inside the database, so a one-line `graphql_plpgsql(query)` wrapper hands the GraphQL string to `graphql.resolve()` and PostgREST publishes it at `/rpc`.

```bash
curl -s -X POST "http://localhost:3000/rpc/graphql_plpgsql" -H 'Content-Type: application/json' -d '{"query":"{ productsCollection { edges { node { name } } } }"}'; echo
```

```json
{"data": {"productsCollection": {"edges": [{"node": {"name": "Mechanical Keyboard"}}, {"node": {"name": "USB-C Hub"}}]}}}
```

## …and PL/Python (identical)

The same wrapper written in PL/Python calls `graphql.resolve()` through `plpy` and returns the exact same payload.

```bash
curl -s -X POST "http://localhost:3000/rpc/graphql_plpython" -H 'Content-Type: application/json' -d '{"query":"{ productsCollection { edges { node { name } } } }"}'; echo
```

```json
{"data": {"productsCollection": {"edges": [{"node": {"name": "Mechanical Keyboard"}}, {"node": {"name": "USB-C Hub"}}]}}}
```

## The two implementations

Both wrappers return identically: [graphql.plpgsql.sql](graphql.plpgsql.sql) and [graphql.plpython.sql](graphql.plpython.sql). In a real project they'd live in `functions/` and be applied with `./postgres4all apply-functions`.
