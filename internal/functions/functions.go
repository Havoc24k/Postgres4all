package functions

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// EmitSQL concatenates dir/*.sql in deterministic (byte-order) sort, each as "-- <path>\n<bytes>\n",
// then appends a NOTIFY reload if any files were found. Returns (sql, fileCount, err).
//
// When owner is non-empty, the concatenated function SQL is wrapped in
// `SET ROLE <owner>; … RESET ROLE;` so every object is CREATEd owned by that
// non-superuser role — the idiomatic PostgreSQL way to keep SECURITY DEFINER
// functions from running as the superuser. The trailing NOTIFY runs after
// RESET ROLE (as the connected superuser).
func EmitSQL(dir, owner string) (string, int, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return "", 0, err
	}
	sort.Strings(matches) // LC_ALL=C byte-order, matching bash `printf ... | LC_ALL=C sort`
	if len(matches) == 0 {
		return "", 0, nil
	}
	var b strings.Builder
	if owner != "" {
		b.WriteString("SET ROLE " + owner + ";\n")
	}
	n := 0
	for _, f := range matches {
		bytes, err := os.ReadFile(f)
		if err != nil {
			return "", 0, err
		}
		b.WriteString("-- " + f + "\n")
		b.Write(bytes)
		b.WriteString("\n")
		n++
	}
	if owner != "" {
		b.WriteString("RESET ROLE;\n")
	}
	b.WriteString("NOTIFY pgrst, 'reload schema';\n")
	return b.String(), n, nil
}
