package functions

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Lint scans dir/*.sql for SECURITY DEFINER hazards and returns human-readable
// warnings (best-effort, per file; no SQL parsing). Each warning is "<file>: <message>".
// A definer function is flagged when it lacks a pinned `SET search_path` (injection
// risk) or an `OWNER TO` reassignment (would be owned by the superuser).
func Lint(dir string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return nil, err
	}
	sort.Strings(matches)
	var warnings []string
	for _, f := range matches {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		lower := strings.ToLower(string(b))
		if !strings.Contains(lower, "security definer") {
			continue
		}
		if !strings.Contains(lower, "set search_path") {
			warnings = append(warnings, f+": SECURITY DEFINER function without a pinned 'SET search_path' (search-path injection risk)")
		}
		if !strings.Contains(lower, "owner to") {
			warnings = append(warnings, f+": SECURITY DEFINER function without 'ALTER FUNCTION ... OWNER TO api_owner' — it would be owned by the superuser (privilege-escalation risk)")
		}
	}
	return warnings, nil
}
