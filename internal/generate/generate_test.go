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

func TestGeneratePreservesSecrets(t *testing.T) {
	c := cfg([]string{"document_store", "api", "auth"}, nil)
	out := t.TempDir()
	read := func() (pg, auth, jwt string) {
		b, _ := os.ReadFile(filepath.Join(out, ".env"))
		for _, line := range strings.Split(string(b), "\n") {
			if k, v, ok := strings.Cut(line, "="); ok {
				switch k {
				case "POSTGRES_PASSWORD":
					pg = v
				case "AUTHENTICATOR_PASSWORD":
					auth = v
				case "JWT_SECRET":
					jwt = v
				}
			}
		}
		return
	}
	if err := Generate(c, out); err != nil {
		t.Fatal(err)
	}
	pg1, a1, j1 := read()
	if a1 == "" || j1 == "" {
		t.Fatalf("api secrets missing from .env: auth=%q jwt=%q", a1, j1)
	}
	if err := Generate(c, out); err != nil { // regenerate into the same dir
		t.Fatal(err)
	}
	pg2, a2, j2 := read()
	if pg1 != pg2 || a1 != a2 || j1 != j2 {
		t.Fatalf("secrets changed on regenerate:\n  pg   %q -> %q\n  auth %q -> %q\n  jwt  %q -> %q", pg1, pg2, a1, a2, j1, j2)
	}
}

func TestGenerateGolden(t *testing.T) {
	cases := map[string]*config.Config{
		"minimal":  cfg([]string{"document_store"}, nil),
		"gis":      cfg([]string{"gis"}, nil),
		"api_only": cfg([]string{"api", "auth"}, nil), // api on, no read-caps -> no GRANT SELECT table line
		"api_auth": cfg([]string{"document_store", "api", "auth"}, nil),
		"full":     cfg(config.Order, nil),
		"languages": cfg([]string{"document_store"}, func(c *config.Config) {
			c.Languages.PLPerl = true
			c.Languages.PLPython = true
			c.Languages.AllowUntrusted = true
		}),
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
		if !d.IsDir() && d.Name() != ".env" { // .env holds random secrets; checked by TestEnvSecretSizes
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

func TestEnvSecretSizes(t *testing.T) {
	// api enabled, NO secrets in config -> Generate must random-fill .env with pinned hex sizes.
	c := &config.Config{Capabilities: map[string]bool{"document_store": true, "api": true}}
	c.ApplyDefaults()
	out := t.TempDir()
	if err := Generate(c, out); err != nil {
		t.Fatal(err)
	}
	env, err := os.ReadFile(filepath.Join(out, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{"POSTGRES_PASSWORD": 48, "AUTHENTICATOR_PASSWORD": 32, "JWT_SECRET": 96}
	for _, line := range strings.Split(string(env), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		if n, found := want[k]; found {
			if len(v) != n {
				t.Errorf("%s: want %d hex chars, got %d (%q)", k, n, len(v), v)
			}
			for _, r := range v {
				if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
					t.Errorf("%s: non-hex char %q", k, r)
				}
			}
			delete(want, k)
		}
	}
	if len(want) != 0 {
		t.Fatalf("missing env keys: %v", want)
	}
}

func TestComposeNamingCustom(t *testing.T) {
	c := cfg([]string{"document_store", "api", "auth"}, func(c *config.Config) {
		c.Compose = config.ComposeCfg{
			Project:  "myapp",
			Services: map[string]string{"db": "postgres", "postgrest": "rest"},
		}
	})
	out := t.TempDir()
	if err := Generate(c, out); err != nil {
		t.Fatal(err)
	}
	compose, _ := os.ReadFile(filepath.Join(out, "docker-compose.yml"))
	cs := string(compose)
	for _, want := range []string{"name: myapp\n", "\n  postgres:\n", "\n  rest:\n", "@postgres:5432", "depends_on:\n      postgres:"} {
		if !strings.Contains(cs, want) {
			t.Errorf("compose missing %q\n---\n%s", want, cs)
		}
	}
	if strings.Contains(cs, "\n  db:\n") {
		t.Errorf("compose should not contain default 'db' service:\n%s", cs)
	}
	env, _ := os.ReadFile(filepath.Join(out, ".env"))
	for _, want := range []string{"P4A_DB_SERVICE=postgres", "P4A_POSTGREST_SERVICE=rest"} {
		if !strings.Contains(string(env), want) {
			t.Errorf(".env missing %q\n---\n%s", want, string(env))
		}
	}
}

func TestComposeNamingDefaultsUnchanged(t *testing.T) {
	c := cfg([]string{"document_store", "api", "auth"}, nil)
	out := t.TempDir()
	if err := Generate(c, out); err != nil {
		t.Fatal(err)
	}
	compose, _ := os.ReadFile(filepath.Join(out, "docker-compose.yml"))
	cs := string(compose)
	if strings.Contains(cs, "name:") {
		t.Errorf("default compose must not emit a name: line\n%s", cs)
	}
	if !strings.Contains(cs, "\n  db:\n") || !strings.Contains(cs, "\n  postgrest:\n") {
		t.Errorf("default services missing:\n%s", cs)
	}
	env, _ := os.ReadFile(filepath.Join(out, ".env"))
	if strings.Contains(string(env), "P4A_DB_SERVICE") {
		t.Errorf("default .env must not contain P4A_DB_SERVICE:\n%s", string(env))
	}
}
