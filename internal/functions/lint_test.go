package functions

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestLint(t *testing.T) {
	cases := []struct {
		dir       string
		wantCount int
		wantSub   string
	}{
		{"clean", 0, ""},
		{"unpinned", 1, "search_path"},
		{"unowned", 1, "OWNER TO"},
		{"none", 0, ""},
	}
	for _, tc := range cases {
		t.Run(tc.dir, func(t *testing.T) {
			got, err := Lint(filepath.Join("testdata", "lint", tc.dir))
			if err != nil {
				t.Fatalf("Lint: %v", err)
			}
			if len(got) != tc.wantCount {
				t.Fatalf("got %d warnings %v, want %d", len(got), got, tc.wantCount)
			}
			if tc.wantSub != "" && !strings.Contains(got[0], tc.wantSub) {
				t.Errorf("warning %q missing %q", got[0], tc.wantSub)
			}
		})
	}
}
