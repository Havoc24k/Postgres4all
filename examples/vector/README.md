# 🧠 Vector search (replaces Pinecone)

Store embeddings alongside your relational rows and rank them by similarity with pgvector's distance operators — then expose that ranking as a single HTTP endpoint, so a client can do approximate-nearest-neighbour search over the API without a separate vector database.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "vector": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/vector/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## Nearest neighbours — PL/pgSQL

KNN search needs a function because the relational `owner` filter and the `<=>` cosine-distance ordering live together server-side; the endpoint takes the query vector as text and casts it to `vector` inside the function.

```bash
curl -s -X POST "http://localhost:3000/rpc/match_documents_plpgsql" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}'; echo
```

```json
[{"content":"cat","distance":0}, 
 {"content":"dog","distance":0.0018}]
```

## Same via /rpc — PL/Python

The same KNN-plus-filter logic written in PL/Python, returning the identical ranking through its own `/rpc` endpoint.

```bash
curl -s -X POST "http://localhost:3000/rpc/match_documents_plpython" \
  -H 'Content-Type: application/json' -d '{"query":"[0.10,0.20,0.30]","owner":1}'; echo
```

```json
[{"content":"cat","distance":0}, 
 {"content":"dog","distance":0.0018}]
```

## The two implementations

[match_documents.plpgsql.sql](match_documents.plpgsql.sql) and [match_documents.plpython.sql](match_documents.plpython.sql) express the same KNN-plus-relational-filter and return identically. In a real project they'd live in `functions/` and be applied with `./postgres4all apply-functions`.
