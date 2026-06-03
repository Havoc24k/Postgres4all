# 🔍 Search (replaces Elasticsearch)

Postgres does full-text and typo-tolerant search natively — `tsvector`/`websearch_to_tsquery` for ranked full-text, and `pg_trgm` similarity for fuzzy matching. Both are reachable over the HTTP API: full-text filtering comes straight from PostgREST's table endpoint, and fuzzy ranking is exposed as an RPC, so callers get Elasticsearch-style search with plain HTTP and no separate search cluster.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "search": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/search/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## Native REST full-text search

PostgREST exposes the `tsvector` column directly: `tsv=wfts(english).run` runs `websearch_to_tsquery` so the query `run` matches the stemmed token in "Running", returning ranked full-text hits with no function required.

```bash
curl -s "http://localhost:3000/articles?tsv=wfts(english).run&select=title"; echo
```

```json
[{"title":"Running Postgres in production"}]
```

## Typo-tolerant search via /rpc — PL/pgSQL

Fuzzy matching needs a function because the `<%` word-similarity operator and `word_similarity()` scoring aren't expressible as a PostgREST filter; the `fuzzy_search_plpgsql` RPC takes a misspelled query and ranks rows by trigram similarity, so `postgrez` still finds "Postgres".

```bash
curl -s -X POST "http://localhost:3000/rpc/fuzzy_search_plpgsql" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}'; echo
```

```json
[{"title":"Running Postgres in production","score":0.778}]
```

## Same via /rpc — PL/Python (identical ranking)

The same fuzzy search implemented in PL/Python prepares and executes the identical trigram query, returning the same ranked result.

```bash
curl -s -X POST "http://localhost:3000/rpc/fuzzy_search_plpython" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}'; echo
```

```json
[{"title":"Running Postgres in production","score":0.778}]
```

## The two implementations

[fuzzy_search.plpgsql.sql](fuzzy_search.plpgsql.sql) and [fuzzy_search.plpython.sql](fuzzy_search.plpython.sql) implement the same typo-tolerant ranking — one in PL/pgSQL, one in PL/Python — and return identically. In a real project these would live in `functions/` and be applied to a running install with `./postgres4all apply-functions`.
