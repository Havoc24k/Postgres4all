package jwt

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestSignHS256(t *testing.T) {
	secret := "s3cret"
	claims := map[string]any{"role": "authenticated", "sub": "alice", "exp": 1893456000}

	tok, err := SignHS256(secret, claims)
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("want 3 dot-separated parts, got %d (%q)", len(parts), tok)
	}

	// header is the standard HS256 JWT header
	hdr, _ := base64.RawURLEncoding.DecodeString(parts[0])
	if string(hdr) != `{"alg":"HS256","typ":"JWT"}` {
		t.Errorf("bad header: %s", hdr)
	}

	// signature must verify (this is exactly what PostgREST recomputes)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	wantSig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if parts[2] != wantSig {
		t.Errorf("signature mismatch:\n got  %s\n want %s", parts[2], wantSig)
	}

	// payload round-trips to the claims
	payload, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var got map[string]any
	if err := json.Unmarshal(payload, &got); err != nil {
		t.Fatal(err)
	}
	if got["sub"] != "alice" || got["role"] != "authenticated" {
		t.Errorf("claims mismatch: %v", got)
	}
	if _, ok := got["exp"]; !ok {
		t.Errorf("exp claim missing")
	}
}
