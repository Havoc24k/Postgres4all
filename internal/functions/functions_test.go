package functions

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEmitSQL_Empty(t *testing.T) {
	dir := t.TempDir()
	sql, n, err := EmitSQL(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 || sql != "" {
		t.Fatalf("empty dir: want n=0 sql='', got n=%d sql=%q", n, sql)
	}
}

func TestEmitSQL_SortedConcat(t *testing.T) {
	dir := t.TempDir()
	// intentionally out of order on disk; emit must sort by name
	if err := os.WriteFile(filepath.Join(dir, "zz_z.sql"), []byte("-- Z\nSELECT 2;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "00_a.sql"), []byte("-- A\nSELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sql, n, err := EmitSQL(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 files, got %d", n)
	}
	ia, iz := strings.Index(sql, "-- A"), strings.Index(sql, "-- Z")
	if ia < 0 || iz < 0 || ia > iz {
		t.Fatalf("sorted order broken: A@%d Z@%d", ia, iz)
	}
	if !strings.Contains(sql, "-- "+filepath.Join(dir, "00_a.sql")+"\n-- A\nSELECT 1;\n") {
		t.Fatalf("00_a not concatenated as expected:\n%s", sql)
	}
	if !strings.HasSuffix(sql, "NOTIFY pgrst, 'reload schema';\n") {
		t.Fatalf("missing trailing NOTIFY:\n%s", sql)
	}
}
