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

func TestEmitSQL_TrustedOnly_WrapsSetRole(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "f.sql"),
		[]byte("CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$BEGIN RETURN 1; END$$;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sql, _, err := EmitSQL(dir, "api_owner")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(sql, "SET ROLE api_owner;\n") {
		t.Fatalf("trusted-only batch must open with SET ROLE:\n%s", sql)
	}
	if !strings.Contains(sql, "RESET ROLE;\n") {
		t.Fatalf("missing RESET ROLE:\n%s", sql)
	}
	// No untrusted functions => no superuser-create-then-reassign machinery.
	if strings.Contains(sql, "_p4a_pre_proc") || strings.Contains(sql, "ALTER FUNCTION") {
		t.Fatalf("trusted-only batch must not emit reassignment machinery:\n%s", sql)
	}
}

func TestEmitSQL_UntrustedCreatedAsSuperuserThenReassigned(t *testing.T) {
	dir := t.TempDir()
	// trusted function first, untrusted (plpython3u) second
	if err := os.WriteFile(filepath.Join(dir, "00_t.sql"),
		[]byte("CREATE FUNCTION t() RETURNS int LANGUAGE plpgsql AS $$BEGIN RETURN 1; END$$;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "10_u.sql"),
		[]byte("CREATE FUNCTION u() RETURNS int LANGUAGE plpython3u AS 'return 1';\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sql, n, err := EmitSQL(dir, "api_owner")
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 files, got %d", n)
	}
	reset := strings.Index(sql, "RESET ROLE;")
	trusted := strings.Index(sql, "CREATE FUNCTION t()")
	untrusted := strings.Index(sql, "CREATE FUNCTION u()")
	reassign := strings.Index(sql, "ALTER FUNCTION")
	if reset < 0 || trusted < 0 || untrusted < 0 || reassign < 0 {
		t.Fatalf("missing required sections (reset=%d trusted=%d untrusted=%d reassign=%d):\n%s",
			reset, trusted, untrusted, reassign, sql)
	}
	// trusted function inside the SET ROLE block (before RESET); untrusted after it (as superuser)
	if !(trusted < reset && reset < untrusted) {
		t.Fatalf("untrusted fn must be created as superuser AFTER RESET ROLE:\n%s", sql)
	}
	// ownership of the untrusted-created function is reassigned to api_owner, after it is created
	if !(untrusted < reassign) {
		t.Fatalf("reassignment must come after the untrusted CREATE:\n%s", sql)
	}
	if !strings.Contains(sql, "OWNER TO %I', r.sig, 'api_owner')") {
		t.Fatalf("reassignment must target the owner role:\n%s", sql)
	}
	if !strings.HasSuffix(sql, "NOTIFY pgrst, 'reload schema';\n") {
		t.Fatalf("missing trailing NOTIFY:\n%s", sql)
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
