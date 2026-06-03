# 🔐 Auth (replaces hand-written auth)

This capability lets Postgres itself enforce per-user access over the HTTP API: PostgREST reads a signed JWT, switches to the matching role, and row-level security scopes every query to the caller's `sub` claim. The result is owner-isolated notes with no hand-written authorization code — the database decides what each user can see.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "auth": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

This example also mints HS256 JWTs with `openssl` and reads `JWT_SECRET` from `build/.env`, so you need `openssl` on your PATH and a built stack (`build/.env` present).

## Run it

```bash
bash examples/auth/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`, from the repo root and in **one shell session** (the token variables below must persist across the steps).

## Mint two user tokens

Row-level security keys each note's `owner` to the JWT `sub` claim, so the by-hand steps need two signed tokens. Mint them the way `run.sh` does — an HS256 JWT signed with `JWT_SECRET` from `build/.env`:

```bash
SECRET=$(grep '^JWT_SECRET=' build/.env | cut -d= -f2-)
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mk_jwt() {  # mk_jwt <sub>
  local hdr pay
  hdr=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  pay=$(printf '{"role":"authenticated","sub":"%s"}' "$1" | b64)
  printf '%s.%s.%s' "$hdr" "$pay" \
    "$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -binary -sha256 -hmac "$SECRET" | b64)"
}
ALICE=$(mk_jwt alice); BOB=$(mk_jwt bob)
```

## No token, no access

`anon` was never granted the `notes` table, so an unauthenticated read is rejected before any rows are considered.

```bash
curl -s -o /dev/null -w '  GET /notes (anonymous) → HTTP %{http_code}\n' "http://localhost:3000/notes"
```

```text
  GET /notes (anonymous) → HTTP 401
```

## Alice creates a note

Alice posts as the `authenticated` role; the `owner` column is filled from her JWT `sub` automatically, and PostgREST returns `201 Created` with no representation requested (an empty body).

```bash
curl -s -X POST "http://localhost:3000/notes" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"body":"alice private note"}'; echo
```

```text
(empty body — PostgREST returns 201 Created with no representation)
```

## RLS isolation via /rpc — PL/pgSQL

The function does a bare `SELECT * FROM notes`; it needs to be a function only so PostgREST can expose it at `/rpc`, while RLS — running as the calling role — scopes the rows to each caller's `sub`.

```bash
echo "  alice → $(curl -s -X POST "http://localhost:3000/rpc/my_notes_plpgsql" -H "Authorization: Bearer $ALICE")"
echo "  bob   → $(curl -s -X POST "http://localhost:3000/rpc/my_notes_plpgsql" -H "Authorization: Bearer $BOB")"
```

```json
  alice → [{"id":1,"owner":"alice","body":"alice private note","created_at":"2026-06-03T06:32:42.780625+00:00"}]
  bob   → []
```

(timestamps and ids will differ on your run)

## RLS isolation via /rpc — PL/Python

The same read in PL/Python returns identical rows: the isolation comes from the database's RLS policy, not the function language.

```bash
echo "  alice → $(curl -s -X POST "http://localhost:3000/rpc/my_notes_plpython" -H "Authorization: Bearer $ALICE")"
echo "  bob   → $(curl -s -X POST "http://localhost:3000/rpc/my_notes_plpython" -H "Authorization: Bearer $BOB")"
```

```json
  alice → [{"id":1,"owner":"alice","body":"alice private note","created_at":"2026-06-03T06:32:42.780625+00:00"}]
  bob   → []
```

(timestamps and ids will differ on your run)

## The two implementations

[my_notes.plpgsql.sql](my_notes.plpgsql.sql) and [my_notes.plpython.sql](my_notes.plpython.sql) return identically — both lean on RLS to enforce per-user isolation rather than coding it themselves. In a real project these would live in `functions/` and be applied to a running install with `./postgres4all apply-functions`.
