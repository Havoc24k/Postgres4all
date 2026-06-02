package functions

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// EmitSQL concatenates dir/*.sql in deterministic (byte-order) sort, each as "-- <path>\n<bytes>\n",
// then appends a NOTIFY reload if any files were found. Returns (sql, fileCount, err).
func EmitSQL(dir string) (string, int, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return "", 0, err
	}
	sort.Strings(matches) // LC_ALL=C byte-order, matching bash `printf ... | LC_ALL=C sort`
	var b strings.Builder
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
	if n > 0 {
		b.WriteString("NOTIFY pgrst, 'reload schema';\n")
	}
	return b.String(), n, nil
}
