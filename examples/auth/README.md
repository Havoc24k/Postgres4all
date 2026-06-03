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

You also need `openssl` and `jq` on your PATH (to sign tokens and pretty-print responses).

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

### 1. Sign a token for each user

A request authenticates with a **JWT**: three base64url parts — `header.payload.signature` — where the
signature is `HMAC-SHA256(header.payload, JWT_SECRET)`. The payload's `role` becomes the Postgres role
PostgREST switches to, and its `sub` is the identity RLS keys each note's `owner` to. Read the
auto-generated secret from `build/.env` and sign one token per user:

```bash
SECRET=$(grep '^JWT_SECRET=' build/.env | cut -d= -f2-)   # the secret install generated

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }   # base64url, no padding
mk_jwt() {                                                # mk_jwt <username> -> signed token
  local hdr pay
  hdr=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  pay=$(printf '{"role":"authenticated","sub":"%s"}' "$1" | b64)
  printf '%s.%s.%s' "$hdr" "$pay" \
    "$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -binary -sha256 -hmac "$SECRET" | b64)"
}

ALICE=$(mk_jwt alice)
BOB=$(mk_jwt bob)
```

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
