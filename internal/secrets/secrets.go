package secrets

import (
	"crypto/rand"
	"encoding/hex"
)

// Hex returns nBytes of crypto-random data as a lowercase hex string (len 2*nBytes).
func Hex(nBytes int) (string, error) {
	b := make([]byte, nBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
