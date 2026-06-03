#!/usr/bin/env bash
# 🔐 auth (replaces hand-written auth) — see README.md. Reads JWT_SECRET from build/.env; needs openssl.
# Run: bash examples/auth/run.sh
source "$(dirname "$0")/../lib.sh"
HERE=$(dirname "$0")
SECRET=$(grep '^JWT_SECRET=' "$ROOT/build/.env" | cut -d= -f2-)

# Mint an HS256 JWT carrying the PostgREST role + the `sub` claim RLS keys every note's owner to.
mk_jwt() { # mk_jwt <sub>
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  local hdr pay
  hdr=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  pay=$(printf '{"role":"authenticated","sub":"%s"}' "$1" | b64)
  printf '%s.%s.%s' "$hdr" "$pay" \
    "$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -binary -sha256 -hmac "$SECRET" | b64)"
}
ALICE=$(mk_jwt alice); BOB=$(mk_jwt bob)
apply_sql_dir "$HERE"

echo "== no token → no access (anon was never granted the notes table) =="
curl -s -o /dev/null -w '  GET /notes (anonymous) → HTTP %{http_code}\n' "$BASE/notes"

echo "== alice creates a note (owner set from her JWT 'sub' automatically) =="
curl -s -X POST "$BASE/notes" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"body":"alice private note"}'; echo

echo "== RLS isolation via /rpc — PL/pgSQL =="
echo "  alice → $(curl -s -X POST "$BASE/rpc/my_notes_plpgsql" -H "Authorization: Bearer $ALICE")"
echo "  bob   → $(curl -s -X POST "$BASE/rpc/my_notes_plpgsql" -H "Authorization: Bearer $BOB")"
echo "== RLS isolation via /rpc — PL/Python (same isolation; the database enforces it) =="
echo "  alice → $(curl -s -X POST "$BASE/rpc/my_notes_plpython" -H "Authorization: Bearer $ALICE")"
echo "  bob   → $(curl -s -X POST "$BASE/rpc/my_notes_plpython" -H "Authorization: Bearer $BOB")"
