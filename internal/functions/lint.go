package functions

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Lint scans dir/*.sql and warns about the one SECURITY DEFINER hazard that is the
// function author's responsibility: a missing pinned `SET search_path` (a search-path
// injection risk that cannot be auto-injected reliably). Ownership is NOT checked here —
// apply-functions creates functions under `SET ROLE api_owner`, so a definer can never
// silently end up superuser-owned. Best-effort, per file, no SQL parsing; SQL line
// comments (-- to end of line) are stripped before scanning. Each warning is
// "<file>: <message>".
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
		scan := stripComments(string(b))
		if !strings.Contains(scan, "security definer") {
			continue
		}
		if !strings.Contains(scan, "set search_path") {
			warnings = append(warnings, f+": SECURITY DEFINER function without a pinned 'SET search_path' (search-path injection risk)")
		}
	}
	return warnings, nil
}

// stripComments lowercases src and removes SQL line comments (-- to end of line)
// so commented-out statements don't satisfy the lint's substring checks.
func stripComments(src string) string {
	var b strings.Builder
	for line := range strings.SplitSeq(src, "\n") {
		if i := strings.Index(line, "--"); i >= 0 {
			line = line[:i]
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return strings.ToLower(b.String())
}
