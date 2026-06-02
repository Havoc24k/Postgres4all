# User functions layer + procedural-language toggles

**Date:** 2026-06-02
**Status:** Approved design, pending spec review
**Builds on:** the config-driven provisioning and capability-update-path specs.

## Problem

PostgREST exposes any function in the `public` schema as an `/rpc/<name>` endpoint, so the natural
way to add business logic to a Postgres4all deployment is to write SQL/PL functions. But the project
has no place for **user-authored** functions and no way to apply them to a running install *after*
setup. Separately, only `plpgsql` is available; users may want other procedural languages — and the
obvious choice, `plv8` (JavaScript), is **not apt-installable** on the pinned base images (confirmed:
no `plv8` package on `postgres:17`/trixie nor in the PostGIS image's PGDG/bullseye repo).

## Goals

- A top-level **`functions/`** directory where users drop `.sql` files containing their business
  logic (`CREATE OR REPLACE FUNCTION …` + grants), added/edited **post-setup**.
- A command to **apply** those files to the running database idempotently and make PostgREST serve
  them immediately.
- Optional **procedural-language toggles** (`plperl`, `plpython`) that ARE apt-installable, with the
  untrusted one gated behind an explicit opt-in. `plpgsql` is always available.

## Non-goals

- No `plv8` / JavaScript (not packageable on these bases; revisit later).
- No scaffolding generator and no standalone CLI (explicitly out of scope; minimal apply command only).
- No Postgres major bump (stays on 17).
- No automatic application of `functions/` during install/update — it is a separate, explicit step.
- No removal/cleanup of functions deleted from `functions/` (apply is additive `CREATE OR REPLACE`;
  dropping a function is the user's manual concern).
- No wiring of language toggles into the `--update` capability delta (languages are install-time;
  see caveat).

## Component 1 — the `functions/` layer

### Directory
A tracked top-level `functions/` containing:
- `functions/README.md` — the convention (drop `.sql` files here; use `CREATE OR REPLACE`; grant
  `EXECUTE` to `anon`/`authenticated`/your role; they appear at `POST /rpc/<name>`).
- `functions/example_submit.sql` — one runnable reference: a `submit_*` function that writes a row
  and enqueues a job, with its `GRANT EXECUTE`. Demonstrates the pattern and gives the tests content.

`functions/` is **not** gitignored — it is part of the repo (users add their own files alongside the
example, or delete the example).

### Command: `./setup.sh --apply-functions [--dry-run]`
- **Live mode** (`--apply-functions`):
  1. Require an existing install (the `pgdata` volume must exist, via `_pgdata_volume_name`); else
     `die` with "no existing install — run ./setup.sh first". Bring `db` up if needed and wait healthy
     (reuse `query_installed`'s up+wait helpers).
  2. If `functions/` has no `.sql` files, print "no functions to apply" and exit 0.
  3. Concatenate `functions/*.sql` in shell-sorted order and apply through one
     `_apply_sql` invocation (`psql -v ON_ERROR_STOP=1 --single-transaction`). All-or-nothing.
  4. `NOTIFY pgrst, 'reload schema'` (via `_psql_q`) so PostgREST reloads its schema cache and serves
     the new endpoints without a restart. Harmless no-op if PostgREST isn't running.
  5. Report how many files were applied.
- **Dry-run** (`--apply-functions --dry-run`): print the concatenated SQL that *would* be applied
  plus the `NOTIFY` line, then exit 0. Touches no Docker/DB. This is what the test suite drives.
- Flag wiring: `--apply-functions` is mutually independent of `--update`; combining the two is an
  error (`die`). `--apply-functions` works in both install-mode-absent and present states only via
  the volume guard (it never provisions; it only applies).

### Properties
- **Atomicity:** one transaction over all files; a syntax error in any file rolls everything back,
  leaving the live schema untouched.
- **Idempotency:** by the `CREATE OR REPLACE` convention, re-applying is safe and is the normal way
  to ship edits.
- **Immediate availability:** the `NOTIFY pgrst, 'reload schema'` makes new `/rpc` endpoints live at
  once (PostgREST listens on the `pgrst` channel by default).

## Component 2 — `languages` config

A new top-level `languages` object in `config.json` (all optional; `plpgsql` is implicit/always on):

```jsonc
"languages": {
  "plperl": false,
  "plpython": false,
  "allow_untrusted": false
}
```

Generation (mirrors the existing extension toggles, so dry-run generation tests cover it):

- `plperl: true` → `build/Dockerfile` adds `postgresql-${PG_MAJOR}-plperl`; `build/init/01-extensions.sql`
  adds `CREATE EXTENSION IF NOT EXISTS plperl;` (the **trusted** Perl language).
- `plpython: true` → `build/Dockerfile` adds `postgresql-${PG_MAJOR}-plpython3`; `01-extensions.sql`
  adds `CREATE EXTENSION IF NOT EXISTS plpython3u;` (the only Python variant — **untrusted**).

### Untrusted gating (validation)
`plpython: true` **requires** `languages.allow_untrusted: true`. Otherwise `setup.sh` errors before
generating anything:

> `ERROR: language 'plpython' is UNTRUSTED (plpython3u runs with the database OS user's full
> privileges — unsafe for user-supplied code). Set "allow_untrusted": true in the languages block to
> enable it deliberately.`

When enabled, a one-line warning is printed to stderr at generation time.

These toggles integrate with the existing preflight/validation and `build/` generation. They are
read with `jq` like the capability flags.

## Caveat — languages are install-time

Language toggles change the **image** (apt packages) and the **extensions** (`01-extensions.sql`),
both of which are evaluated when `build/` is generated and the image is built. Enabling a language on
an already-running install therefore requires an image rebuild — a `down -v` + `./setup.sh`, or any
`--update` that rebuilds the image. This is documented; language deltas are intentionally **not**
wired into the `--update` capability-delta logic (out of scope for "minimal"). The `functions/` layer
itself is fully post-setup and re-appliable; it assumes the language a function uses is already
installed (else the apply transaction fails with a clear `could not open extension control file` /
`language "…" does not exist` error and rolls back).

## Data flow

```
# install time
config.json (capabilities + languages) ──> setup.sh ──> build/ (Dockerfile installs plperl/plpython
                                                          if enabled; 01-extensions CREATE EXTENSION)
                                                       ──> docker compose up  (extensions created on init)

# post setup, repeatable
edit functions/*.sql ──> ./setup.sh --apply-functions
                          │  require pgdata volume; db up + healthy
                          ▼
                cat functions/*.sql | psql --single-transaction -v ON_ERROR_STOP=1
                          ▼
                NOTIFY pgrst, 'reload schema'   ──> PostgREST serves new /rpc endpoints
```

## Error handling

- `--apply-functions` with no existing install (no volume) → `die` "no existing install — run
  ./setup.sh first".
- `--apply-functions` combined with `--update` → `die` "--apply-functions cannot be combined with
  --update".
- Empty `functions/` → "no functions to apply", exit 0 (not an error).
- A failing statement in any function file → `ON_ERROR_STOP` aborts the single transaction; nothing is
  applied; the psql error (with file context the user can locate) propagates and the script exits
  non-zero.
- `plpython` enabled without `allow_untrusted` → validation error before any generation.

## Testing strategy

**Pure-bash generation tests** (extend `test/test_setup.sh`):
- `plperl: true` → `build/Dockerfile` contains `postgresql-17-plperl`; `01-extensions.sql` contains
  `CREATE EXTENSION IF NOT EXISTS plperl`.
- `plpython: true` without `allow_untrusted` → `setup.sh --dry-run` exits non-zero with the untrusted
  message; with `allow_untrusted: true` → `plpython3u` install + `CREATE EXTENSION IF NOT EXISTS
  plpython3u` present.
- languages omitted → neither package nor extension appears (no regression to existing tests).

**New `test/test_functions.sh`** (drives `--apply-functions --dry-run`, no Docker):
- prints the concatenated SQL including the shipped `example_submit.sql` content and the
  `NOTIFY pgrst, 'reload schema'` line.
- multiple files concatenated in sorted order.
- `--apply-functions` + `--update` together → error.
- (Volume-guard refusal is Docker-dependent; covered by the e2e, noted as not unit-testable.)

**Docker e2e** (manual, a plan task): fresh install with `api` enabled; drop a function into
`functions/`; `./setup.sh --apply-functions`; assert it is callable via `POST /rpc/<name>` and
returns the expected result; edit + re-apply to confirm idempotency and live reload. If feasible,
also enable `plperl` at install and apply a trivial `plperl` function to prove a non-default language
works end to end.

## Open implementation choices (non-blocking)

- Whether `--apply-functions` should accept an optional path argument to apply a single file
  (e.g. `--apply-functions functions/foo.sql`). Leaning no for minimal; apply the whole directory.
- Exact name of the example function and its table. Leaning on reusing the documented `submit_*`
  pattern against an existing demo table (e.g. `products`) so it works whenever `document_store` is
  enabled, with a comment noting the dependency.
