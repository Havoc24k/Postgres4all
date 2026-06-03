// Package jwt signs HS256 JSON Web Tokens — the symmetric scheme PostgREST verifies with JWT_SECRET.
package jwt

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
)

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// SignHS256 returns a compact HS256 JWT (header.payload.signature) for the given claims,
// signed with secret. The signature is HMAC-SHA256 over "header.payload", exactly what
// PostgREST recomputes with its PGRST_JWT_SECRET.
func SignHS256(secret string, claims map[string]any) (string, error) {
	header := b64([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payloadJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signing := header + "." + b64(payloadJSON)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signing))
	return signing + "." + b64(mac.Sum(nil)), nil
}
