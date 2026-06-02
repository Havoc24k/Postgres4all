#!/usr/bin/env bash
# 🔐 auth (replaces hand-written auth) — row-level security + JWT, per-user isolation over the API.
# Enable: { "api": true, "auth": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/auth.sh        (reads JWT_SECRET from build/.env; needs openssl)
source "$(dirname "$0")/lib.sh"
SECRET=$(grep '^JWT_SECRET=' "$ROOT/build/.env" | cut -d= -f2-)

# Mint an HS256 JWT for a user, in pure shell: the payload carries the PostgREST role and the
# `sub` claim that row-level security keys every note's owner to.
mk_jwt() { # mk_jwt <sub>
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  local hdr pay
  hdr=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  pay=$(printf '{"role":"authenticated","sub":"%s"}' "$1" | b64)
  printf '%s.%s.%s' "$hdr" "$pay" \
    "$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -binary -sha256 -hmac "$SECRET" | b64)"
}
ALICE=$(mk_jwt alice)
BOB=$(mk_jwt bob)

echo "# No token → no access (anon was never granted the notes table):"
curl -s -o /dev/null -w '  GET /notes (anonymous) → HTTP %{http_code}\n' "$BASE/notes"

echo
echo "# alice creates a note (its owner is set from her JWT 'sub' automatically):"
curl -s -X POST "$BASE/notes" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"body":"alice private note"}'; echo

# A function that reads "my" notes — same RLS applies because it runs as the calling role.
# Shown in BOTH languages; each caller sees only their own rows, enforced by the database.
define_sql <<'SQL'
CREATE OR REPLACE FUNCTION my_notes_plpgsql()
RETURNS SETOF notes LANGUAGE plpgsql STABLE AS $fn$
BEGIN RETURN QUERY SELECT * FROM notes; END;
$fn$;

CREATE OR REPLACE FUNCTION my_notes_plpython()
RETURNS SETOF notes LANGUAGE plpython3u AS $fn$
return plpy.execute("SELECT * FROM notes")
$fn$;
SQL

echo
echo "# RLS isolation via an /rpc function — PL/pgSQL:"
echo "  alice → $(curl -s -X POST "$BASE/rpc/my_notes_plpgsql" -H "Authorization: Bearer $ALICE")"
echo "  bob   → $(curl -s -X POST "$BASE/rpc/my_notes_plpgsql" -H "Authorization: Bearer $BOB")"
echo "# …and PL/Python (same isolation — the database enforces it, not the function):"
echo "  alice → $(curl -s -X POST "$BASE/rpc/my_notes_plpython" -H "Authorization: Bearer $ALICE")"
echo "  bob   → $(curl -s -X POST "$BASE/rpc/my_notes_plpython" -H "Authorization: Bearer $BOB")"
