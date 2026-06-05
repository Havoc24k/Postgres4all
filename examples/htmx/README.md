# 🧩 htmx

PostgREST can return **HTML**, not just JSON — so a Postgres function can be a web page. Define a
domain literally named `"text/html"`, and any function that `RETURNS "text/html"` is served with
`Content-Type: text/html` (when the request's `Accept` allows it). Pair that with
[htmx](https://htmx.org) and you get an interactive UI with **no application server and no frontend
build** — the database is the backend *and* renders the views.

This example is a tiny todo list: a page that lists todos, and a form that adds one and swaps the new
`<li>` straight into the list. Based on the PostgREST how-to:
<https://docs.postgrest.org/en/v14/how-tos/providing-html-content-using-htmx.html>

## Prerequisites

Enable `api` (the HTTP layer) and PL/Python (for the second implementation) in `config.json`:

```jsonc
{
  "capabilities": {
    "api": true
  },
  "languages": {
    "plpython": true,
    "allow_untrusted": true
  }
}
```

```bash
./postgres4all install
```

## Load the example's functions

```bash
./postgres4all apply-functions examples/htmx
```

That creates the `"text/html"` domain + `todos` table ([00_todos.schema.sql](00_todos.schema.sql)) and
both implementations: PL/pgSQL ([index.plpgsql.sql](index.plpgsql.sql),
[add_todo.plpgsql.sql](add_todo.plpgsql.sql)) and PL/Python
([index.plpython.sql](index.plpython.sql), [add_todo.plpython.sql](add_todo.plpython.sql)).

## Use it

**Open the page in a browser** (browsers send `Accept: text/html`, so PostgREST returns the HTML):

```
http://localhost:3000/rpc/index_plpgsql
```

Type a task, hit **Add** — htmx posts to `/rpc/add_todo_plpgsql` and appends the returned `<li>` with
no full-page reload. (The PL/Python page is at `/rpc/index_plpython`; it's identical.)

**Or drive it with `curl`** — the `Accept: text/html` header is what flips PostgREST from JSON to HTML:

```bash
# the page
curl -s -H 'Accept: text/html' "http://localhost:3000/rpc/index_plpgsql" | head -5
```

```html
<!doctype html>
<html>
<head><meta charset="utf-8"><title>todos</title>
<script src="https://unpkg.com/htmx.org@2.0.3"></script></head>
<body hx-headers='{"Accept": "text/html"}'>
```

```bash
# add one the way htmx does — a url-encoded form post — and get back just the fragment
curl -s -H 'Accept: text/html' -d 'task=Ship it' "http://localhost:3000/rpc/add_todo_plpgsql"
```

```html
<li>Ship it</li>
```

Without the header you get PostgREST's normal JSON error/representation — the same function, two
content types, chosen by `Accept`.

> Note: user input is HTML-escaped (`escape_html` / Python's `html.escape`) before it's embedded —
> never concatenate raw user text into HTML. The `safeupdate` guard (server-wide whenever `api` is
> enabled) doesn't affect this example: `add_todo` only does `INSERT`s.
