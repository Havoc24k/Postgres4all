# 🔍 Search (replaces Elasticsearch)

Postgres does full-text and typo-tolerant search natively — `tsvector` / `websearch_to_tsquery` for
ranked full-text, and `pg_trgm` similarity for fuzzy matching. Full-text comes straight from
PostgREST's table endpoint; fuzzy ranking is exposed as an `/rpc`, so callers get Elasticsearch-style
search over plain HTTP with no separate search cluster.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
    "search": true,
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

Apply this folder's `/rpc` functions with the CLI — the binary does it, no scripts — and it reloads
PostgREST's schema cache (give it a second before calling):

```bash
./postgres4all apply-functions examples/search
```

That loads [fuzzy_search.plpgsql.sql](fuzzy_search.plpgsql.sql) and
[fuzzy_search.plpython.sql](fuzzy_search.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**Native REST — stemmed full-text** (PostgREST's `wfts` is `websearch_to_tsquery`; the stemmer makes
`run` match `running`):

```bash
curl -s "http://localhost:3000/articles?tsv=wfts(english).run&select=title" | jq
```

```json
[
  {
    "title": "Running Postgres in production"
  }
]
```

**Typo-tolerant search for `postgrez` — PL/pgSQL** (`pg_trgm` `word_similarity` still finds
"Postgres" despite the typo):

```bash
curl -s -X POST "http://localhost:3000/rpc/fuzzy_search_plpgsql" \
  -H 'Content-Type: application/json' -d '{"q":"postgrez"}' | jq
```

```json
[
  {
    "title": "Running Postgres in production",
    "score": 0.778
  }
]
```

The PL/Python variant (`/rpc/fuzzy_search_plpython`) returns the identical ranking.

## The two implementations

[fuzzy_search.plpgsql.sql](fuzzy_search.plpgsql.sql) and
[fuzzy_search.plpython.sql](fuzzy_search.plpython.sql) run the same `word_similarity` ranking and
return identically. In a real project these would live in `functions/` and `./postgres4all
apply-functions` (no argument) would apply them from there.
