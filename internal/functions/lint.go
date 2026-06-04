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
// SQL line comments (-- to end of line) are stripped before scanning so that
// commented-out statements never satisfy a check.
//
// Scope is deliberately file-level, not per-function: the checks assume the
// project convention of one SECURITY DEFINER function per file. A file mixing an
// owned and an unowned definer would not be flagged. That is acceptable because
// this lint is an advisory nudge, not the privilege boundary — the actual
// guarantee is the powerless api_owner role plus the explicit OWNER TO in each
// file. Parsing per-function scope is intentionally out of scope (YAGNI here).
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
		if !strings.Contains(scan, "owner to") {
			warnings = append(warnings, f+": SECURITY DEFINER function without 'ALTER FUNCTION ... OWNER TO api_owner' — it would be owned by the superuser (privilege-escalation risk)")
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
