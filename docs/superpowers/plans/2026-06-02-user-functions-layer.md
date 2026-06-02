# User functions layer + language toggles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-level `functions/` directory of user-authored business-logic SQL, an idempotent `./setup.sh --apply-functions` command that applies them to a running install and reloads PostgREST, plus install-time `languages` toggles (`plperl` trusted; `plpython` untrusted, gated).

**Architecture:** `--apply-functions` concatenates `functions/*.sql` and runs them through one `psql --single-transaction`, then `NOTIFY pgrst, 'reload schema'`. Languages flow into the generated `build/Dockerfile` (apt) and `build/init/01-extensions.sql` (`CREATE EXTENSION`), mirroring existing extension toggles; `plpython` requires `languages.allow_untrusted`. A `--dry-run` mode prints the SQL with no Docker, so the pure-bash tests can drive it.

**Tech Stack:** Bash, `jq`, Docker Compose, PostgreSQL 17, PostgREST. Tests extend `test/test_setup.sh` and add `test/test_functions.sh`.

**Spec:** `docs/superpowers/specs/2026-06-02-user-functions-layer-design.md`

**Reuse from existing `setup.sh`:** helpers `_compose`, `_pgdata_volume_name`, `_psql_q`, `_apply_sql`, `_wait_db_healthy`, `die`; the arg-parse `while` loop; the `${EN[...]}`-style generation. `PG_MAJOR=17` is a script var. `PG_USER`/`PG_DB` are set during `.env` generation.

---

### Task 1: The `functions/` directory (README + example)

**Files:** Create `functions/README.md`, `functions/example_submit.sql`

- [ ] **Step 1: Create `functions/README.md`**

```markdown
# functions/

Drop your business-logic SQL here. Each `.sql` file should contain `CREATE OR REPLACE FUNCTION …`
plus a `GRANT EXECUTE … TO anon|authenticated|<role>`. PostgREST exposes any function in the
`public` schema at `POST /rpc/<name>` (or `GET` if the function is marked `STABLE`/`IMMUTABLE`).

Apply them to a running install (idempotent, all-or-nothing, reloads PostgREST):

    ./setup.sh --apply-functions

Preview without applying:

    ./setup.sh --apply-functions --dry-run

Notes:
- Use `CREATE OR REPLACE` so re-applying is safe — that's how you ship edits.
- All files are applied in one transaction; a syntax error in any file rolls everything back.
- A function written in a non-default language (e.g. `plperl`) needs that language enabled in
  `config.json`'s `languages` block at install time.
```

- [ ] **Step 2: Create `functions/example_submit.sql`**

```sql
-- Example business logic: store a document (document_store) AND enqueue a job (job_queue),
-- atomically, then return the new id. Exposed at: POST /rpc/submit_product
-- Requires the `document_store` and `job_queue` capabilities to be enabled.
CREATE OR REPLACE FUNCTION submit_product(name text, attributes jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    new_id bigint;
BEGIN
    INSERT INTO products (name, attributes)
    VALUES (submit_product.name, submit_product.attributes)
    RETURNING id INTO new_id;

    INSERT INTO jobs (payload)
    VALUES (jsonb_build_object('task', 'index_product', 'product_id', new_id));

    RETURN jsonb_build_object('product_id', new_id, 'queued', true);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_product(text, jsonb) TO anon, authenticated;
```

- [ ] **Step 3: Verify + commit**

Run: `ls functions/` → shows `README.md` and `example_submit.sql`.
```bash
git add functions/
git commit -m "feat: add functions/ layer with README and example function"
```

---

### Task 2: `languages` config — generation + gating (TDD)

**Files:** Modify `setup.sh`, `test/test_setup.sh`, `config.example.json`

- [ ] **Step 1: Add failing tests**

Append to `test/test_setup.sh` before the summary block:
```bash
# --- languages: plperl -> apt package + CREATE EXTENSION plperl ---
# NOTE: PL packages are named postgresql-plperl-<major> (lang-then-version), NOT postgresql-<major>-plperl.
gen '{"capabilities":{"document_store":true},"languages":{"plperl":true}}'
grep -q 'postgresql-plperl-17' build/Dockerfile && ok "plperl: apt package" || bad "plperl pkg"
grep -q 'CREATE EXTENSION IF NOT EXISTS plperl' build/init/01-extensions.sql && ok "plperl: extension" || bad "plperl ext"

# --- languages: plpython without allow_untrusted -> setup errors ---
cfg="$(mktemp)"; printf '{"capabilities":{"document_store":true},"languages":{"plpython":true}}' >"$cfg"
out="$(./setup.sh --dry-run "$cfg" 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -qi 'untrusted'; } && ok "plpython gated without allow_untrusted" || bad "plpython gate"
rm -f "$cfg"

# --- languages: plpython WITH allow_untrusted -> package + plpython3u extension ---
gen '{"capabilities":{"document_store":true},"languages":{"plpython":true,"allow_untrusted":true}}'
grep -q 'postgresql-plpython3-17' build/Dockerfile && ok "plpython: apt package" || bad "plpython pkg"
grep -q 'CREATE EXTENSION IF NOT EXISTS plpython3u' build/init/01-extensions.sql && ok "plpython: extension" || bad "plpython ext"

# --- languages: omitted -> no language packages/extensions ---
gen '{"capabilities":{"document_store":true}}'
grep -qE 'plperl|plpython' build/Dockerfile && bad "no language pkgs when omitted" || ok "no language pkgs (omitted)"
grep -qE 'plperl|plpython3u' build/init/01-extensions.sql && bad "no language exts when omitted" || ok "no language exts (omitted)"
```

- [ ] **Step 2: Run, verify failure** — `./test/test_setup.sh` → new assertions fail.

- [ ] **Step 3: Read the language flags + validate (gating)**

In `setup.sh`, after the existing capability flags are loaded into `EN` and BEFORE `build/`
generation (a good spot: right after the capability validation block), add:
```bash
# --- languages (plpgsql is always available; plperl trusted; plpython untrusted) ---
LANG_PLPERL="$(jq -r '.languages.plperl // false | if . then 1 else 0 end' "$CONFIG")"
LANG_PLPYTHON="$(jq -r '.languages.plpython // false | if . then 1 else 0 end' "$CONFIG")"
LANG_ALLOW_UNTRUSTED="$(jq -r '.languages.allow_untrusted // false | if . then 1 else 0 end' "$CONFIG")"

if [ "$LANG_PLPYTHON" = 1 ] && [ "$LANG_ALLOW_UNTRUSTED" = 0 ]; then
  die "language 'plpython' is UNTRUSTED (plpython3u runs with the database OS user's full privileges — unsafe for user-supplied code). Set \"allow_untrusted\": true in the languages block of $CONFIG to enable it deliberately."
fi
if [ "$LANG_PLPYTHON" = 1 ]; then
  echo "WARNING: plpython3u is an UNTRUSTED language; only superusers can create functions in it and they run with full OS privileges." >&2
fi
```

- [ ] **Step 4: Emit language apt packages into the Dockerfile**

In the Dockerfile-generation block of `setup.sh`, add a RUN that installs the enabled language
packages. Place it AFTER the base `FROM`/`ARG` lines and BEFORE the `COPY init/` line (alongside the
other apt installs). Use:
```bash
  if [ "$LANG_PLPERL" = 1 ] || [ "$LANG_PLPYTHON" = 1 ]; then
    pkgs=""
    [ "$LANG_PLPERL" = 1 ]   && pkgs="$pkgs postgresql-plperl-${PG_MAJOR}"
    [ "$LANG_PLPYTHON" = 1 ] && pkgs="$pkgs postgresql-plpython3-${PG_MAJOR}"
    echo "RUN apt-get update && apt-get install -y --no-install-recommends${pkgs} && rm -rf /var/lib/apt/lists/*"
  fi
```
Note: `${pkgs}` begins with a leading space, so the emitted line reads `... --no-install-recommends postgresql-17-plperl ...`. Confirm the spacing in the generated Dockerfile is valid.

- [ ] **Step 5: Emit language `CREATE EXTENSION` into 01-extensions.sql**

In the `01-extensions.sql` generation block, add after the existing capability extension lines (and
before the trailing `true`):
```bash
  [ "$LANG_PLPERL" = 1 ]   && echo "CREATE EXTENSION IF NOT EXISTS plperl;"
  [ "$LANG_PLPYTHON" = 1 ] && echo "CREATE EXTENSION IF NOT EXISTS plpython3u;"
```

- [ ] **Step 6: Update `config.example.json`**

Add a `languages` block to `config.example.json` (after the `capabilities` block), keeping valid JSON:
```json
  "languages": { "plperl": false, "plpython": false, "allow_untrusted": false },
```
Verify with `jq -e . config.example.json`.

- [ ] **Step 7: Run tests, verify pass**

Run: `./test/test_setup.sh` → `FAIL=0`. Inspect:
`printf '{"capabilities":{"document_store":true},"languages":{"plperl":true,"plpython":true,"allow_untrusted":true}}' >/tmp/l.json && ./setup.sh --dry-run /tmp/l.json && grep -nE 'plperl|plpython' build/Dockerfile build/init/01-extensions.sql`
Confirm one combined apt RUN with both packages, and both `CREATE EXTENSION` lines.

- [ ] **Step 8: Commit**

```bash
git add setup.sh test/test_setup.sh config.example.json
git commit -m "feat: languages config (plperl trusted; plpython gated untrusted)"
```

---

### Task 3: `--apply-functions` arg wiring + dry-run (TDD)

**Files:** Modify `setup.sh`; create `test/test_functions.sh`

- [ ] **Step 1: Create the functions test harness**

Create `test/test_functions.sh` (`chmod +x`):
```bash
#!/usr/bin/env bash
# Functions-apply tests. Drive setup.sh --apply-functions --dry-run (prints the SQL it would apply,
# no Docker/DB).
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

OUT="$(./setup.sh --apply-functions --dry-run 2>&1)"; RC=$?

[ $RC -eq 0 ] && ok "apply-functions --dry-run exits 0" || bad "apply dry-run rc=$RC"
echo "$OUT" | grep -q 'CREATE OR REPLACE FUNCTION submit_product' && ok "includes example function" || bad "example function missing"
echo "$OUT" | grep -q "NOTIFY pgrst, 'reload schema'" && ok "includes schema reload" || bad "reload missing"

# --apply-functions cannot combine with --update
out2="$(./setup.sh --apply-functions --update --dry-run 2>&1)"; rc2=$?
{ [ $rc2 -ne 0 ] && echo "$out2" | grep -qi 'cannot be combined'; } && ok "apply+update rejected" || bad "apply+update guard"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run, verify failure** — `./test/test_functions.sh` → fails (flag not handled).

- [ ] **Step 3: Add `--apply-functions` to the arg parser**

In the `while` arg-parse loop in `setup.sh`, add a case (before the `--*) die unknown` catch-all):
```bash
    --apply-functions) APPLY_FUNCTIONS=1 ;;
```
Initialize `APPLY_FUNCTIONS=0` alongside the other flag defaults. After the loop, add guards
(alongside the existing `--allow-drop`/`--installed` guards):
```bash
if [ "$APPLY_FUNCTIONS" = 1 ] && [ "$UPDATE" = 1 ]; then die "--apply-functions cannot be combined with --update"; fi
if [ "$APPLY_FUNCTIONS" = 1 ] && [ "$ALLOW_DROP" = 1 ]; then die "--apply-functions cannot be combined with --allow-drop"; fi
```

- [ ] **Step 4: Add the apply-functions emit helper + early branch**

Add a helper near the other emit functions:
```bash
emit_functions_sql() {
  # Concatenate functions/*.sql in sorted order; print nothing if none exist.
  local f found=0
  for f in functions/*.sql; do
    [ -e "$f" ] || continue
    found=1
    echo "-- ${f}"
    cat "$f"
    echo
  done
  [ "$found" = 1 ] && echo "NOTIFY pgrst, 'reload schema';"
  return 0
}
```
Then add the apply-functions handling. It must run BEFORE the normal install/update branching but
AFTER `cd "$(dirname "$0")"` (so `functions/` resolves) — note `--apply-functions` does NOT need
`build/` generation. Place this block right after the `cd "$(dirname "$0")"` (and after the OLD_*
secret capture is irrelevant here). Implement:
```bash
if [ "$APPLY_FUNCTIONS" = 1 ]; then
  if ! ls functions/*.sql >/dev/null 2>&1; then
    echo "no functions to apply (functions/ has no .sql files)."
    exit 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    emit_functions_sql
    exit 0
  fi
  # live apply added in Task 4
  die "internal: live apply-functions not implemented"
fi
```
IMPORTANT: `--apply-functions` needs `cd "$(dirname "$0")"` to have run so `functions/*.sql` is
relative to the script dir. Verify the `cd` precedes this block; if the `cd` currently sits later
(inside the generation path), MOVE a `cd "$(dirname "$0")"` to before this block, or compute an
absolute functions path. The dry-run path must not require `build/` or Docker.

- [ ] **Step 5: Run tests, verify pass**

Run: `./test/test_functions.sh` → `FAIL=0`. Run `./test/test_setup.sh` and (if present)
`./test/test_update.sh` → `FAIL=0`. `bash -n setup.sh` ok.
Manual: `./setup.sh --apply-functions --dry-run` → prints the example function SQL + the NOTIFY line.

- [ ] **Step 6: Commit**

```bash
git add setup.sh test/test_functions.sh
git commit -m "feat: --apply-functions arg wiring + dry-run (concatenate functions/ + reload)"
```

---

### Task 4: Live `--apply-functions` execution (no unit test; e2e in Task 5)

**Files:** Modify `setup.sh`

- [ ] **Step 1: Implement the live apply**

Replace `die "internal: live apply-functions not implemented"` with:
```bash
  # Live: require an existing install, bring db up, apply all functions in one transaction, reload.
  vol="$(_pgdata_volume_name)"
  if [ -z "$vol" ] || ! docker volume inspect "$vol" >/dev/null 2>&1; then
    die "no existing install found (no pgdata volume). Run './setup.sh' first, then --apply-functions."
  fi
  _compose up -d --remove-orphans db
  _wait_db_healthy
  echo "applying $(ls functions/*.sql | wc -l | tr -d ' ') function file(s)..."
  emit_functions_sql | _apply_sql
  echo "functions applied; PostgREST schema reloaded."
  exit 0
```
Note: `_apply_sql` runs `psql -v ON_ERROR_STOP=1 --single-transaction -U "$PG_USER" -d "$PG_DB"`.
`PG_USER`/`PG_DB` are set during `.env` generation — which for `--apply-functions` does NOT run
(we skip `build/` generation). So set them for this path: read from the existing `build/.env`:
```bash
  PG_USER="$(grep '^POSTGRES_USER=' build/.env | cut -d= -f2-)"
  PG_DB="$(grep '^POSTGRES_DB=' build/.env | cut -d= -f2-)"
```
Place these reads BEFORE the `_compose`/`_apply_sql` calls (right after the volume check). If
`build/.env` is missing, `die "build/.env not found — run ./setup.sh first"`. Adjust the exact
variable names to match what `_apply_sql`/`_psql_q` reference (`PG_USER`/`PG_DB`).

- [ ] **Step 2: Static check + no regression**

Run: `bash -n setup.sh` → ok. `./test/test_functions.sh`, `./test/test_setup.sh`, `./test/test_update.sh`
→ all `FAIL=0` (dry-run paths don't touch the live code).

- [ ] **Step 3: Commit**

```bash
git add setup.sh
git commit -m "feat: live --apply-functions (single-transaction apply + schema reload)"
```

---

### Task 5: End-to-end Docker verification

**Files:** none (verification only). Uses the legacy builder if buildx < 0.17.

- [ ] **Step 1: Fresh install with the capabilities the example needs + api**

```bash
cat > config.json <<'JSON'
{ "postgres": { "password": "fn_e2e" }, "seed_demo_data": true,
  "capabilities": { "document_store": true, "job_queue": true, "api": true } }
JSON
./setup.sh --dry-run config.json >/dev/null
DOCKER_BUILDKIT=0 docker build -t postgres4all:generated build/   # buildx is old here
docker compose --env-file build/.env -f build/docker-compose.yml up -d --no-build
# wait healthy
```

- [ ] **Step 2: Apply functions, assert the endpoint works**

```bash
./setup.sh --apply-functions config.json
sleep 3
# the example submit_product is now an /rpc endpoint:
curl -s -X POST http://127.0.0.1:3000/rpc/submit_product \
  -H 'Content-Type: application/json' \
  -d '{"name":"E2E Keyboard","attributes":{"wireless":true}}'        # -> {"product_id":N,"queued":true}
# verify it actually wrote a product AND enqueued a job, atomically:
DC() { docker compose --env-file build/.env -f build/docker-compose.yml exec -T db psql -U postgres -d app -tAc "$1"; }
DC "SELECT count(*) FROM products WHERE name='E2E Keyboard';"        # -> 1
DC "SELECT count(*) FROM jobs WHERE payload->>'task'='index_product';" # -> >=1
```

- [ ] **Step 3: Idempotency + live reload**

Edit `functions/example_submit.sql` (e.g. change the returned JSON to add `"v":2`), then:
```bash
./setup.sh --apply-functions config.json
sleep 2
curl -s -X POST http://127.0.0.1:3000/rpc/submit_product -d '{"name":"again"}'  # -> includes "v":2
```
Expected: re-apply succeeds (CREATE OR REPLACE), PostgREST serves the updated function without a
restart. Revert the edit afterward (`git checkout functions/example_submit.sql`).

- [ ] **Step 4: (If feasible) prove a non-default language end to end**

```bash
# rebuild with plperl enabled, then apply a trivial plperl function
cat > config.json <<'JSON'
{ "postgres": { "password": "fn_e2e" }, "seed_demo_data": true,
  "capabilities": { "document_store": true, "job_queue": true, "api": true },
  "languages": { "plperl": true } }
JSON
./setup.sh --dry-run config.json >/dev/null
DOCKER_BUILDKIT=0 docker build -t postgres4all:generated build/
docker compose --env-file build/.env -f build/docker-compose.yml up -d --no-build --remove-orphans
# (note: extension created on fresh init only; on this already-initialised volume, create it once:)
DC "CREATE EXTENSION IF NOT EXISTS plperl;"
cat > functions/zz_perl_demo.sql <<'SQL'
CREATE OR REPLACE FUNCTION perl_upper(t text) RETURNS text LANGUAGE plperl AS $$ return uc($_[0]); $$;
GRANT EXECUTE ON FUNCTION perl_upper(text) TO anon, authenticated;
SQL
./setup.sh --apply-functions config.json
sleep 2
curl -s "http://127.0.0.1:3000/rpc/perl_upper?t=hello"   # -> "HELLO"
rm -f functions/zz_perl_demo.sql
```
This step doubles as a live confirmation that the languages caveat (extension must exist on the
running DB) is real and that a `plperl` function works once the language is present. If buildx/time
makes this impractical, document it as verified-by-reasoning and skip.

- [ ] **Step 5: Guard + teardown**

```bash
# no-install guard:
docker compose --env-file build/.env -f build/docker-compose.yml down -v
./setup.sh --apply-functions config.json 2>&1 | grep -qi 'no existing install' && echo "OK: apply guard fires"
rm -f config.json
```

---

### Task 6: Documentation

**Files:** Modify `README.md`, `CLAUDE.md`

- [ ] **Step 1: README — add a "Custom business logic (`/rpc`)" subsection**

After the "Updating an existing install" subsection in `README.md`, add:
```markdown
### Custom business logic (`/rpc`)

Drop SQL functions into the top-level `functions/` directory and apply them to a running install:

```bash
./setup.sh --apply-functions             # apply functions/*.sql, then reload PostgREST
./setup.sh --apply-functions --dry-run   # print the SQL without applying
```

Each function in the `public` schema becomes a `POST /rpc/<name>` endpoint (or `GET` if `STABLE`).
Files are applied in one transaction (all-or-nothing) using your `CREATE OR REPLACE` definitions, so
re-applying is how you ship edits. A function can leverage any enabled capability — the shipped
`functions/example_submit.sql` writes a document **and** enqueues a job in a single call.

**Other languages.** `plpgsql` is always available. Enable more in the `languages` block of
`config.json` *at install time*:

| Language | `languages` key | Trusted? |
|---|---|---|
| PL/pgSQL | (always on) | ✅ |
| PL/Perl | `"plperl": true` | ✅ |
| PL/Python | `"plpython": true` + `"allow_untrusted": true` | ❌ untrusted |

> [!WARNING]
> `plpython` uses `plpython3u`, an **untrusted** language (functions run with the database OS user's
> full privileges). It is gated behind `"allow_untrusted": true` and is unsafe for code you didn't
> write. Toggling a language on an already-running install requires an image rebuild
> (`down -v` + `./setup.sh`).
```

- [ ] **Step 2: CLAUDE.md — append to the `## Provisioning model` section**

```markdown
**Custom functions:** user business logic lives in top-level `functions/*.sql` (not generated, not
init — user space). `./setup.sh --apply-functions` concatenates them and runs one
`psql --single-transaction`, then `NOTIFY pgrst, 'reload schema'` so PostgREST serves the new
`/rpc` endpoints live. It requires an existing install (pgdata volume) and reads `PG_USER`/`PG_DB`
from `build/.env`; `--apply-functions --dry-run` prints the SQL with no Docker (tested by
`test/test_functions.sh`). Procedural languages beyond `plpgsql` are install-time toggles in the
`languages` config block: `plperl` (trusted) and `plpython` (untrusted `plpython3u`, gated behind
`allow_untrusted`). They generate apt installs in `build/Dockerfile` and `CREATE EXTENSION` lines in
`01-extensions.sql`; changing them later needs an image rebuild.
```

- [ ] **Step 3: Verify** — `./test/test_setup.sh`, `./test/test_functions.sh`, `./test/test_update.sh` → all `FAIL=0`.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document the functions/ layer and languages toggles"
```

---

## Self-Review

**Spec coverage:** `functions/` dir + example (T1), languages generation + gating (T2), `--apply-functions`
arg + dry-run (T3), live apply + reload (T4), e2e incl. a non-default language (T5), docs (T6). All
spec sections map to tasks.

**Placeholder scan:** the Task-3 stub (`die "internal: live apply-functions not implemented"`) is
replaced in full in Task 4. No "TBD".

**Type/name consistency:** `LANG_PLPERL`/`LANG_PLPYTHON`/`LANG_ALLOW_UNTRUSTED`, `APPLY_FUNCTIONS`,
`emit_functions_sql`, `_apply_sql`/`_psql_q`/`_pgdata_volume_name`/`_wait_db_healthy`, `PG_USER`/`PG_DB`,
the `functions/` path, and `NOTIFY pgrst, 'reload schema'` are consistent across tasks. `PG_MAJOR` is the
existing script var used for the apt package names.

**Known risks to validate during execution:**
- `--apply-functions` skips `build/` generation, so `PG_USER`/`PG_DB` are NOT set by the normal path —
  Task 4 reads them from `build/.env` (which exists from the prior install). Confirm the variable names
  match `_apply_sql`'s references.
- The `cd "$(dirname "$0")"` must precede the apply-functions block so `functions/*.sql` resolves; Task 3
  Step 4 flags moving/confirming it.
- `NOTIFY pgrst` only has an effect when PostgREST is running (api enabled); harmless otherwise.
