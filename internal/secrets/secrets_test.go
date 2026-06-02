package secrets

import "testing"

func TestHex(t *testing.T) {
	s, err := Hex(24)
	if err != nil {
		t.Fatal(err)
	}
	if len(s) != 48 { // 24 bytes -> 48 hex chars
		t.Fatalf("want 48 hex chars, got %d (%q)", len(s), s)
	}
	s2, _ := Hex(24)
	if s == s2 {
		t.Fatalf("two calls should differ")
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			t.Fatalf("non-hex char %q", r)
		}
	}
}
