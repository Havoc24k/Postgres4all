#!/usr/bin/env bash
# 🔐 auth  (replaces hand-written auth)  — row-level security + JWT, per-user isolation
# Enable: "capabilities": { "api": true, "auth": true }
# Run:    bash examples/auth.sh        (reads JWT_SECRET from build/.env; needs openssl)
set -euo pipefail
BASE=${BASE:-http://localhost:3000}
SECRET=$(grep '^JWT_SECRET=' build/.env | cut -d= -f2-)

# Mint an HS256 JWT for a user, in pure shell: payload carries the PostgREST role + the
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

echo "# alice creates a note (its owner is set from her JWT 'sub' automatically):"
curl -s -X POST "$BASE/notes" -H "Authorization: Bearer $ALICE" \
  -H 'Content-Type: application/json' -d '{"body":"alice private note"}'; echo

echo
echo "# RLS isolation — each user sees only their own rows:"
echo "alice sees: $(curl -s "$BASE/notes" -H "Authorization: Bearer $ALICE")"
echo "bob sees:   $(curl -s "$BASE/notes" -H "Authorization: Bearer $BOB")"
