# Scoped SECURITY DEFINER Owner + apply-functions Lint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `SECURITY DEFINER` functions a powerless `api_owner` role instead of running as the superuser, and warn (in `apply-functions`) when a definer function would be left superuser-owned or has an unpinned search_path.

**Architecture:** Generate an `api_owner` role (NOLOGIN NOINHERIT, api-gated) on fresh install and idempotently on `update`. Each `SECURITY DEFINER` `.sql` file explicitly reassigns ownership to `api_owner` and grants it only the table privileges that one function needs. A new best-effort `functions.Lint` flags definer hazards; `apply-functions` prints the warnings and applies anyway (warn-only).

**Tech Stack:** Go (stdlib + cobra), Postgres SQL, golden-file tests (`-update` flag in both `internal/generate` and `internal/update`).

**Spec:** `docs/superpowers/specs/2026-06-04-security-definer-owner-design.md`

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `internal/functions/lint.go` | Best-effort definer lint | Create |
| `internal/functions/lint_test.go` | Lint table test | Create |
| `internal/functions/testdata/lint/{clean,unpinned,unowned,none}/*.sql` | Lint fixtures | Create |
| `cmd/postgres4all/apply_functions.go` | Wire lint into the command (warn to stderr) | Modify |
| `internal/generate/generate.go` | Add `api_owner` to roles + USAGE grant | Modify |
| `internal/generate/testdata/golden/{api_only,api_auth,full}/init/{00-roles.sh,03-api-grants.sql}` | Generate goldens | Regenerate |
| `internal/update/emit.go` | `api_owner` in PreSQL / add / remove | Modify |
| `internal/update/emit_test.go` | Assert PreSQL creates `api_owner` | Modify |
| `internal/update/testdata/golden/*api*` | Update goldens | Regenerate |
| `functions/example_submit.sql` | Reassign owner + scoped grant + comment | Modify |
| `examples/job_queue/claim_job.plpgsql.sql` | Reassign owner + scoped grant | Modify |
| `examples/job_queue/claim_job.plpython.sql` | Reassign owner + scoped grant | Modify |

---

## Task 1: `functions.Lint`

**Files:**
- Create: `internal/functions/lint.go`
- Test: `internal/functions/lint_test.go`
- Create fixtures: `internal/functions/testdata/lint/{clean,unpinned,unowned,none}/f.sql`

- [ ] **Step 1: Create the lint fixtures**

`internal/functions/testdata/lint/clean/f.sql`:
```sql
CREATE FUNCTION f() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT 1 $$;
ALTER FUNCTION f() OWNER TO api_owner;
```

`internal/functions/testdata/lint/unpinned/f.sql`:
```sql
CREATE FUNCTION f() RETURNS void LANGUAGE sql SECURITY DEFINER AS $$ SELECT 1 $$;
ALTER FUNCTION f() OWNER TO api_owner;
```

`internal/functions/testdata/lint/unowned/f.sql`:
```sql
CREATE FUNCTION f() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT 1 $$;
```

`internal/functions/testdata/lint/none/f.sql`:
```sql
CREATE FUNCTION f() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;
```

- [ ] **Step 2: Write the failing test**

`internal/functions/lint_test.go`:
```go
package functions

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestLint(t *testing.T) {
	cases := []struct {
		dir       string
		wantCount int
		wantSub   string
	}{
		{"clean", 0, ""},
		{"unpinned", 1, "search_path"},
		{"unowned", 1, "OWNER TO"},
		{"none", 0, ""},
	}
	for _, tc := range cases {
		t.Run(tc.dir, func(t *testing.T) {
			got, err := Lint(filepath.Join("testdata", "lint", tc.dir))
			if err != nil {
				t.Fatalf("Lint: %v", err)
			}
			if len(got) != tc.wantCount {
				t.Fatalf("got %d warnings %v, want %d", len(got), got, tc.wantCount)
			}
			if tc.wantSub != "" && !strings.Contains(got[0], tc.wantSub) {
				t.Errorf("warning %q missing %q", got[0], tc.wantSub)
			}
		})
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/functions/ -run TestLint`
Expected: FAIL — `undefined: Lint`.

- [ ] **Step 4: Write the implementation**

`internal/functions/lint.go`:
```go
package functions

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Lint scans dir/*.sql for SECURITY DEFINER hazards and returns human-readable
// warnings (best-effort, per file; no SQL parsing). Each warning is "<file>: <message>".
// A definer function is flagged when it lacks a pinned `SET search_path` (injection
// risk) or an `OWNER TO` reassignment (would be owned by the superuser).
func Lint(dir string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return nil, err
	}
	sort.Strings(matches)
	var warnings []string
	for _, f := range matches {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		lower := strings.ToLower(string(b))
		if !strings.Contains(lower, "security definer") {
			continue
		}
		if !strings.Contains(lower, "set search_path") {
			warnings = append(warnings, f+": SECURITY DEFINER function without a pinned 'SET search_path' (search-path injection risk)")
		}
		if !strings.Contains(lower, "owner to") {
			warnings = append(warnings, f+": SECURITY DEFINER function without 'ALTER FUNCTION ... OWNER TO api_owner' — it would be owned by the superuser (privilege-escalation risk)")
		}
	}
	return warnings, nil
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/functions/ -run TestLint -v`
Expected: PASS (all four subtests).

- [ ] **Step 6: Commit**

```bash
git add internal/functions/lint.go internal/functions/lint_test.go internal/functions/testdata/lint
git commit -m "feat(functions): Lint — warn on superuser-owned/unpinned SECURITY DEFINER funcs"
```

---

## Task 2: Wire the lint into `apply-functions`

**Files:**
- Modify: `cmd/postgres4all/apply_functions.go`

- [ ] **Step 1: Add the lint call (and `os` import)**

In `cmd/postgres4all/apply_functions.go`, add `"os"` to the import block. Then, immediately after the positional-dir resolution (the `if len(args) == 1 { dir = args[0] }` block, currently ending at line 21) and BEFORE the existing `sql, n, err := functions.EmitSQL(dir)` line, insert:

```go
			warnings, err := functions.Lint(dir)
			if err != nil {
				return err
			}
			for _, w := range warnings {
				fmt.Fprintln(os.Stderr, "warning: "+w)
			}
```

Leave the existing `sql, n, err := functions.EmitSQL(dir)` line unchanged: `:=` remains valid because `sql` and `n` are new (Go only requires one new variable on the left), and `err` is simply reassigned.

- [ ] **Step 2: Build to verify it compiles**

Run: `go build ./cmd/postgres4all`
Expected: builds clean (`./postgres4all` produced, no unused-variable errors).

- [ ] **Step 3: Manually verify the warning fires**

Run (lint a deliberately-bad fixture via dry-run; needs no live DB):
```bash
go run ./cmd/postgres4all apply-functions --dry-run --dir internal/functions/testdata/lint/unowned 2>/tmp/p4a.err 1>/dev/null; cat /tmp/p4a.err
```
Expected stderr: `warning: internal/functions/testdata/lint/unowned/f.sql: SECURITY DEFINER function without 'ALTER FUNCTION ... OWNER TO api_owner' — ...`

- [ ] **Step 4: Verify the existing suite still passes**

Run: `go test ./...`
Expected: PASS (no behavior change beyond the new warning).

- [ ] **Step 5: Commit**

```bash
git add cmd/postgres4all/apply_functions.go
git commit -m "feat(apply-functions): run functions.Lint and warn (non-fatal) before applying"
```

---

## Task 3: Add `api_owner` to fresh-install roles + grants

**Files:**
- Modify: `internal/generate/generate.go` (`rolesShScript` const; `writeAPIGrants`)
- Regenerate: `internal/generate/testdata/golden/{api_only,api_auth,full}/init/{00-roles.sh,03-api-grants.sql}`

- [ ] **Step 1: Add `api_owner` to the roles script**

In `internal/generate/generate.go`, in the `rolesShScript` const, change the role block from:
```
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'authpw';
    GRANT anon, authenticated TO authenticator;
```
to:
```
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'authpw';
    CREATE ROLE api_owner NOLOGIN NOINHERIT;
    GRANT anon, authenticated TO authenticator;
```

- [ ] **Step 2: Add the `api_owner` USAGE grant**

In `writeAPIGrants` (`internal/generate/generate.go`), immediately after the line
`sb.WriteString("GRANT USAGE ON SCHEMA public TO anon, authenticated;\n")`, add:
```go
	sb.WriteString("GRANT USAGE ON SCHEMA public TO api_owner;\n")
```

- [ ] **Step 3: Run the generate test to confirm it now fails against old goldens**

Run: `go test ./internal/generate/ -run TestGenerate`
Expected: FAIL — `00-roles.sh differs from golden` (and `03-api-grants.sql differs`) for the api-enabled cases.

- [ ] **Step 4: Regenerate the goldens**

Run: `go test ./internal/generate/ -run TestGenerate -update`
Expected: PASS (goldens rewritten).

- [ ] **Step 5: Review every regenerated line by hand**

Run: `git diff internal/generate/testdata/golden`
Expected: ONLY two kinds of additions, ONLY under `api_only`, `api_auth`, `full`:
- `00-roles.sh`: a new `    CREATE ROLE api_owner NOLOGIN NOINHERIT;` line before the `GRANT anon, authenticated` line.
- `03-api-grants.sql`: a new `GRANT USAGE ON SCHEMA public TO api_owner;` line after the anon/authenticated USAGE line.
No changes under `minimal`, `gis`, `languages` (no api → no roles/grants files). If anything else changed, STOP and investigate.

- [ ] **Step 6: Confirm tests pass**

Run: `go test ./internal/generate/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/generate/generate.go internal/generate/testdata/golden
git commit -m "feat(generate): create powerless api_owner role + grant it USAGE on public"
```

---

## Task 4: Add `api_owner` to the `update` delta emitters

**Files:**
- Modify: `internal/update/emit.go` (`EmitPreSQL`, `EmitAddSQL`, `EmitRemoveSQL`)
- Modify: `internal/update/emit_test.go` (new assertion)
- Regenerate: `internal/update/testdata/golden/*api*`

- [ ] **Step 1: Write the failing assertion**

In `internal/update/emit_test.go`, add:
```go
func TestPreSQLCreatesAPIOwner(t *testing.T) {
	got := EmitPreSQL("pw")
	if !strings.Contains(got, "CREATE ROLE api_owner NOLOGIN NOINHERIT") {
		t.Errorf("EmitPreSQL must create api_owner; got:\n%s", got)
	}
}
```
(`strings` is already imported in this test file.)

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/update/ -run TestPreSQLCreatesAPIOwner`
Expected: FAIL — assertion not met.

- [ ] **Step 3: Add `api_owner` to `EmitPreSQL`**

In `internal/update/emit.go`, in `EmitPreSQL`, immediately after the `authenticator` CREATE line and BEFORE the `GRANT anon, authenticated TO authenticator;` line, add:
```go
	sb.WriteString("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='api_owner') THEN CREATE ROLE api_owner NOLOGIN NOINHERIT; END IF; END $$;\n")
```

- [ ] **Step 4: Add the USAGE grant to `EmitAddSQL`'s api block**

In `EmitAddSQL`, immediately after `sb.WriteString("GRANT USAGE ON SCHEMA public TO anon, authenticated;\n")` (inside `if apiAdded {`), add:
```go
		sb.WriteString("GRANT USAGE ON SCHEMA public TO api_owner;\n")
```

- [ ] **Step 5: Add `api_owner` to `EmitRemoveSQL`'s api teardown**

In `EmitRemoveSQL`, in the `if apiRemoved {` block, change:
```go
		sb.WriteString("DROP OWNED BY authenticator, anon, authenticated;\n")
```
to:
```go
		sb.WriteString("DROP OWNED BY authenticator, anon, authenticated, api_owner;\n")
```
and immediately after the `sb.WriteString("DROP ROLE IF EXISTS anon;\n")` line, add:
```go
		sb.WriteString("DROP ROLE IF EXISTS api_owner;\n")
```

- [ ] **Step 6: Run the new assertion to verify it passes**

Run: `go test ./internal/update/ -run TestPreSQLCreatesAPIOwner`
Expected: PASS.

- [ ] **Step 7: Confirm golden tests now fail (expected), then regenerate**

Run: `go test ./internal/update/`
Expected: FAIL — golden mismatches for api-related fixtures.

Run: `go test ./internal/update/ -update`
Expected: PASS (goldens rewritten).

- [ ] **Step 8: Review every regenerated line by hand**

Run: `git diff internal/update/testdata/golden`
Expected additions ONLY:
- `*_pre.sql` (where api is added): the `DO $$ ... CREATE ROLE api_owner ...` line after the authenticator DO-block.
- `*_add.sql` (where api is added): `GRANT USAGE ON SCHEMA public TO api_owner;` after the anon/authenticated USAGE line.
- `*_remove.sql` (where api is removed): `api_owner` appended to the `DROP OWNED BY ...` line, and a new `DROP ROLE IF EXISTS api_owner;` line after `DROP ROLE IF EXISTS anon;`.
Fixtures with no api change must be unchanged. If anything else moved, STOP and investigate.

- [ ] **Step 9: Confirm the whole suite passes**

Run: `go test ./...`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add internal/update/emit.go internal/update/emit_test.go internal/update/testdata/golden
git commit -m "feat(update): create/drop api_owner in the delta (PreSQL + api add/remove)"
```

---

## Task 5: Harden the demo — `functions/example_submit.sql`

**Files:**
- Modify: `functions/example_submit.sql`

- [ ] **Step 1: Append the owner reassignment + scoped grant**

At the END of `functions/example_submit.sql`, after the existing `DO $$ ... GRANT EXECUTE ... $$;` block, add:
```sql

-- Run the privileged INSERTs as a scoped, NON-superuser role rather than the superuser that
-- applied this file. api_owner exists only when `api` is enabled; the table grant is applied
-- only when the target tables exist (document_store + job_queue) so this file still applies
-- cleanly on any install.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_owner') THEN
        ALTER FUNCTION submit_product(text, jsonb) OWNER TO api_owner;
        IF to_regclass('public.products') IS NOT NULL
           AND to_regclass('public.jobs') IS NOT NULL THEN
            GRANT INSERT ON products, jobs TO api_owner;
        END IF;
    END IF;
END $$;
```

- [ ] **Step 2: Fix the misleading comment**

In `functions/example_submit.sql`, replace the comment sentence that currently reads (around line 9-11):
```
-- SECURITY DEFINER: this function performs privileged INSERTs, but anon/authenticated have only
-- SELECT on products/jobs. Running as the function owner lets unprivileged callers perform exactly
-- this one controlled write — the whole point of exposing logic as an RPC. search_path is pinned
-- (a SECURITY DEFINER safety requirement); pg_catalog is searched first implicitly.
```
with:
```
-- SECURITY DEFINER: this function performs privileged INSERTs, but anon/authenticated have only
-- SELECT on products/jobs. The trailing DO-block reassigns ownership to api_owner — a powerless
-- role granted ONLY INSERT on products/jobs — so an unprivileged caller runs exactly this one
-- controlled write as that scoped role, NOT as the superuser. search_path is pinned (a SECURITY
-- DEFINER safety requirement); pg_catalog is searched first implicitly.
```

- [ ] **Step 3: Verify the lint is now clean for `functions/`**

Run:
```bash
go run ./cmd/postgres4all apply-functions --dry-run 2>/tmp/p4a.err 1>/dev/null; cat /tmp/p4a.err
```
Expected: EMPTY stderr (the file now has both `SET search_path` and `OWNER TO`).

- [ ] **Step 4: Commit**

```bash
git add functions/example_submit.sql
git commit -m "feat(demo): submit_product runs as scoped api_owner, not the superuser"
```

---

## Task 6: Harden the job_queue examples

**Files:**
- Modify: `examples/job_queue/claim_job.plpgsql.sql`
- Modify: `examples/job_queue/claim_job.plpython.sql`

- [ ] **Step 1: Reassign owner for the PL/pgSQL variant**

At the END of `examples/job_queue/claim_job.plpgsql.sql`, add:
```sql

-- Run the dequeue UPDATE as a scoped, non-superuser role. api_owner exists only when `api` is
-- enabled; the grant is applied only when jobs exists (job_queue enabled).
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_owner') THEN
        ALTER FUNCTION claim_job_plpgsql() OWNER TO api_owner;
        IF to_regclass('public.jobs') IS NOT NULL THEN
            GRANT SELECT, UPDATE ON jobs TO api_owner;
        END IF;
    END IF;
END $$;
```

- [ ] **Step 2: Reassign owner for the PL/Python variant**

At the END of `examples/job_queue/claim_job.plpython.sql`, add:
```sql

-- Run the dequeue UPDATE as a scoped, non-superuser role (see the PL/pgSQL variant).
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_owner') THEN
        ALTER FUNCTION claim_job_plpython() OWNER TO api_owner;
        IF to_regclass('public.jobs') IS NOT NULL THEN
            GRANT SELECT, UPDATE ON jobs TO api_owner;
        END IF;
    END IF;
END $$;
```

- [ ] **Step 3: Verify the lint is now clean for the example dir**

Run:
```bash
go run ./cmd/postgres4all apply-functions --dry-run --dir examples/job_queue 2>/tmp/p4a.err 1>/dev/null; cat /tmp/p4a.err
```
Expected: EMPTY stderr (both files now carry `OWNER TO`; both already pin `search_path`).

- [ ] **Step 4: Commit**

```bash
git add examples/job_queue/claim_job.plpgsql.sql examples/job_queue/claim_job.plpython.sql
git commit -m "feat(examples): claim_job runs as scoped api_owner, not the superuser"
```

---

## Task 7: Final verification

- [ ] **Step 1: Full suite green**

Run: `go test ./...`
Expected: PASS across all packages.

- [ ] **Step 2: Build the binary**

Run: `go build ./cmd/postgres4all`
Expected: clean build.

- [ ] **Step 3: Confirm no stray superuser-owned definers remain in-repo**

Run:
```bash
for d in functions examples/job_queue; do go run ./cmd/postgres4all apply-functions --dry-run --dir "$d" 2>&1 1>/dev/null; done
```
Expected: NO `warning:` lines.

- [ ] **Step 4: Close the issue scope note**

Run:
```bash
bd update postgres4all-cip --notes "DONE: api_owner scoped owner role (generate + update) + apply-functions warn-only lint + demo/examples reassign ownership. Remaining sub-parts: per-capability RLS option, read/writer role separation."
```

(Do NOT `bd close` — `cip` still has the RLS and role-separation sub-parts. The session-close push happens after this task.)
