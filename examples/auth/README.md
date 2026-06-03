# 🔐 Auth

Postgres itself enforces per-user access over the HTTP API: PostgREST reads a signed JWT, switches to
the matching role, and row-level security scopes every query to the caller's `sub` claim. The result
is owner-isolated notes with no hand-written authorization code — the database decides what each user
can see.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
    "auth": true,
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

You also need `jq` on your PATH (to pretty-print responses).

### Where the JWT secret comes from

Auth hinges on a secret that signs and verifies tokens. You don't configure it: `install`
**auto-generates** it into `build/.env` (mode `0600`). `JWT_SECRET` is what PostgREST verifies every
token against, and `AUTHENTICATOR_PASSWORD` is the password PostgREST logs in with. This example reads
the generated `JWT_SECRET` from `build/.env` to sign Alice's and Bob's tokens — so it works without you
choosing a secret, and the secret is preserved across `./postgres4all update` so tokens stay valid.

## Load the example's functions

Apply this folder's `/rpc` functions with the CLI (it reloads PostgREST's schema cache; give it a
second before calling):

```bash
./postgres4all apply-functions examples/auth
```

That loads [my_notes.plpgsql.sql](my_notes.plpgsql.sql) and [my_notes.plpython.sql](my_notes.plpython.sql).

## Call the API

Run the steps below **from the repo root, in one shell session** (the token variables must persist).
JSON responses are piped through `jq`.

### 1. Mint a token for each user

A request authenticates with a **JWT** whose `sub` claim is the identity RLS keys each note's `owner`
to, and whose `role` claim is the Postgres role PostgREST switches to. `postgres4all mint-token` signs
one (HS256, with the install's auto-generated `JWT_SECRET`) and prints it — short-lived (15m by
default) and **expiring**, so a leaked token doesn't work forever:

```bash
ALICE=$(./postgres4all mint-token --sub alice)
BOB=$(./postgres4all mint-token --sub bob)
```

No `openssl`, no hand-signing. When a token expires, PostgREST replies `401 JWT expired` — re-mint it.
(Set a default lifetime with `security.jwt_ttl`, or bind tokens to this deployment with
`security.jwt_audience` → `PGRST_JWT_AUD`.)

### 2. No token → no access

`anon` (the no-token role) was never granted the `notes` table, so an unauthenticated read is rejected:

```bash
curl -s -o /dev/null -w 'GET /notes (anon) -> HTTP %{http_code}\n' "http://localhost:3000/notes"
```

```text
GET /notes (anon) -> HTTP 401
```

### 3. Alice creates a note

She sends her token; the `owner` column is filled from her JWT `sub` automatically. PostgREST returns
`201 Created` with an empty body:

```bash
curl -s -X POST "http://localhost:3000/notes" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"body":"alice private note"}'
```

### 4. Each user sees only their own rows

The `/rpc` function runs a bare `SELECT * FROM notes`, but RLS — running as the calling role — scopes
the rows to each caller's `sub`. Alice sees her note; Bob sees nothing:

```bash
echo "alice:"; curl -s -X POST "http://localhost:3000/rpc/my_notes_plpgsql" -H "Authorization: Bearer $ALICE" | jq
echo "bob:";   curl -s -X POST "http://localhost:3000/rpc/my_notes_plpgsql" -H "Authorization: Bearer $BOB" | jq
```

```text
alice:
[
  {
    "id": 1,
    "owner": "alice",
    "body": "alice private note",
    "created_at": "2026-06-03T07:07:34.29852+00:00"
  }
]
bob:
[]
```

(timestamps and ids will differ on your run)

The PL/Python variant (`/rpc/my_notes_plpython`) enforces the same isolation — it comes from the
database's RLS policy, not the function language.
