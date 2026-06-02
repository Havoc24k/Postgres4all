# Go port — Phase 3 (apply-functions) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** `postgres4all apply-functions [--dry-run]` — port the bash `--apply-functions`: concatenate `functions/*.sql` and apply to a running install in one transaction, then reload PostgREST. Replaces the last stub. (Language *generation* already shipped in Phase 1's `Generate`; this phase is only the apply runtime.)

**Spec (this is the design):** Behavior is defined by `setup.sh`'s `emit_functions_sql` + the apply-functions branch and `docs/superpowers/specs/2026-06-02-user-functions-layer-design.md`. Output must be behaviorally equivalent.

**Architecture:** `internal/functions` (pure: read `functions/*.sql`, sorted, concatenate + `NOTIFY pgrst`); `cmd/postgres4all/apply_functions.go` (dry-run prints; live requires an install, reads PG_USER/DB from build/.env, brings up the full stack, applies in one transaction). Reuses `internal/dockerx` (`Compose.ApplySQL`, `Run`, `VolumeName`/`VolumeExists`, `Preflight`, `WaitHealthy`, `EnvValue`).

**Tech Stack:** Go 1.25, cobra. Tests: `go test ./...` (table + golden for the emitted SQL).

**Invariants (match bash exactly):** files sorted deterministically (`LC_ALL=C` → `sort.Strings`); each file emitted as `-- <path>\n` + raw bytes + `\n`; `NOTIFY pgrst, 'reload schema';` appended ONLY if ≥1 file; single `psql --single-transaction` (all-or-nothing); live brings up the FULL stack (so the in-transaction NOTIFY reaches PostgREST); requires an existing install (pgdata volume) + `build/.env`.

---

### Task 1: `internal/functions` — emit concatenated SQL (TDD)

**Files:** Create `internal/functions/functions.go`, `internal/functions/functions_test.go`.

- [ ] **Step 1: Failing test** — `functions_test.go`:
```go
package functions

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEmitSQL_Empty(t *testing.T) {
	dir := t.TempDir()
	sql, n, err := EmitSQL(dir)
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
	os.WriteFile(filepath.Join(dir, "zz_z.sql"), []byte("-- Z\nSELECT 2;\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "00_a.sql"), []byte("-- A\nSELECT 1;\n"), 0o644)
	sql, n, err := EmitSQL(dir)
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
	// each file: "-- <path>\n<content>\n"; header path uses the file path passed in
	if !strings.Contains(sql, "-- "+filepath.Join(dir, "00_a.sql")+"\n-- A\nSELECT 1;\n") {
		t.Fatalf("00_a not concatenated as expected:\n%s", sql)
	}
	if !strings.HasSuffix(sql, "NOTIFY pgrst, 'reload schema';\n") {
		t.Fatalf("missing trailing NOTIFY:\n%s", sql)
	}
}
```
- [ ] **Step 2: Run, verify failure** (`go test ./internal/functions/` — no EmitSQL).
- [ ] **Step 3: Implement `functions.go`**:
```go
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
```
NOTE on header path: bash emits `-- functions/<name>.sql` (the glob path). The Go command passes the
literal `functions` dir, so `filepath.Glob` yields `functions/<name>.sql` and the header matches bash.
The dry-run e2e (Task 3) confirms byte-equivalence against `./setup.sh --apply-functions --dry-run`.
- [ ] **Step 4: Run, verify pass.** `go vet ./...` clean.
- [ ] **Step 5: Commit** `git add internal/functions && git commit -m "feat(go): functions concatenation (sorted + NOTIFY reload)"`

---

### Task 2: `cmd/postgres4all/apply_functions.go` — wire the command (replace stub)

**Files:** Create `cmd/postgres4all/apply_functions.go`; modify `main.go` (replace the `apply-functions` stub).

- [ ] **Step 1: Implement `newApplyFunctionsCmd()`** — flags `--out` (default "build"), `--dir` (default "functions"), `--dry-run`:
```go
package main

import (
	"fmt"

	"github.com/Havoc24k/postgres4all/internal/dockerx"
	"github.com/Havoc24k/postgres4all/internal/functions"
	"github.com/spf13/cobra"
)

func newApplyFunctionsCmd() *cobra.Command {
	var out, dir string
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "apply-functions",
		Short: "Apply functions/*.sql to a running install and reload PostgREST",
		RunE: func(cmd *cobra.Command, args []string) error {
			sql, n, err := functions.EmitSQL(dir)
			if err != nil {
				return err
			}
			if n == 0 {
				fmt.Printf("no functions to apply (%s/ has no .sql files).\n", dir)
				return nil
			}
			if dryRun {
				fmt.Print(sql)
				return nil
			}
			// live apply
			if err := dockerx.Preflight(); err != nil {
				return err
			}
			user := dockerx.EnvValue(out, "POSTGRES_USER")
			db := dockerx.EnvValue(out, "POSTGRES_DB")
			if user == "" || db == "" {
				return fmt.Errorf("%s/.env not found or missing POSTGRES_USER/POSTGRES_DB — run install first", out)
			}
			comp := dockerx.Compose{Dir: out}
			if vol, _ := comp.VolumeName(); !dockerx.VolumeExists(vol) {
				return fmt.Errorf("no existing install found (no pgdata volume); run 'postgres4all install' first")
			}
			// full stack up so the in-transaction NOTIFY reaches a live PostgREST
			if err := comp.Run("up", "-d", "--remove-orphans"); err != nil {
				return err
			}
			if err := comp.WaitHealthy(); err != nil {
				return err
			}
			fmt.Printf("applying %d function file(s)...\n", n)
			if err := comp.ApplySQL(user, db, sql); err != nil {
				return err
			}
			fmt.Println("functions applied; PostgREST schema reloaded (if running).")
			return nil
		},
	}
	cmd.Flags().StringVar(&out, "out", "build", "build directory")
	cmd.Flags().StringVar(&dir, "dir", "functions", "functions directory")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the SQL without applying")
	return cmd
}
```
- [ ] **Step 2:** In `main.go`, replace `root.AddCommand(newStub("apply-functions", "Phase 3"))` with `root.AddCommand(newApplyFunctionsCmd())`.
- [ ] **Step 3: Verify** `go build ./... && go vet ./... && go test ./...` clean. Dry-run byte-parity vs bash:
```bash
go build ./cmd/postgres4all
./postgres4all apply-functions --dry-run > /tmp/go_fn.txt
./setup.sh --apply-functions --dry-run > /tmp/bash_fn.txt
diff /tmp/go_fn.txt /tmp/bash_fn.txt && echo "BYTE-IDENTICAL to bash" || echo "(diff above — inspect; should match)"
rm -f /tmp/go_fn.txt /tmp/bash_fn.txt
```
(Both read the same `functions/` dir; the only shipped file is `example_submit.sql`, so the dry-run output must be byte-identical: `-- functions/example_submit.sql` + content + blank + NOTIFY.)
- [ ] **Step 4: Commit** `git add cmd/postgres4all && git commit -m "feat(go): apply-functions command"`

---

### Task 3: Docker e2e

**Files:** none. I (controller) run it.

- [ ] **Step 1:** Go install document_store+job_queue+api. `./postgres4all apply-functions`. `curl -X POST /rpc/submit_product` (with Content-Type: application/json) → returns product_id+queued; verify the product row + job were written. Re-apply (idempotent). Teardown.

---

### Task 4: README + docs (port complete)

**Files:** Modify `README.md`, `CLAUDE.md`.

- [ ] **Step 1:** README "Go CLI" section: ALL commands ported (`generate`/`install`/`update`/`apply-functions`); the Go binary is now a full replacement for `setup.sh`. Note bash remains for reference/coexistence. Optionally mention retiring `setup.sh` as a future step.
- [ ] **Step 2:** CLAUDE.md Go-port section: `apply-functions` ported (`internal/functions` + `cmd/postgres4all/apply_functions.go`); no stubs remain.
- [ ] **Step 3:** `go test ./...` + `./test/test_functions.sh` green. Commit + push.

---

## Self-Review

**Spec coverage:** functions emit (T1), command incl. live guards + full-stack-up + secret-source-from-.env (T2), e2e (T3), docs (T4).

**Invariants:** sorted concat, `-- <path>` header + bytes + `\n`, NOTIFY only if ≥1 file, single-transaction apply, full-stack up, require volume + build/.env. Dry-run is byte-checked against bash (T2 Step 3).

**Risks:** the `-- <path>` header must use the same path prefix as bash (`functions/<name>.sql`) — the command passes `--dir functions` so Glob yields that prefix; the dry-run diff (T2 S3) catches any mismatch. `ApplySQL` user/db come from `build/.env` (POSTGRES_USER/DB), exercised live in T3.
