# 📄 Document store (replaces MongoDB)

Store schemaless documents as `JSONB` and query them by containment over the HTTP API — the `@>`
operator asks "does this document contain this fragment?", giving MongoDB-style filtering on
arbitrary nested attributes with no fixed schema.

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

The `/rpc` functions ship as SQL in this folder. Apply them with the CLI and it reloads PostgREST's schema cache (give it a second to take effect before calling):

```bash
./postgres4all apply-functions examples/document_store
```

That loads [products_matching.plpgsql.sql](products_matching.plpgsql.sql) and
[products_matching.plpython.sql](products_matching.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**Native REST — filter by containment** (PostgREST's `cs` maps to the `@>` JSONB operator; `-g` stops
curl globbing the `{}`):

```bash
curl -sg "http://localhost:3000/products?attributes=cs.{\"wireless\":true}&select=name,attributes" | jq
```

```json
[
  {
    "name": "Mechanical Keyboard",
    "attributes": {
      "tags": [
        "typing",
        "gaming"
      ],
      "brand": "Keychron",
      "switch": "brown",
      "wireless": true
    }
  }
]
```

**Same query as an `/rpc` function — PL/pgSQL** (POST the filter as a JSON body):

```bash
curl -s -X POST "http://localhost:3000/rpc/products_matching_plpgsql" \
  -H 'Content-Type: application/json' -d '{"filter":{"wireless":true}}' | jq
```

```json
[
  {
    "id": 1,
    "name": "Mechanical Keyboard",
    "attributes": {
      "tags": [
        "typing",
        "gaming"
      ],
      "brand": "Keychron",
      "switch": "brown",
      "wireless": true
    }
  }
]
```

The PL/Python variant (`/rpc/products_matching_plpython`) returns the identical result.
