# 📄 Document store (replaces MongoDB)

Store schemaless documents as `JSONB` and query them by containment over the HTTP API — the `@>` operator asks "does this document contain this fragment?", giving you MongoDB-style filtering on arbitrary nested attributes without a fixed schema.

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
bash examples/document_store/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## Native REST: filter JSON documents by containment (`cs` = `@>`)

PostgREST maps its `cs` (contains) operator straight onto the Postgres `@>` JSONB containment operator, so you can filter documents on a nested attribute with no function at all.

```bash
curl -sg "http://localhost:3000/products?attributes=cs.{\"wireless\":true}&select=name,attributes"; echo
```

```json
[{"name":"Mechanical Keyboard","attributes":{"tags": ["typing", "gaming"], "brand": "Keychron", "switch": "brown", "wireless": true}}]
```

## Same query via `/rpc` — PL/pgSQL

Wrapping the same `@>` containment query in a function lets callers POST the filter as a JSON body; PostgREST exposes it at `/rpc`.

```bash
curl -s -X POST "http://localhost:3000/rpc/products_matching_plpgsql" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}'; echo
```

```json
[{"id":1,"name":"Mechanical Keyboard","attributes":{"tags": ["typing", "gaming"], "brand": "Keychron", "switch": "brown", "wireless": true}}]
```

## Same query via `/rpc` — PL/Python (identical)

The PL/Python implementation prepares the identical containment query and returns the same rows, proving the language is just an implementation detail behind the API.

```bash
curl -s -X POST "http://localhost:3000/rpc/products_matching_plpython" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}'; echo
```

```json
[{"id":1,"name":"Mechanical Keyboard","attributes":{"tags": ["typing", "gaming"], "brand": "Keychron", "switch": "brown", "wireless": true}}]
```

## The two implementations

The two functions — [products_matching.plpgsql.sql](products_matching.plpgsql.sql) and [products_matching.plpython.sql](products_matching.plpython.sql) — run the same `@>` containment query and return identical results. In a real project they'd live in `functions/` and be applied with `./postgres4all apply-functions`.
