package update

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Havoc24k/postgres4all/internal/config"
)

var flagUpdate = flag.Bool("update", false, "update golden files")

const goldenDir = "testdata/golden"

// readGolden reads a golden file; returns "" if not found.
func readGolden(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(goldenDir, name))
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatalf("read golden %s: %v", name, err)
	}
	return string(b)
}

// writeGolden writes a golden file, creating the directory if needed.
func writeGolden(t *testing.T, name, content string) {
	t.Helper()
	if err := os.MkdirAll(goldenDir, 0o755); err != nil {
		t.Fatalf("mkdir golden dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(goldenDir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write golden %s: %v", name, err)
	}
}

// cfgWithCaps returns a Config with the given capabilities enabled, with seeding on by default.
func cfgWithCaps(caps ...string) *config.Config {
	c := &config.Config{Capabilities: map[string]bool{}}
	for _, k := range caps {
		c.Capabilities[k] = true
	}
	c.ApplyDefaults()
	return c
}

// cfgNoSeed returns a Config with the given capabilities and seeding disabled.
func cfgNoSeed(caps ...string) *config.Config {
	c := cfgWithCaps(caps...)
	f := false
	c.SeedDemoData = &f
	return c
}

// checkGolden compares got to the golden file; updates if -update is given.
func checkGolden(t *testing.T, goldenName, got string) {
	t.Helper()
	if *flagUpdate {
		writeGolden(t, goldenName, got)
		return
	}
	want := readGolden(t, goldenName)
	if got != want {
		t.Errorf("golden mismatch for %s:\nGOT:\n%s\nWANT:\n%s", goldenName, got, want)
	}
}

func TestEmit(t *testing.T) {
	t.Run("add_vector_no_api", func(t *testing.T) {
		cfg := cfgWithCaps("document_store", "vector")
		add := []string{"vector"}
		installed := []string{"document_store"}

		got := EmitAddSQL(cfg, add, installed)
		checkGolden(t, "add_vector_add.sql", got)

		// Pre and remove are empty for this scenario.
		checkGolden(t, "add_vector_pre.sql", "")
		checkGolden(t, "add_vector_remove.sql", "")
	})

	t.Run("add_api_installed_document_store", func(t *testing.T) {
		cfg := cfgWithCaps("document_store", "api")
		add := []string{"api"}
		installed := []string{"document_store"}

		gotPre := EmitPreSQL("a")
		gotAdd := EmitAddSQL(cfg, add, installed)
		checkGolden(t, "add_api_pre.sql", gotPre)
		checkGolden(t, "add_api_add.sql", gotAdd)
		checkGolden(t, "add_api_remove.sql", "")
	})

	t.Run("add_api_and_vector", func(t *testing.T) {
		cfg := cfgWithCaps("document_store", "vector", "api")
		add := []string{"vector", "api"}
		installed := []string{"document_store"}

		gotPre := EmitPreSQL("a")
		gotAdd := EmitAddSQL(cfg, add, installed)
		checkGolden(t, "add_api_vector_pre.sql", gotPre)
		checkGolden(t, "add_api_vector_add.sql", gotAdd)
		checkGolden(t, "add_api_vector_remove.sql", "")

		// Targeted line-order assertion:
		// "CREATE TABLE documents" must precede "GRANT SELECT ON documents"
		lines := strings.Split(gotAdd, "\n")
		createIdx, grantIdx := -1, -1
		for i, l := range lines {
			if strings.Contains(l, "CREATE TABLE documents") {
				createIdx = i
			}
			if strings.Contains(l, "GRANT SELECT ON documents") {
				grantIdx = i
			}
		}
		if createIdx < 0 {
			t.Error("expected 'CREATE TABLE documents' in add_api_vector ADD output")
		}
		if grantIdx < 0 {
			t.Error("expected 'GRANT SELECT ON documents' in add_api_vector ADD output")
		}
		if createIdx >= 0 && grantIdx >= 0 && createIdx >= grantIdx {
			t.Errorf("expected CREATE TABLE documents (line %d) before GRANT SELECT ON documents (line %d)", createIdx, grantIdx)
		}
	})

	t.Run("remove_search_api", func(t *testing.T) {
		cfg := cfgWithCaps("document_store")
		remove := []string{"search", "api"}

		gotRemove := EmitRemoveSQL(cfg, remove)
		checkGolden(t, "remove_search_api_remove.sql", gotRemove)
		checkGolden(t, "remove_search_api_pre.sql", "")
		checkGolden(t, "remove_search_api_add.sql", "")

		// Targeted line-order: REVOKE must precede "DROP ROLE IF EXISTS anon"
		lines := strings.Split(gotRemove, "\n")
		revokeIdx, dropAnonIdx := -1, -1
		for i, l := range lines {
			if strings.Contains(l, "REVOKE SELECT ON TABLES FROM anon") {
				revokeIdx = i
			}
			if l == "DROP ROLE IF EXISTS anon;" {
				dropAnonIdx = i
			}
		}
		if revokeIdx < 0 {
			t.Error("expected REVOKE SELECT ON TABLES FROM anon in remove_search_api REMOVE output")
		}
		if dropAnonIdx < 0 {
			t.Error("expected 'DROP ROLE IF EXISTS anon;' in remove_search_api REMOVE output")
		}
		if revokeIdx >= 0 && dropAnonIdx >= 0 && revokeIdx >= dropAnonIdx {
			t.Errorf("expected REVOKE (line %d) before DROP ROLE anon (line %d)", revokeIdx, dropAnonIdx)
		}
	})

	t.Run("remove_document_store_no_ext", func(t *testing.T) {
		cfg := cfgWithCaps("search")
		remove := []string{"document_store"}

		gotRemove := EmitRemoveSQL(cfg, remove)
		checkGolden(t, "remove_document_store_remove.sql", gotRemove)
		checkGolden(t, "remove_document_store_pre.sql", "")
		checkGolden(t, "remove_document_store_add.sql", "")

		// Assert no DROP EXTENSION lines (document_store owns no extension).
		if strings.Contains(gotRemove, "DROP EXTENSION") {
			t.Errorf("remove_document_store: unexpected DROP EXTENSION in output:\n%s", gotRemove)
		}
	})

	t.Run("remove_auth_api", func(t *testing.T) {
		cfg := cfgWithCaps("document_store")
		remove := []string{"api", "auth"}

		gotRemove := EmitRemoveSQL(cfg, remove)
		checkGolden(t, "remove_auth_api_remove.sql", gotRemove)
		checkGolden(t, "remove_auth_api_pre.sql", "")
		checkGolden(t, "remove_auth_api_add.sql", "")

		// Targeted line-order: notes dropped (auth) before REVOKE (api teardown).
		lines := strings.Split(gotRemove, "\n")
		notesIdx, revokeIdx := -1, -1
		for i, l := range lines {
			if strings.Contains(l, "DROP TABLE IF EXISTS notes") {
				notesIdx = i
			}
			if strings.Contains(l, "REVOKE SELECT ON TABLES FROM anon") {
				revokeIdx = i
			}
		}
		if notesIdx < 0 {
			t.Error("expected DROP TABLE IF EXISTS notes in remove_auth_api REMOVE output")
		}
		if revokeIdx < 0 {
			t.Error("expected REVOKE SELECT ON TABLES FROM anon in remove_auth_api REMOVE output")
		}
		if notesIdx >= 0 && revokeIdx >= 0 && notesIdx >= revokeIdx {
			t.Errorf("expected notes drop (line %d) before REVOKE (line %d)", notesIdx, revokeIdx)
		}
	})
}
