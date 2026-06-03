# 🧠 Vector search (replaces Pinecone)

Store embeddings in a `vector` column and rank by similarity over the HTTP API. This example does the
headline trick — semantic K-nearest-neighbours **and** a relational `WHERE` in one query — behind an
`/rpc` function, because the `ORDER BY embedding <=> $query` expression can't be written in
PostgREST's URL grammar.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
    "vector": true,
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

Apply this folder's `/rpc` functions with the CLI and it reloads
PostgREST's schema cache (give it a second before calling):

```bash
./postgres4all apply-functions examples/vector
```

That loads [match_documents.plpgsql.sql](match_documents.plpgsql.sql) and
[match_documents.plpython.sql](match_documents.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**KNN + relational filter — PL/pgSQL** (`<=>` is cosine distance; `owner` scopes the search to one
user — semantic similarity *and* a relational predicate in one query):

```bash
curl -s -X POST "http://localhost:3000/rpc/match_documents_plpgsql" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}' | jq
```

```json
[
  {
    "content": "cat",
    "distance": 0
  },
  {
    "content": "dog",
    "distance": 0.0018
  }
]
```

The PL/Python variant (`/rpc/match_documents_plpython`) returns the identical result.
