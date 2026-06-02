# Go port — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Go `postgres4all` binary (Cobra CLI) with `generate` (write `build/` from `config.json`, no Docker) and `install` (generate + `docker compose up`) — a behavioral redesign of `setup.sh`'s install path, with typed config, embedded templates, and a single static binary. `setup.sh` and its bash tests stay untouched (coexistence).

**Architecture:** `cmd/postgres4all` (Cobra) → `internal/config` (typed Load+Validate) → `internal/generate` (embedded `text/template` + embedded capability `.sql` fragments → writes `build/`) → `internal/dockerx` (`os/exec` wrappers for `docker compose`). Secrets via `internal/secrets` (`crypto/rand`). Tests: table-driven config tests + golden-file generation tests.

**Tech Stack:** Go 1.23+, `github.com/spf13/cobra`, stdlib (`encoding/json`, `text/template`, `embed`, `crypto/rand`, `os/exec`). Tests via `go test ./...`.

**Spec:** `docs/superpowers/specs/2026-06-02-go-port-phase1-design.md`

**Pinned constants (Go):** `PGMajor="17"`, `PostGISVersion="3.5"`, `PgGraphQLVersion="1.5.11"`, `PostgRESTImage="postgrest/postgrest:v12.2.3"`, `GeneratedImage="postgres4all:generated"`. Canonical capability order: `document_store, job_queue, search, vector, gis, timeseries, dashboards, api, auth`. Extension map: `search→pg_trgm, vector→vector, gis→postgis, api→pg_graphql`. Read-table map: `document_store→products, job_queue→jobs, search→articles, vector→documents, gis→places, timeseries→events, dashboards→event_daily`. Language pkgs (lang-then-version): `postgresql-plperl-17`, `postgresql-plpython3-17`.

**Module path:** `github.com/Havoc24k/postgres4all`. Binary: `postgres4all`.

---

### Task 1: Module + Cobra skeleton (builds, `--version`)

**Files:** Create `go.mod`, `cmd/postgres4all/main.go`. Modify `.gitignore`.

- [ ] **Step 1: Init the module + add cobra**
```bash
cd /home/havoc24k/projects/postgres4all
go mod init github.com/Havoc24k/postgres4all
go get github.com/spf13/cobra@latest
```

- [ ] **Step 2: Write `cmd/postgres4all/main.go`**
```go
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var version = "0.1.0-dev"

func main() {
	root := &cobra.Command{
		Use:           "postgres4all",
		Short:         "Provision a single Postgres that replaces your backend stack",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	// subcommands registered in later tasks
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}
```

- [ ] **Step 3: gitignore the binary + build artifacts**

Append to `.gitignore`:
```
/postgres4all
*.test
```
(`build/` is already ignored.)

- [ ] **Step 4: Verify it builds and runs**

Run: `go build ./... && go run ./cmd/postgres4all --version`
Expected: prints `postgres4all version 0.1.0-dev`, exit 0. `go vet ./...` clean.

- [ ] **Step 5: Commit**
```bash
git add go.mod go.sum cmd/postgres4all/main.go .gitignore
git commit -m "feat(go): module scaffold + cobra root command"
```

---

### Task 2: `internal/config` — typed config, Load + Validate (TDD)

**Files:** Create `internal/config/config.go`, `internal/config/config_test.go`.

- [ ] **Step 1: Write the failing tests**

`internal/config/config_test.go`:
```go
package config

import "testing"

func mustValidate(t *testing.T, c *Config) error { t.Helper(); return c.Validate() }

func TestValidate(t *testing.T) {
	cases := []struct {
		name    string
		caps    map[string]bool
		lang    LanguagesCfg
		wantErr string // substring; "" means valid
	}{
		{"minimal ok", map[string]bool{"document_store": true}, LanguagesCfg{}, ""},
		{"zero caps", map[string]bool{}, LanguagesCfg{}, "at least one capability"},
		{"auth needs api", map[string]bool{"auth": true}, LanguagesCfg{}, "auth' requires 'api"},
		{"dashboards needs timeseries", map[string]bool{"dashboards": true}, LanguagesCfg{}, "dashboards' requires 'timeseries"},
		{"plpython gated", map[string]bool{"document_store": true}, LanguagesCfg{PLPython: true}, "untrusted"},
		{"plpython allowed", map[string]bool{"document_store": true}, LanguagesCfg{PLPython: true, AllowUntrusted: true}, ""},
		{"api+auth ok", map[string]bool{"api": true, "auth": true}, LanguagesCfg{}, ""},
		{"ts+dashboards ok", map[string]bool{"timeseries": true, "dashboards": true}, LanguagesCfg{}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &Config{Capabilities: tc.caps, Languages: tc.lang}
			err := mustValidate(t, c)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want valid, got %v", err)
				}
				return
			}
			if err == nil || !contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestDefaults(t *testing.T) {
	c := &Config{Capabilities: map[string]bool{"document_store": true}}
	c.ApplyDefaults()
	if c.Postgres.User != "postgres" || c.Postgres.DB != "app" {
		t.Fatalf("defaults not applied: %+v", c.Postgres)
	}
	if !c.Seed() {
		t.Fatalf("seed should default true")
	}
}

func contains(s, sub string) bool { return len(sub) == 0 || (len(s) >= len(sub) && indexOf(s, sub) >= 0) }
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
```

- [ ] **Step 2: Run, verify failure** — `go test ./internal/config/` → fails to compile (no Config). Confirm.

- [ ] **Step 3: Implement `internal/config/config.go`**
```go
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

// Order is the canonical capability order used across generation.
var Order = []string{"document_store", "job_queue", "search", "vector", "gis", "timeseries", "dashboards", "api", "auth"}

type Config struct {
	Postgres     PostgresCfg     `json:"postgres"`
	SeedDemoData *bool           `json:"seed_demo_data"`
	Capabilities map[string]bool `json:"capabilities"`
	API          APICfg          `json:"api"`
	Languages    LanguagesCfg    `json:"languages"`
}
type PostgresCfg struct {
	User              string `json:"user"`
	DB                string `json:"db"`
	Password          string `json:"password"`
	PublishExternally bool   `json:"publish_externally"`
}
type APICfg struct {
	AuthenticatorPassword string `json:"authenticator_password"`
	JWTSecret             string `json:"jwt_secret"`
}
type LanguagesCfg struct {
	PLPerl         bool `json:"plperl"`
	PLPython       bool `json:"plpython"`
	AllowUntrusted bool `json:"allow_untrusted"`
}

func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parsing config %s: %w", path, err)
	}
	c.ApplyDefaults()
	return &c, nil
}

func (c *Config) ApplyDefaults() {
	if c.Postgres.User == "" {
		c.Postgres.User = "postgres"
	}
	if c.Postgres.DB == "" {
		c.Postgres.DB = "app"
	}
	if c.Capabilities == nil {
		c.Capabilities = map[string]bool{}
	}
}

func (c *Config) Seed() bool { return c.SeedDemoData == nil || *c.SeedDemoData }

func (c *Config) Enabled(cap string) bool { return c.Capabilities[cap] }

// Validate aggregates all problems into one error.
func (c *Config) Validate() error {
	var problems []string
	known := map[string]bool{}
	for _, k := range Order {
		known[k] = true
	}
	any := false
	for _, k := range Order {
		if c.Capabilities[k] {
			any = true
		}
	}
	if !any {
		problems = append(problems, "at least one capability must be enabled")
	}
	for k := range c.Capabilities {
		if !known[k] {
			problems = append(problems, fmt.Sprintf("unknown capability %q (ignored)", k))
		}
	}
	if c.Capabilities["auth"] && !c.Capabilities["api"] {
		problems = append(problems, "capability 'auth' requires 'api'")
	}
	if c.Capabilities["dashboards"] && !c.Capabilities["timeseries"] {
		problems = append(problems, "capability 'dashboards' requires 'timeseries'")
	}
	if c.Languages.PLPython && !c.Languages.AllowUntrusted {
		problems = append(problems, "language 'plpython' is UNTRUSTED (plpython3u runs with the database OS user's full privileges); set languages.allow_untrusted=true to enable it deliberately")
	}
	if len(problems) > 0 {
		return errors.New("invalid config:\n  - " + strings.Join(problems, "\n  - "))
	}
	return nil
}
```

- [ ] **Step 4: Run, verify pass** — `go test ./internal/config/` → PASS. `go vet ./internal/config/` clean.

- [ ] **Step 5: Commit**
```bash
git add internal/config/
git commit -m "feat(go): typed config with aggregated validation"
```

---

### Task 3: `internal/secrets` — crypto/rand hex (TDD)

**Files:** Create `internal/secrets/secrets.go`, `internal/secrets/secrets_test.go`.

- [ ] **Step 1: Failing test**

`internal/secrets/secrets_test.go`:
```go
package secrets

import "testing"

func TestHex(t *testing.T) {
	s, err := Hex(24)
	if err != nil {
		t.Fatal(err)
	}
	if len(s) != 48 { // 24 bytes -> 48 hex chars
		t.Fatalf("want 48 hex chars, got %d (%q)", len(s), s)
	}
	s2, _ := Hex(24)
	if s == s2 {
		t.Fatalf("two calls should differ")
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			t.Fatalf("non-hex char %q", r)
		}
	}
}
```

- [ ] **Step 2: Run, verify failure** — `go test ./internal/secrets/` → no Hex. Confirm.

- [ ] **Step 3: Implement `internal/secrets/secrets.go`**
```go
package secrets

import (
	"crypto/rand"
	"encoding/hex"
)

// Hex returns nBytes of crypto-random data as a lowercase hex string (len 2*nBytes).
func Hex(nBytes int) (string, error) {
	b := make([]byte, nBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
```

- [ ] **Step 4: Run, verify pass** — `go test ./internal/secrets/` → PASS.

- [ ] **Step 5: Commit**
```bash
git add internal/secrets/
git commit -m "feat(go): crypto/rand hex secrets"
```

---

### Task 4: Embed capability fragments + sync test

**Files:** Create `internal/generate/capabilities/` (copies of `init/capabilities/*.sql`), `internal/generate/embed.go`, `internal/generate/embed_test.go`.

- [ ] **Step 1: Copy the fragments**
```bash
mkdir -p internal/generate/capabilities
cp init/capabilities/*.sql internal/generate/capabilities/
ls internal/generate/capabilities/ | wc -l   # expect 22 (8 schema + 6 seed + 8 drop)
```

- [ ] **Step 2: `internal/generate/embed.go`**
```go
package generate

import "embed"

//go:embed capabilities/*.sql
var capabilitiesFS embed.FS

//go:embed templates/*.tmpl
var templatesFS embed.FS
```
(Note: `templates/*.tmpl` is created in Task 5; to keep this task compiling on its own, create an empty placeholder `internal/generate/templates/.keep` is NOT enough for `go:embed` — instead, defer the `templates` embed line to Task 5 and embed only `capabilities/*.sql` here.)

REVISED `embed.go` for Task 4 (templates embed added in Task 5):
```go
package generate

import "embed"

//go:embed capabilities/*.sql
var capabilitiesFS embed.FS
```

- [ ] **Step 3: Sync test — embedded copies must match `init/capabilities/`**

`internal/generate/embed_test.go`:
```go
package generate

import (
	"os"
	"path/filepath"
	"testing"
)

// The embedded capability fragments must stay byte-identical to init/capabilities/
// until the bash setup.sh is retired (single source of truth during the port).
func TestCapabilitiesInSyncWithInit(t *testing.T) {
	entries, err := capabilitiesFS.ReadDir("capabilities")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("no embedded capability fragments")
	}
	for _, e := range entries {
		name := e.Name()
		embedded, err := capabilitiesFS.ReadFile("capabilities/" + name)
		if err != nil {
			t.Fatal(err)
		}
		// repo root is two levels up from internal/generate
		onDisk, err := os.ReadFile(filepath.Join("..", "..", "init", "capabilities", name))
		if err != nil {
			t.Fatalf("init/capabilities/%s missing: %v", name, err)
		}
		if string(embedded) != string(onDisk) {
			t.Fatalf("embedded capabilities/%s differs from init/capabilities/%s — re-copy", name, name)
		}
	}
}
```

- [ ] **Step 4: Run, verify pass** — `go test ./internal/generate/` → PASS (sync holds).

- [ ] **Step 5: Commit**
```bash
git add internal/generate/capabilities/ internal/generate/embed.go internal/generate/embed_test.go
git commit -m "feat(go): embed capability SQL fragments + init sync test"
```

---

### Task 5: `internal/generate` — templates + Generate() (golden-file TDD)

**Files:** Create `internal/generate/templates/{Dockerfile.tmpl,docker-compose.yml.tmpl,env.tmpl}`, `internal/generate/generate.go`, `internal/generate/generate_test.go`, `internal/generate/testdata/golden/...`. Modify `internal/generate/embed.go` (add templates embed).

- [ ] **Step 1: Author the three templates**

`internal/generate/templates/Dockerfile.tmpl`:
```
{{- if .GIS}}FROM postgis/postgis:{{.PGMajor}}-{{.PostGISVersion}}
{{- else}}FROM postgres:{{.PGMajor}}
{{- end}}
ARG PG_MAJOR={{.PGMajor}}
{{- if .Vector}}
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-{{.PGMajor}}-pgvector ca-certificates wget && rm -rf /var/lib/apt/lists/*
{{- end}}
{{- if .API}}
{{- if not .Vector}}
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget && rm -rf /var/lib/apt/lists/*
{{- end}}
RUN set -eux; arch="$(dpkg --print-architecture)"; url="https://github.com/supabase/pg_graphql/releases/download/v{{.PgGraphQL}}/pg_graphql-v{{.PgGraphQL}}-pg{{.PGMajor}}-${arch}-linux-gnu.deb"; wget -q -O /tmp/pg_graphql.deb "$url"; apt-get update; apt-get install -y --no-install-recommends /tmp/pg_graphql.deb; rm -f /tmp/pg_graphql.deb; rm -rf /var/lib/apt/lists/*
{{- end}}
{{- if .LangPkgs}}
RUN apt-get update && apt-get install -y --no-install-recommends{{range .LangPkgs}} {{.}}{{end}} && rm -rf /var/lib/apt/lists/*
{{- end}}
COPY init/ /docker-entrypoint-initdb.d/
```

`internal/generate/templates/env.tmpl`:
```
POSTGRES_USER={{.User}}
POSTGRES_PASSWORD={{.Password}}
POSTGRES_DB={{.DB}}
{{- if .API}}
AUTHENTICATOR_PASSWORD={{.AuthPw}}
JWT_SECRET={{.JWT}}
{{- end}}
```

`internal/generate/templates/docker-compose.yml.tmpl`:
```
services:
  db:
    build: .
    image: {{.Image}}
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
{{- if .API}}
      AUTHENTICATOR_PASSWORD: ${AUTHENTICATOR_PASSWORD}
{{- end}}
    ports:
      - "{{.Bind}}5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 12
{{- if .API}}
  postgrest:
    image: {{.PostgRESTImage}}
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://authenticator:${AUTHENTICATOR_PASSWORD}@db:5432/${POSTGRES_DB}
      PGRST_DB_SCHEMAS: public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
    ports:
      - "{{.Bind}}3000:3000"
    depends_on:
      db:
        condition: service_healthy
{{- end}}
volumes:
  pgdata:
```
Add the templates embed back to `embed.go`:
```go
//go:embed templates/*.tmpl
var templatesFS embed.FS
```

- [ ] **Step 2: Write the golden test harness FIRST (failing)**

`internal/generate/generate_test.go`:
```go
package generate

import (
	"flag"
	"os"
	"path/filepath"
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
	if mut != nil {
		mut(c)
	}
	return c
}

func TestGenerateGolden(t *testing.T) {
	cases := map[string]*config.Config{
		"minimal":  cfg([]string{"document_store"}, nil),
		"api_auth": cfg([]string{"document_store", "api", "auth"}, func(c *config.Config) {
			c.Postgres.Password = "p"; c.API.AuthenticatorPassword = "a"; c.API.JWTSecret = "j"
		}),
		"gis":      cfg([]string{"gis"}, nil),
		"full":     cfg(config.Order, func(c *config.Config) {
			c.Postgres.Password = "p"; c.API.AuthenticatorPassword = "a"; c.API.JWTSecret = "j"
		}),
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			out := t.TempDir()
			if err := Generate(c, out); err != nil {
				t.Fatal(err)
			}
			goldenDir := filepath.Join("testdata", "golden", name)
			compareTree(t, goldenDir, out, *update)
		})
	}
}

// compareTree walks want (golden) and got dirs; with update, rewrites golden from got.
func compareTree(t *testing.T, goldenDir, gotDir string, doUpdate bool) {
	t.Helper()
	if doUpdate {
		os.RemoveAll(goldenDir)
		copyTree(t, gotDir, goldenDir)
		return
	}
	wantFiles := listFiles(t, goldenDir)
	gotFiles := listFiles(t, gotDir)
	if len(wantFiles) != len(gotFiles) {
		t.Fatalf("file set differs:\n want %v\n got  %v", wantFiles, gotFiles)
	}
	for _, rel := range wantFiles {
		w, _ := os.ReadFile(filepath.Join(goldenDir, rel))
		g, err := os.ReadFile(filepath.Join(gotDir, rel))
		if err != nil {
			t.Fatalf("missing generated %s", rel)
		}
		if string(w) != string(g) {
			t.Fatalf("%s differs from golden", rel)
		}
	}
}
```
Plus small helpers `listFiles`, `copyTree` (walk with `filepath.WalkDir`, collect relative paths sorted; copy preserving subdirs). Implement them in the test file. NOTE: secrets make `.env` non-deterministic — so for golden cases that enable `api`, the config MUST set explicit passwords/JWT (as above), and `Generate` must use config-provided secrets verbatim (only generate when empty). The golden `.env` then has the fixed values. For non-api cases without a password, `Generate` would random-generate POSTGRES_PASSWORD → non-deterministic; therefore golden cases ALWAYS set `Postgres.Password` (minimal/gis set it too). Update the `cfg` calls to set `Password:"p"` for every case to keep `.env` deterministic.

- [ ] **Step 3: Run, verify failure** — `go test ./internal/generate/` → fails (no `Generate`). Confirm.

- [ ] **Step 4: Implement `internal/generate/generate.go`**

Implement `Generate(c *config.Config, outDir string) error` that:
1. wipes+creates `outDir` and `outDir/init`.
2. builds a Dockerfile view-model (GIS/Vector/API bools, LangPkgs slice, version consts) and renders `Dockerfile.tmpl` → `outDir/Dockerfile`.
3. writes `outDir/init/01-extensions.sql`: `CREATE EXTENSION IF NOT EXISTS` for pg_trgm/vector/postgis/pg_graphql per enabled caps, then plperl/plpython3u per languages.
4. writes `outDir/init/02-schema.sql`: for each cap in canonical order (excluding api), read `capabilities/<cap>.schema.sql` from `capabilitiesFS`, then `<cap>.seed.sql` if `c.Seed()` and it exists.
5. writes `outDir/init/04-meta.sql`: schema + table + INSERT per enabled cap.
6. if api: write `outDir/init/00-roles.sh` (constant content) and `outDir/init/03-api-grants.sql` (grants scoped to enabled read-tables + notes CRUD if auth + graphql grants + alter default).
7. resolves secrets: Password/AuthPw/JWT from config, else `secrets.Hex`. Renders `env.tmpl` → `outDir/.env`, then `os.Chmod(outDir/.env, 0o600)`.
8. renders `docker-compose.yml.tmpl` with `Bind = "127.0.0.1:"` unless `PublishExternally`, `Image`, `PostgRESTImage`.

Use the constants from the plan header. The 00-roles.sh and 03-grants content should mirror the bash-generated equivalents (behavioral parity). Provide them as Go string constants / a small builder. (The implementer mirrors `build/init/00-roles.sh` and `03-api-grants.sql` produced by the current `setup.sh` for the same config — generate one with bash and diff during development.)

- [ ] **Step 5: Generate goldens, then run**

Run: `go test ./internal/generate/ -run TestGenerateGolden -update` to write goldens. INSPECT the goldens (`git diff --stat`, read `testdata/golden/full/Dockerfile` and `init/*`) and confirm they match what `setup.sh --dry-run` produces for the same configs (diff against a bash-generated `build/`). Then `go test ./internal/generate/` → PASS.

- [ ] **Step 6: Commit**
```bash
git add internal/generate/
git commit -m "feat(go): build/ generation via embedded templates + golden tests"
```

---

### Task 6: `internal/dockerx` — exec wrappers

**Files:** Create `internal/dockerx/dockerx.go` (+ a light test for arg construction).

- [ ] **Step 1: Implement**
```go
package dockerx

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

type Compose struct{ Dir string } // Dir holds build/ (contains .env + docker-compose.yml)

func (c Compose) baseArgs() []string {
	return []string{"compose", "--env-file", c.Dir + "/.env", "-f", c.Dir + "/docker-compose.yml"}
}

func (c Compose) Run(args ...string) error {
	cmd := exec.Command("docker", append(c.baseArgs(), args...)...)
	cmd.Stdout, cmd.Stderr, cmd.Stdin = os.Stdout, os.Stderr, os.Stdin
	return cmd.Run()
}

// VolumeName parses `docker compose config --format json` for the pgdata volume's real name.
func (c Compose) VolumeName() (string, error) {
	out, err := exec.Command("docker", append(c.baseArgs(), "config", "--format", "json")...).Output()
	if err != nil {
		return "", fmt.Errorf("docker compose config: %w", err)
	}
	var parsed struct {
		Volumes map[string]struct{ Name string `json:"name"` } `json:"volumes"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return "", err
	}
	return parsed.Volumes["pgdata"].Name, nil
}

func VolumeExists(name string) bool {
	if name == "" {
		return false
	}
	return exec.Command("docker", "volume", "inspect", name).Run() == nil
}

// Preflight verifies docker + docker compose are available.
func Preflight() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("missing required tool: docker")
	}
	if exec.Command("docker", "compose", "version").Run() != nil {
		return fmt.Errorf("missing required tool: docker compose")
	}
	return nil
}
```

- [ ] **Step 2: Verify it builds** — `go build ./... && go vet ./...` clean. (No Docker needed; behavior covered by Task 7 e2e.)

- [ ] **Step 3: Commit**
```bash
git add internal/dockerx/
git commit -m "feat(go): docker compose exec wrappers"
```

---

### Task 7: Wire `generate` + `install` subcommands (+ stubs)

**Files:** Create `cmd/postgres4all/generate.go`, `cmd/postgres4all/install.go`, `cmd/postgres4all/stubs.go`. Modify `cmd/postgres4all/main.go` (register).

- [ ] **Step 1: `generate` subcommand** — `cmd/postgres4all/generate.go`
```go
package main

import (
	"fmt"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/generate"
	"github.com/spf13/cobra"
)

func newGenerateCmd() *cobra.Command {
	var cfgPath, out string
	cmd := &cobra.Command{
		Use:   "generate",
		Short: "Generate the build/ directory from config.json (no Docker)",
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := config.Load(cfgPath)
			if err != nil {
				return err
			}
			if err := c.Validate(); err != nil {
				return err
			}
			if err := generate.Generate(c, out); err != nil {
				return err
			}
			fmt.Printf("generated %s/ for: %v\n", out, enabledList(c))
			return nil
		},
	}
	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "path to config.json")
	cmd.Flags().StringVar(&out, "out", "build", "output directory")
	return cmd
}

func enabledList(c *config.Config) []string {
	var e []string
	for _, k := range config.Order {
		if c.Enabled(k) {
			e = append(e, k)
		}
	}
	return e
}
```

- [ ] **Step 2: `install` subcommand** — `cmd/postgres4all/install.go`
```go
package main

import (
	"fmt"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/dockerx"
	"github.com/Havoc24k/postgres4all/internal/generate"
	"github.com/spf13/cobra"
)

func newInstallCmd() *cobra.Command {
	var cfgPath, out string
	cmd := &cobra.Command{
		Use:   "install",
		Short: "Generate build/ and start the stack with docker compose",
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := config.Load(cfgPath)
			if err != nil {
				return err
			}
			if err := c.Validate(); err != nil {
				return err
			}
			if err := generate.Generate(c, out); err != nil {
				return err
			}
			if err := dockerx.Preflight(); err != nil {
				return err
			}
			comp := dockerx.Compose{Dir: out}
			if vol, _ := comp.VolumeName(); dockerx.VolumeExists(vol) {
				return fmt.Errorf("an install already exists (volume %s). Use 'postgres4all update' (Phase 2) or 'docker compose -f %s/docker-compose.yml down -v' to start over", vol, out)
			}
			fmt.Println("starting stack...")
			return comp.Run("up", "--build")
		},
	}
	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "path to config.json")
	cmd.Flags().StringVar(&out, "out", "build", "output directory")
	return cmd
}
```

- [ ] **Step 3: Stubs for later phases** — `cmd/postgres4all/stubs.go`
```go
package main

import (
	"fmt"

	"github.com/spf13/cobra"
)

func newStub(use, phase string) *cobra.Command {
	return &cobra.Command{
		Use:   use,
		Short: fmt.Sprintf("(%s — not yet ported; use ./setup.sh for now)", phase),
		RunE: func(cmd *cobra.Command, args []string) error {
			return fmt.Errorf("%q is implemented in %s of the Go port; for now use ./setup.sh %s", use, phase, use)
		},
	}
}
```

- [ ] **Step 4: Register in `main.go`**

Replace the `// subcommands registered in later tasks` line with:
```go
	root.AddCommand(newGenerateCmd())
	root.AddCommand(newInstallCmd())
	root.AddCommand(newStub("update", "Phase 2"))
	root.AddCommand(newStub("apply-functions", "Phase 3"))
```

- [ ] **Step 5: Verify build + generate parity vs bash**

Run:
```bash
go build ./cmd/postgres4all
printf '{"capabilities":{"document_store":true,"api":true,"auth":true},"postgres":{"password":"p"},"api":{"authenticator_password":"a","jwt_secret":"j"}}' > /tmp/c.json
./postgres4all generate --config /tmp/c.json --out /tmp/gobuild
# compare structure to bash:
./setup.sh --dry-run /tmp/c.json >/dev/null   # wait — bash needs config.json; instead:
cp /tmp/c.json config.json; ./setup.sh --dry-run >/dev/null; rm -f config.json
diff <(cd /tmp/gobuild && find . -type f | sort) <(cd build && find . -type f | sort)
```
Expected: same file set (Dockerfile, docker-compose.yml, .env, init/00-04). Inspect `.env` keys and compose services match. `go test ./...` → PASS. `go vet ./...` clean.

- [ ] **Step 6: Commit**
```bash
git add cmd/postgres4all/
git commit -m "feat(go): generate + install subcommands; stubs for update/apply-functions"
```

---

### Task 8: End-to-end (Docker) + docs

**Files:** none for e2e; modify `README.md` (note the Go binary as the emerging interface).

- [ ] **Step 1: E2E — build, generate, boot, verify a capability**
```bash
go build ./cmd/postgres4all
printf '{"capabilities":{"document_store":true,"job_queue":true,"api":true},"postgres":{"password":"go_e2e"}}' > config.json
./postgres4all generate --config config.json
DOCKER_BUILDKIT=0 docker build -t postgres4all:generated build/   # old buildx on this host
docker compose --env-file build/.env -f build/docker-compose.yml up -d --no-build
# wait healthy, then:
docker compose --env-file build/.env -f build/docker-compose.yml exec -T db psql -U postgres -d app -tAc "SELECT name FROM products WHERE attributes @> '{\"wireless\":true}';"  # -> Mechanical Keyboard
sleep 3; curl -s http://127.0.0.1:3000/products | head -c 60; echo
docker compose --env-file build/.env -f build/docker-compose.yml down -v
rm -f config.json
```
Expected: image builds (Go-generated Dockerfile), stack boots, JSONB query returns the seeded row, PostgREST serves `/products`. Confirms the Go-generated `build/` is Docker-valid and behavior-equivalent. (`install` would do generate+up in one step on a host with buildx ≥ 0.17.)

- [ ] **Step 2: README — note the Go interface (coexistence)**

Add a short note under a new `## Go CLI (in progress)` subsection near the top of README, e.g.:
```markdown
## Go CLI (in progress)

A Go rewrite is underway. `postgres4all generate` / `postgres4all install` already replace the
install path (`go build ./cmd/postgres4all`); `update` and `apply-functions` are still served by
`./setup.sh` during the port. The bash tool and the Go binary produce a compatible `build/`.
```

- [ ] **Step 3: Verify + commit**

Run: `go test ./...` and `./test/test_setup.sh` (bash still green). Then:
```bash
git add README.md
git commit -m "docs: note the in-progress Go CLI alongside setup.sh"
```

---

## Self-Review

**Spec coverage:** module+cobra (T1), typed config+validate (T2), secrets (T3), embed+sync (T4), generation+golden (T5), dockerx (T6), generate+install+stubs (T7), e2e+docs (T8). All Phase-1 spec sections map to tasks.

**Placeholder scan:** the only deferred content is `update`/`apply-functions` (intentional stubs, Phase 2/3). Task 5 Step 4 describes the 00-roles/03-grants content as "mirror the bash output" rather than inlining 40 lines — the implementer generates the bash equivalent and matches it; the golden files (committed in Step 5) become the concrete spec. No "TBD".

**Type/name consistency:** `config.Config`/`Order`/`Enabled`/`Seed`/`ApplyDefaults`/`Validate`; `secrets.Hex`; `generate.Generate`, `capabilitiesFS`/`templatesFS`; `dockerx.Compose`/`VolumeName`/`VolumeExists`/`Preflight`; cmd constructors `newGenerateCmd`/`newInstallCmd`/`newStub`. Module path `github.com/Havoc24k/postgres4all` used in all imports.

**Known risks to validate during execution:**
- `.env` non-determinism breaks golden tests unless every golden config sets explicit secrets — Task 5 Step 2 mandates `Password`/`AuthPw`/`JWT` on all golden cases.
- `go:embed templates/*.tmpl` requires the `templates/` dir to exist with ≥1 file at build time — Task 5 creates the templates before adding the embed line (Task 4 embeds only `capabilities`).
- The 00-roles/03-grants byte-parity with bash is the main correctness risk — Task 5 Step 5 mandates diffing the goldens against `setup.sh --dry-run` output.
- `go.sum` must be committed (Task 1) for reproducible cobra builds.
