package generate

import (
	"flag"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/Havoc24k/postgres4all/internal/config"
)

var update = flag.Bool("update", false, "update golden files")

func cfg(caps []string, mut func(*config.Config)) *config.Config {
	c := &config.Config{Capabilities: map[string]bool{}}
	for _, k := range caps {
		c.Capabilities[k] = true
	}
	c.ApplyDefaults()
	c.Postgres.Password = "p" // fixed -> deterministic .env for goldens
	if mut != nil {
		mut(c)
	}
	return c
}

func withAPI(c *config.Config) { c.API.AuthenticatorPassword = "a"; c.API.JWTSecret = "j" }

func TestGenerateGolden(t *testing.T) {
	cases := map[string]*config.Config{
		"minimal":  cfg([]string{"document_store"}, nil),
		"gis":      cfg([]string{"gis"}, nil),
		"api_only": cfg([]string{"api", "auth"}, withAPI), // api on, no read-caps -> no GRANT SELECT table line
		"api_auth": cfg([]string{"document_store", "api", "auth"}, withAPI),
		"full":     cfg(config.Order, withAPI),
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			out := t.TempDir()
			if err := Generate(c, out); err != nil {
				t.Fatal(err)
			}
			compareTree(t, filepath.Join("testdata", "golden", name), out, *update)
		})
	}
}

func compareTree(t *testing.T, goldenDir, gotDir string, doUpdate bool) {
	t.Helper()
	if doUpdate {
		os.RemoveAll(goldenDir)
		copyTree(t, gotDir, goldenDir)
		return
	}
	want, got := listFiles(t, goldenDir), listFiles(t, gotDir)
	if strings.Join(want, ",") != strings.Join(got, ",") {
		t.Fatalf("file set differs:\n want %v\n got  %v", want, got)
	}
	for _, rel := range want {
		w, _ := os.ReadFile(filepath.Join(goldenDir, rel))
		g, err := os.ReadFile(filepath.Join(gotDir, rel))
		if err != nil {
			t.Fatalf("missing generated %s", rel)
		}
		if string(w) != string(g) {
			t.Fatalf("%s differs from golden (run -update to regenerate after a deliberate change)", rel)
		}
	}
}

func listFiles(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	if err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			rel, _ := filepath.Rel(dir, p)
			out = append(out, rel)
		}
		return nil
	}); err != nil {
		t.Fatalf("walk %s: %v", dir, err)
	}
	sort.Strings(out)
	return out
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	if err := filepath.WalkDir(src, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	}); err != nil {
		t.Fatalf("copy %s->%s: %v", src, dst, err)
	}
}
