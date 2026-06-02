# Go port — Phase 1: config + generation + install

**Date:** 2026-06-02
**Status:** Approved design, pending spec review
**Part of:** a phased rewrite of `setup.sh` (bash) into a Go CLI. This spec covers **Phase 1 only**
(config + `build/` generation + `install`). Phase 2 = `update` delta engine; Phase 3 =
`apply-functions` + language toggles. Each phase is a separately spec'd, shippable increment.

## Problem

`setup.sh` has grown to ~547 lines of bash doing config parsing, file templating, Docker
orchestration, a delta engine, and a functions layer. Bash is straining where it's weakest:
`set -e` footguns, `${}` escaping bugs, no data structures, `echo`-based templating, per-field `jq`
subprocesses, and untestable-except-via-`--dry-run`. We are porting to Go for types, real templating,
a proper subcommand CLI, and a single static binary.

## Goals (Phase 1)

- A Go module producing a `postgres4all` binary with a Cobra CLI.
- `postgres4all generate` — load + validate `config.json`, write the `build/` tree, no Docker.
- `postgres4all install` — generate, refuse if an install already exists, then `docker compose up --build`.
- Typed config with one-pass validation (replaces the `jq` calls and scattered `die`s).
- Generated `build/` stays **format-compatible** with what bash `setup.sh` produces, so the
  not-yet-ported bash `--update` / `--apply-functions` still work against a Go-generated install.
- Single static binary: SQL fragments and templates embedded via `//go:embed`.

## Non-goals (Phase 1)

- No `update` (delta engine) — Phase 2.
- No `apply-functions` / language toggles execution — Phase 3 (though the config struct may already
  carry the `languages` block; generation of language apt/extension lines is included since it's part
  of `generate`/`install`, see "Open choices").
- No removal of `setup.sh` or the bash test suites — they coexist until all phases land and the Go
  binary is validated end-to-end.
- No byte-for-byte identical output vs bash — behavioral/format equivalence only.
- No new runtime features beyond what `setup.sh install` + `--dry-run` already do.

## Module & package layout

```
go.mod                              # module github.com/Havoc24k/postgres4all; Go 1.23+
cmd/postgres4all/main.go            # cobra rootCmd; wires generate + install; version
internal/
  config/
    config.go                       # Config struct; Load(path) (encoding/json); Validate()
    config_test.go                  # table-driven accept/reject cases
  generate/
    generate.go                     # Generate(cfg, outDir) -> writes build/ tree
    templates/
      Dockerfile.tmpl               # //go:embed; base image, ext installs, language pkgs, COPY init/
      docker-compose.yml.tmpl       # //go:embed; db always, postgrest if api
      env.tmpl                      # //go:embed; POSTGRES_*, AUTHENTICATOR_PASSWORD/JWT if api
    capabilities/                   # //go:embed *.sql (copied/moved from init/capabilities/)
    generate_test.go                # golden-file tests
    testdata/golden/<case>/         # committed expected build/ trees
  dockerx/
    dockerx.go                      # Compose(args...) via os/exec; VolumeName(); VolumeExists()
  secrets/
    secrets.go                      # Hex(nBytes) using crypto/rand
```

**Embedding:** the per-capability `.sql` fragments currently in `init/capabilities/` are embedded into
the binary (a copy lives under `internal/generate/capabilities/`, kept in sync — or `go:embed`
reaches the repo-root `init/capabilities` via a build-time copy step; implementation picks one). The
three artifact templates (Dockerfile, compose, .env) become `text/template` files, also embedded.

## Config (typed)

```go
type Config struct {
    Postgres     PostgresCfg            `json:"postgres"`
    SeedDemoData *bool                  `json:"seed_demo_data"` // pointer: nil => default true
    Capabilities map[string]bool        `json:"capabilities"`
    API          APICfg                 `json:"api"`
    Languages    LanguagesCfg           `json:"languages"`
}
type PostgresCfg struct { User, DB, Password string; PublishExternally bool `json:"publish_externally"` }
type APICfg       struct { AuthenticatorPassword string `json:"authenticator_password"`; JWTSecret string `json:"jwt_secret"` }
type LanguagesCfg struct { PLPerl, PLPython, AllowUntrusted bool }
```

- `Load(path)`: read file, `json.Unmarshal`. Unknown top-level capability keys → a validation warning
  (not silently ignored — the bash version silently ignored them; the redesign improves this).
- Defaults: `Postgres.User` → `"postgres"`, `Postgres.DB` → `"app"`, `SeedDemoData` nil → `true`.
- `Validate()` returns a typed error listing ALL problems (not just the first):
  - at least one capability enabled;
  - `dashboards` requires `timeseries`; `auth` requires `api`;
  - `plpython` requires `languages.allow_untrusted` (untrusted gating);
  - unknown capability keys (warning).
- The canonical capability list and the extension/read-table/language maps live as Go constants/maps
  in `config` or `generate` (single source of truth), replacing the bash arrays.

## Generation (`generate.Generate(cfg, outDir)`)

Writes, into `outDir` (default `build/`), behavior-matching the current bash generator:

- `Dockerfile` — base `postgres:17` unless `gis` → `postgis/postgis:17-3.5`; pgvector apt if `vector`;
  pg_graphql `.deb` (arch-aware) if `api`; language packages `postgresql-plperl-17` /
  `postgresql-plpython3-17` (lang-then-version) if enabled; `COPY init/ ...`.
- `init/01-extensions.sql` — `CREATE EXTENSION IF NOT EXISTS` for the enabled set + languages.
- `init/02-schema.sql` — enabled capability `schema.sql` (+ `seed.sql` if seeding) in canonical order
  (`timeseries` before `dashboards`).
- `init/00-roles.sh` + `init/03-api-grants.sql` — only if `api`; grants scoped to existing tables.
- `init/04-meta.sql` — `p4a_meta.capabilities` + inserts (always).
- `docker-compose.yml` — `db` always; `postgrest` only if `api`; ports bound to `127.0.0.1` unless
  `publish_externally`.
- `.env` — `POSTGRES_*` always; `AUTHENTICATOR_PASSWORD`/`JWT_SECRET` if `api`; secrets from config or
  `secrets.Hex(...)`; written `0600`.

Pinned versions (`PG_MAJOR=17`, PostGIS `3.5`, `PG_GRAPHQL_VERSION=1.5.11`, PostgREST `v12.2.3`) are Go
constants. The image tag is `postgres4all:generated` (matches the bash version, so compose/build agree).

## Commands (Cobra)

- `postgres4all generate [--config config.json] [--out build/]`
  → `config.Load` → `Validate` → `generate.Generate` → print what was written. No Docker. Exit non-zero
  with the aggregated validation error on bad config.
- `postgres4all install [--config config.json]`
  → generate → if the pgdata volume already exists (`dockerx.VolumeExists`), refuse with guidance →
  else `docker compose --env-file build/.env -f build/docker-compose.yml up --build` (foreground).
- Root command: `--help`, `--version`. `update` and `apply-functions` may be registered as stubs that
  print "not yet implemented (Phase 2/3)" or omitted; pick one in the plan.

## Docker interaction (`dockerx`)

Thin `os/exec` wrappers — no Docker SDK:
- `Compose(ctx, args...)` runs `docker compose --env-file build/.env -f build/docker-compose.yml <args>`
  with stdout/stderr streamed.
- `VolumeName()` parses `docker compose ... config --format json` for `.volumes.pgdata.name`.
- `VolumeExists(name)` runs `docker volume inspect`.
- Preflight: `docker`, `docker compose` availability (install path only).
- The buildx-<0.17 fallback (legacy `DOCKER_BUILDKIT=0 docker build`) is carried over.

## Error handling

- Missing/invalid config file → clear typed error, exit non-zero.
- `Validate()` aggregates all violations into one message.
- `install` on an existing pgdata volume → refuse, point to (future) `update` / `down -v`.
- Generation failures (template exec, file write) → wrapped errors with context (`fmt.Errorf("%w")`).
- Docker command failures → surfaced with the command's stderr.

## Testing strategy

- **`config_test.go`** — table-driven: valid configs; each rejection (zero caps, `auth` without `api`,
  `dashboards` without `timeseries`, `plpython` without `allow_untrusted`); defaults applied; unknown
  capability key warned.
- **`generate_test.go`** — golden-file: for representative configs (minimal `document_store`;
  `gis`-only base swap; `api`+`auth`; `vector`; all-on; languages on), call `Generate` into a temp dir
  and compare the tree to `testdata/golden/<case>/`. A `-update` test flag regenerates goldens.
- **Format-compatibility check** — at least one golden is cross-checked (by inspection during
  implementation, documented) against the bash `setup.sh --dry-run` output for the same config to
  confirm `.env` keys, compose services, and init filenames match (behavioral equivalence).
- **E2E (manual, a plan task)** — `go build ./cmd/postgres4all`; `postgres4all generate` a config;
  `docker build` (legacy builder for old buildx) + compose up (or `postgres4all install`); confirm the
  stack boots and one capability works (e.g. JSONB query / `curl /products` when `api`).
- The bash suites stay green and untouched (coexistence).

## Open implementation choices (non-blocking)

- **Embed source for capability fragments:** embed the existing `init/capabilities/*.sql` directly
  (a `go:embed` path that reaches repo-root, requiring the Go files to sit where embed can see them or
  a small generate step) vs keep a synced copy under `internal/generate/capabilities/`. Leaning: a
  copy under `internal/` that `go:embed` owns, with a note that `init/capabilities/` remains the bash
  source until bash is retired (the two are kept in sync during the port; a test can assert they match).
- **Whether `generate`/`install` already emit the `languages` apt/extension lines in Phase 1** (they
  are part of generation) or defer to Phase 3. Leaning: include them in generation now (it's pure
  output), and defer only the `apply-functions` runtime to Phase 3.
- **Stub vs omit `update`/`apply-functions` subcommands** in the Phase-1 binary. Leaning: register them
  as stubs that exit with "implemented in a later phase; use ./setup.sh for now" so the CLI shape is
  stable and users are pointed at the bash fallback.
- **Module path** assumes `github.com/Havoc24k/postgres4all`; binary name `postgres4all`. Confirm at
  implementation if a different path is wanted.
