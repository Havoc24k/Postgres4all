# Go port — Phase 2 (update delta engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** `postgres4all update [--allow-drop]` (+ `--dry-run --installed "<csv>"`) — port the bash `--update` delta engine to Go, behaviorally equivalent, replacing the Phase-1 stub.

**Architecture:** new `internal/update` (pure delta logic + SQL emission, unit-tested); extend `internal/dockerx` (ApplySQL/QueryInstalled/WaitHealthy/BuildUp/UpDB/RestartPostgrest/EnvValue); `cmd/postgres4all/update.go` orchestrates the phased execution. Shared capability maps + fragment reader exported from `internal/generate`.

**Tech Stack:** Go 1.25, cobra. Tests: `go test ./...` (table + golden for delta SQL).

**Spec:** `docs/superpowers/specs/2026-06-03-go-port-phase2-design.md`
**Behavioral reference (READ IT):** `setup.sh` functions `emit_pre_sql` / `emit_add_sql` / `emit_remove_sql` and the UPDATE branch; `test/test_update.sh` (30 assertions) is the scenario list to mirror; `docs/superpowers/specs/2026-06-02-capability-update-path-design.md`.

**Invariants to preserve (the hardened bash fixes):** grant-after-create (api-add grants only INSTALLED read-tables; the per-cap add loop grants NEW tables); reverse-canonical drop order; api-removal REVOKEs the superuser-owned default-priv ACL before DROP ROLE anon; Phase-0 idempotent roles (DO-block `IF NOT EXISTS pg_roles`); secret preservation; `--remove-orphans`; full-stack up so NOTIFY reaches PostgREST.

---

### Task 1: Export shared capability maps + fragment reader from `internal/generate`

**Files:** Modify `internal/generate/generate.go` (export maps; add reader). No behavior change.

- [ ] **Step 1**: In `generate.go`, rename the unexported `extensionMap`→`ExtensionMap`, `readTableMap`→`ReadTableMap` (exported), update all internal references. Add:
```go
// ReadCapabilitySQL returns an embedded capability fragment, e.g. ReadCapabilitySQL("document_store.schema.sql").
func ReadCapabilitySQL(name string) ([]byte, error) {
	return capabilitiesFS.ReadFile("capabilities/" + name)
}
```
- [ ] **Step 2**: `go build ./... && go test ./... && go vet ./...` → all green (pure rename + addition; goldens unchanged).
- [ ] **Step 3**: Commit `git add internal/generate && git commit -m "refactor(go): export capability maps + fragment reader for reuse"`

---

### Task 2: `internal/update` — Delta computation (TDD)

**Files:** Create `internal/update/delta.go`, `internal/update/delta_test.go`.

- [ ] **Step 1: Failing test** — `internal/update/delta_test.go`:
```go
package update

import (
	"strings"
	"testing"

	"github.com/Havoc24k/postgres4all/internal/config"
)

func target(caps ...string) *config.Config {
	c := &config.Config{Capabilities: map[string]bool{}}
	for _, k := range caps {
		c.Capabilities[k] = true
	}
	c.ApplyDefaults()
	return c
}

func TestDelta(t *testing.T) {
	cases := []struct {
		name              string
		tgt               []string
		installed         []string
		wantAdd, wantRem  string
	}{
		{"add vector", []string{"document_store", "vector"}, []string{"document_store"}, "vector", ""},
		{"remove search", []string{"document_store"}, []string{"document_store", "search"}, "", "search"},
		{"add api+cap order", []string{"document_store", "search", "api"}, []string{"document_store"}, "search,api", ""},
		{"remove canonical", []string{"document_store"}, []string{"document_store", "search", "api"}, "", "search,api"},
		{"noop", []string{"document_store"}, []string{"document_store"}, "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			add, rem := Delta(target(tc.tgt...), tc.installed)
			if strings.Join(add, ",") != tc.wantAdd {
				t.Errorf("add: want %q got %q", tc.wantAdd, strings.Join(add, ","))
			}
			if strings.Join(rem, ",") != tc.wantRem {
				t.Errorf("rem: want %q got %q", tc.wantRem, strings.Join(rem, ","))
			}
		})
	}
}
```
- [ ] **Step 2: Run, verify failure** (`go test ./internal/update/` — no Delta).
- [ ] **Step 3: Implement `internal/update/delta.go`**:
```go
package update

import "github.com/Havoc24k/postgres4all/internal/config"

// Delta returns capabilities to add (in target, not installed) and remove (installed, not in target),
// both in canonical order.
func Delta(target *config.Config, installed []string) (add, remove []string) {
	inst := map[string]bool{}
	for _, c := range installed {
		if c != "" {
			inst[c] = true
		}
	}
	for _, c := range config.Order {
		t := target.Enabled(c)
		if t && !inst[c] {
			add = append(add, c)
		}
		if !t && inst[c] {
			remove = append(remove, c)
		}
	}
	return add, remove
}

// Contains reports membership; exported so update.go and emit.go can reuse it.
func Contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
```
- [ ] **Step 4: Run, verify pass.** `go vet ./...` clean.
- [ ] **Step 5: Commit** `git add internal/update && git commit -m "feat(go): update delta computation"`

---

### Task 3: `internal/update` — delta SQL emission (golden TDD)

**Files:** Create `internal/update/emit.go`, `internal/update/emit_test.go`, `internal/update/testdata/golden/`.

READ `setup.sh`'s `emit_pre_sql`/`emit_add_sql`/`emit_remove_sql` as the byte-level behavioral reference (run `./setup.sh --update --dry-run --installed '<csv>' <cfg>` for several scenarios to capture exact expected SQL; the Go output should match those SQL bodies — header lines differ, none here since these are not the init `-- generated by` files; the delta SQL has no header).

- [ ] **Step 1: Implement `emit.go`** with three functions (signatures):
```go
package update

import (
	"fmt"
	"strings"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/generate"
)

// EmitPreSQL: idempotent role-chain creation, emitted only when "api" is being added, BEFORE the rebuild.
// authPw is the AUTHENTICATOR_PASSWORD value (from build/.env); single-quotes are doubled for the SQL literal.
func EmitPreSQL(authPw string) string { ... }

// EmitAddSQL: extensions + schema fragments (+seed if cfg.Seed()) + grants + meta inserts for the ADD set.
// Grant rule: if api is newly added, grant the ALREADY-INSTALLED read tables in the api block; the per-cap
// loop grants NEW tables AFTER their CREATE (api present or added). installed = the installed set.
func EmitAddSQL(cfg *config.Config, add, installed []string) string { ... }

// EmitRemoveSQL: drop fragments + DROP EXTENSION (per cap) in REVERSE canonical order, then for api removal:
// ALTER DEFAULT PRIVILEGES ... REVOKE ... FROM anon; DROP OWNED BY ...; DROP ROLE ...; DROP EXTENSION pg_graphql;
// then meta deletes.
func EmitRemoveSQL(cfg *config.Config, remove []string) string { ... }
```
Implementation notes (mirror bash EXACTLY — these are the hardened invariants):
- Use `generate.ReadCapabilitySQL("<cap>.schema.sql"/.seed.sql/.drop.sql)`, `generate.ExtensionMap`, `generate.ReadTableMap`, `config.Order`.
- `EmitPreSQL`: three `DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='...') THEN CREATE ROLE ... END IF; END $$;` for anon/authenticated/authenticator (authenticator with `PASSWORD '<authPw doubled-quotes>'`), then `GRANT anon, authenticated TO authenticator;`.
- **Fragment fidelity (CRITICAL whitespace rule):** for every schema/seed/drop fragment, `sb.Write(bytes)` then `sb.WriteString("\n")` — the fragment bytes already end in one `\n`, and the extra `\n` reproduces bash's `cat file; echo` trailing-blank-line. Match `generate.go` writeSchema exactly. The delta SQL has NO `-- generated` header.
- `EmitAddSQL(cfg, add, installed)`: `apiAdded := Delta-style contains(add,"api")`; `apiEff := cfg.Enabled("api")`. Build an `installed` set/`Contains(installed, …)`.
  - **If apiAdded** (api block): `CREATE EXTENSION IF NOT EXISTS pg_graphql;`, `GRANT USAGE ON SCHEMA public TO anon, authenticated;`. Then the read-table grant — **membership keyed on `installed`, NOT cfg**: iterate `config.Order`, skip any cap absent from `generate.ReadTableMap` (this naturally drops `api` AND `auth`), include only caps with `Contains(installed, cap)`, join with `", "`; emit `GRANT SELECT ON <list> TO anon, authenticated;` **only if the list is non-empty**. Then `if Contains(installed, "auth")`: `GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;`. Then the two graphql grants + `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;`.
  - Then for each cap in canonical order (api excluded) that is in `add`: `CREATE EXTENSION IF NOT EXISTS <ext>` if `generate.ExtensionMap[cap]` exists; schema fragment (+`\n`); seed (+`\n`) if `cfg.Seed()` and the `<cap>.seed.sql` fragment exists; if `apiEff`: `GRANT SELECT ON <ReadTableMap[cap]> TO anon, authenticated;` when the cap has a read table, and for `cap=="auth"` `GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;`; then `INSERT INTO p4a_meta.capabilities (cap) VALUES ('<cap>') ON CONFLICT (cap) DO NOTHING;`.
  - Then if apiAdded: `INSERT INTO p4a_meta.capabilities (cap) VALUES ('api') ON CONFLICT (cap) DO NOTHING;`.
- `EmitRemoveSQL`: api_removed = "api" in remove. For caps in REVERSE schemaOrder that are in `remove`: drop fragment; `DROP EXTENSION IF EXISTS <ext>` if owns one; `DELETE FROM p4a_meta.capabilities WHERE cap='<cap>';`. Then if api_removed: `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM anon;`, `DROP OWNED BY authenticator, anon, authenticated;`, `DROP ROLE IF EXISTS authenticator/authenticated/anon;`, `DROP EXTENSION IF EXISTS pg_graphql;`, `DELETE FROM p4a_meta.capabilities WHERE cap='api';`.

- [ ] **Step 2: Golden tests** — `emit_test.go` with cases mirroring `test_update.sh`:
  - add vector (no api): EmitAddSQL has `CREATE EXTENSION ... vector`, `CREATE TABLE documents`, seed, meta insert; NO grant (api off); golden.
  - add api+search installed document_store,api: api NOT in add → per-cap grants `articles` after its create; golden asserts create-before-grant ordering (awk-style line check in the test).
  - api newly added (installed document_store): EmitPreSQL has idempotent role DO-blocks; EmitAddSQL has pg_graphql + grant on products (installed) + meta insert api.
  - remove search,api (allow-drop): EmitRemoveSQL has DROP TABLE articles CASCADE, DROP EXTENSION pg_trgm, REVOKE before DROP ROLE anon, single pg_graphql drop, reverse order (dashboards/event_daily before events if both).
  - remove document_store (no owned extension): EmitRemoveSQL has `DROP TABLE IF EXISTS products CASCADE` and ZERO `DROP EXTENSION` lines (document_store owns no extension).
  - remove auth+api (allow-drop): `notes` dropped (auth, first in the reverse loop) BEFORE the api REVOKE / DROP OWNED / DROP ROLE block.
  Use golden files for full SQL bodies + targeted line-order assertions for create-before-grant and revoke-before-drop. **Generate the goldens by capturing bash output** as the oracle for these delta-SQL cases (the delta SQL is unambiguously defined by `setup.sh --update --dry-run --installed '<csv>' <cfg> [--allow-drop]`): run bash for each scenario, save its PRE/REMOVE/ADD section bodies, and make the Go golden match (these have no header, so byte-fidelity IS the target here — unlike the Phase-1 init files). `-update` flag to (re)generate; inspect; commit.
- [ ] **Step 3: Run** `go test ./internal/update/ -run TestEmit -update`, INSPECT goldens (paste add-api and remove-api), then `go test ./internal/update/` → PASS. `go vet ./...` clean.
- [ ] **Step 4: Commit** `git add internal/update && git commit -m "feat(go): update delta SQL emission (pre/add/remove)"`

---

### Task 4: Extend `internal/dockerx` for live update

**Files:** Modify `internal/dockerx/dockerx.go`.

- [ ] **Step 1: Add methods/functions**:
```go
// ApplySQL pipes sql to `compose exec -T db psql -v ON_ERROR_STOP=1 --single-transaction -U user -d db`.
func (c Compose) ApplySQL(user, db, sql string) error {
	cmd := exec.Command("docker", append(c.baseArgs(), "exec", "-T", "db",
		"psql", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-U", user, "-d", db)...)
	cmd.Stdin = strings.NewReader(sql)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

// QueryInstalled reads the comma-joined installed capability set from p4a_meta.capabilities.
func (c Compose) QueryInstalled(user, db string) (string, error) {
	out, err := exec.Command("docker", append(c.baseArgs(), "exec", "-T", "db",
		"psql", "-tAqc", "SELECT string_agg(cap, ',') FROM p4a_meta.capabilities", "-U", user, "-d", db)...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// HasMetaTable reports whether p4a_meta.capabilities exists.
func (c Compose) HasMetaTable(user, db string) bool {
	out, _ := exec.Command("docker", append(c.baseArgs(), "exec", "-T", "db",
		"psql", "-tAqc", "SELECT to_regclass('p4a_meta.capabilities')", "-U", user, "-d", db)...).Output()
	return strings.TrimSpace(string(out)) == "p4a_meta.capabilities"
}

func (c Compose) UpDB() error      { return c.Run("up", "-d", "--remove-orphans", "db") }
func (c Compose) RestartPostgrest() { _ = c.Run("restart", "postgrest") }

// WaitHealthy polls the db container health for up to ~60s.
func (c Compose) WaitHealthy() error {
	for i := 0; i < 30; i++ {
		cid, _ := exec.Command("docker", append(c.baseArgs(), "ps", "-q", "db")...).Output()
		id := strings.TrimSpace(string(cid))
		if id != "" {
			h, _ := exec.Command("docker", "inspect", "-f", "{{.State.Health.Status}}", id).Output()
			if strings.TrimSpace(string(h)) == "healthy" {
				return nil
			}
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("database did not become healthy")
}

// BuildUp: up -d --build --remove-orphans, with a DOCKER_BUILDKIT=0 legacy-build fallback for old buildx.
func (c Compose) BuildUp() error {
	cmd := exec.Command("docker", append(c.baseArgs(), "up", "-d", "--build", "--remove-orphans")...)
	var stderr strings.Builder
	cmd.Stdout = os.Stdout
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderr) // stream live AND capture for buildx detection
	if err := cmd.Run(); err == nil {
		return nil
	} else if !strings.Contains(strings.ToLower(stderr.String()), "buildx") {
		return err // already streamed to os.Stderr
	}
	// fallback: legacy build then up --no-build
	bld := exec.Command("docker", "build", "-t", generate.GeneratedImage, c.Dir)
	bld.Env = append(os.Environ(), "DOCKER_BUILDKIT=0")
	bld.Stdout, bld.Stderr = os.Stdout, os.Stderr
	if err := bld.Run(); err != nil {
		return err
	}
	return c.Run("up", "-d", "--no-build", "--remove-orphans")
}

// EnvValue reads KEY=value from build/.env (Dir/.env).
func EnvValue(dir, key string) string {
	b, err := os.ReadFile(dir + "/.env")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok && k == key {
			return strings.TrimRight(v, "\r") // defensively strip a stray CR (CRLF .env)
		}
	}
	return ""
}
```
Add imports `io`, `strings`, `time`, and `github.com/Havoc24k/postgres4all/internal/generate` (for `GeneratedImage`, already exported at `generate.go:21` — just import it). Verify the exec/Env wiring compiles; the import graph is acyclic (generate imports only config+secrets).
- [ ] **Step 2**: `go build ./... && go vet ./...` clean. (Docker behavior covered by Task 6 e2e.)
- [ ] **Step 3: Commit** `git add internal/dockerx internal/generate && git commit -m "feat(go): dockerx live-update helpers (ApplySQL, QueryInstalled, BuildUp, WaitHealthy)"`

---

### Task 5: `cmd/postgres4all/update.go` — wire the command (replace stub)

**Files:** Create `cmd/postgres4all/update.go`; modify `cmd/postgres4all/main.go` (replace the `update` stub registration with `newUpdateCmd()`).

- [ ] **Step 1: Implement `newUpdateCmd()`** with flags `--config` (default config.json), `--out` (build), `--allow-drop`, `--dry-run`, `--installed`. RunE orchestration:
  1. `config.Load` + `Validate` (target).
  2. Secret preservation: read existing `build/.env` (if present) via `dockerx.EnvValue(out, "POSTGRES_PASSWORD"/"AUTHENTICATOR_PASSWORD"/"JWT_SECRET")`; if a config secret is empty and an old value exists, set it into the in-memory config (`c.Postgres.Password`, `c.API.AuthenticatorPassword`, `c.API.JWTSecret`) so `Generate` reuses it.
  3. `generate.Generate(c, out)` (regenerates build/ for the target, with reused secrets).
  4. Determine installed: if `--installed` given use it; else require docker (`dockerx.Preflight`), require the pgdata volume exists (`Compose.VolumeName`+`VolumeExists`, else error "no existing install — run install first"), `UpDB`+`WaitHealthy`, ensure `HasMetaTable`, `QueryInstalled`.
  5. `add, remove := update.Delta(c, splitCSV(installed))`. Print `Update plan:` ADD/REMOVE.
  6. If `len(remove)>0 && !allowDrop` → error listing remove caps. If both empty → "already up to date", return nil.
  7. `apiAdded := update.Contains(add, "api")`. If `--dry-run`: require `--installed` (else error "—dry-run requires --installed"). Then print the THREE section headers **UNCONDITIONALLY**, gating only the bodies (mirrors bash setup.sh:514-519):
     ```go
     fmt.Println("===== PRE =====")
     if apiAdded { fmt.Print(update.EmitPreSQL(authPw)) }
     fmt.Println("===== REMOVE =====")
     if len(remove) > 0 { fmt.Print(update.EmitRemoveSQL(c, remove)) }
     fmt.Println("===== ADD =====")
     if len(add) > 0 { fmt.Print(update.EmitAddSQL(c, add, installedList)) }
     return nil
     ```
  8. Live: `comp.UpDB()`+`WaitHealthy`; if apiAdded → `comp.ApplySQL(user, db, update.EmitPreSQL(authPw))`; if `len(remove)>0` → `comp.ApplySQL(user, db, update.EmitRemoveSQL(c, remove))`; `comp.BuildUp()`+`WaitHealthy`; if `len(add)>0` → `comp.ApplySQL(user, db, update.EmitAddSQL(c, add, installedList))` and if apiAdded `comp.RestartPostgrest()`. Then re-query and print the completion line (separate query — NOT QueryInstalled, which uses a different separator/order):
     ```go
     // print: update complete. installed: <SELECT string_agg(cap, ', ' ORDER BY cap) FROM p4a_meta.capabilities>
     ```
  - `authPw` = AUTHENTICATOR_PASSWORD from `build/.env` read via `dockerx.EnvValue(out, "AUTHENTICATOR_PASSWORD")` **AFTER** `Generate` (Generate wrote it). `user`/`db` = `c.Postgres.User`/`c.Postgres.DB`. `installedList` = the `[]string` parsed from the installed CSV.
- [ ] **Step 2**: In `main.go`, replace `root.AddCommand(newStub("update", "Phase 2"))` with `root.AddCommand(newUpdateCmd())`.
- [ ] **Step 3: Verify** `go build ./... && go vet ./...` clean. Dry-run parity vs bash:
```bash
go build ./cmd/postgres4all
printf '{"capabilities":{"document_store":true,"vector":true,"api":true},"postgres":{"password":"p"},"api":{"authenticator_password":"a","jwt_secret":"j"}}' > /tmp/u.json
./postgres4all update --dry-run --installed 'document_store' --config /tmp/u.json
# compare PRE/ADD sections semantically to: ./setup.sh --update --dry-run --installed 'document_store' /tmp/u.json --allow-drop
rm -f /tmp/u.json
```
Confirm the Go dry-run shows the plan + PRE (idempotent roles) + ADD (pg_graphql, grant products, create documents then grant documents, meta inserts). `go test ./...` → PASS.
- [ ] **Step 4: Commit** `git add cmd/postgres4all && git commit -m "feat(go): update command (delta engine + phased execution)"`

---

### Task 6: Docker e2e (data preservation)

**Files:** none. I (the executor/controller) run this.

- [ ] **Step 1**: Fresh install via Go: `document_store` + `job_queue` + `api`, sentinel row inserted.
- [ ] **Step 2**: `./postgres4all update` adding `vector` → assert sentinel survives, `documents` exists + seeded, p4a_meta updated. (BuildUp's buildkit fallback handles old buildx.)
- [ ] **Step 3**: `./postgres4all update` adding `search` (api already on) → PostgREST serves `/articles`; grant-ordering OK (no abort).
- [ ] **Step 4**: `./postgres4all update --allow-drop` removing `vector` → `documents` gone, sentinel intact, pgvector dropped.
- [ ] **Step 5**: idempotent re-run → "already up to date". Teardown `down -v`.

---

### Task 7: README + docs

**Files:** Modify `README.md`, `CLAUDE.md`.

- [ ] **Step 1**: Update the README "## Go CLI (in progress)" section: `update` is now ported (`./postgres4all update [--allow-drop]`); only `apply-functions` remains on bash. Keep the coexistence note.
- [ ] **Step 2**: CLAUDE.md: note the Go `update` lives in `internal/update` (Delta + Emit*) + `cmd/postgres4all/update.go`, behaviorally mirroring bash `--update`.
- [ ] **Step 3**: `go test ./...` + `./test/test_update.sh` green. Commit.

---

## Self-Review

**Spec coverage:** shared maps (T1), Delta (T2), emit pre/add/remove with hardened invariants (T3), dockerx live helpers (T4), update command + secret preservation + phased execution + dry-run (T5), data-preservation e2e (T6), docs (T7).

**Invariants:** grant-after-create, revoke-before-drop, reverse-order drops, idempotent Phase-0 roles, secret reuse, --remove-orphans, full-stack up — all called out in T3/T5 and golden/e2e-locked.

**Risks to validate:** the emit_* SQL must byte-match the bash behavior (golden against bash output once); `BuildUp` stderr buffering vs streaming (acceptable); `authPw` must be read AFTER Generate writes build/.env; `EnvValue` cut on first `=` only (`cut -d= -f2-` equivalent — use `strings.Cut` which splits on first `=`, correct).
