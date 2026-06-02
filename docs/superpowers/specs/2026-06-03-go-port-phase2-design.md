# Go port — Phase 2: the `update` delta engine

**Date:** 2026-06-03
**Status:** Approved (user directed "proceed all phases"); behavior defined by the bash `--update`.
**Behavioral reference:** `setup.sh` `--update` and `docs/superpowers/specs/2026-06-02-capability-update-path-design.md`. This is a PORT — the Go output must be behaviorally equivalent.

## Goal

`postgres4all update [--allow-drop]` (+ `update --dry-run --installed "<csv>"`) replaces the bash
`--update` path: diff the config against the installed capabilities recorded in `p4a_meta.capabilities`
and apply the delta in phases without data loss. Replaces the Phase-1 `update` stub.

## Scope

- `update` (additive) and `update --allow-drop` (additive + destructive removal).
- `update --dry-run --installed "<csv>"` — print the plan + per-phase delta SQL, no Docker/DB (the
  unit-test seam, mirroring bash `test_update.sh`).
- Secret preservation: reuse existing `build/.env` secrets on update (regenerating breaks PostgREST's
  stored authenticator password).
- The same phased execution as bash: Phase 0 idempotent roles (if `api` newly added) → Phase 1 drops
  (if `--allow-drop` and REMOVE non-empty) → Phase 2 rebuild+recreate (volume preserved, `--remove-orphans`,
  buildkit fallback) → Phase 3 adds; each a single `psql --single-transaction`; NOTIFY/restart postgrest
  on api add.

## Non-goals

- No `apply-functions` (Phase 3). No retirement of bash `setup.sh`.
- No new behavior beyond bash `--update`.

## New / changed Go units

- **`internal/update`** (new): pure delta logic + SQL emission, fully unit-testable.
  - `Delta(target *config.Config, installed []string) (add, remove []string)` — canonical-order diff.
  - `EmitPreSQL(cfg, add) string` — idempotent role `DO`-blocks (only when api in add); reads the
    authenticator password from a passed-in value (sourced from `build/.env`).
  - `EmitAddSQL(cfg, add, installed) string` — extensions + schema fragments (+ seed if `cfg.Seed()`) +
    grants (grant-after-create; api-add grants installed tables, loop grants new tables) + meta inserts.
  - `EmitRemoveSQL(cfg, remove) string` — drop fragments + DROP EXTENSION + (api) REVOKE-before-DROP ROLE
    + meta deletes, reverse canonical order.
  - Reuses `internal/generate`'s embedded `capabilitiesFS` (schema/seed/drop fragments) and the
    extension/read-table maps (hoist those maps to a shared location, e.g. `internal/generate` exported,
    or a small `internal/caps` package — implementation decides; avoid duplication).
- **`internal/dockerx`** (extend): `ApplySQL(dir, user, db string, sql string) error` (psql
  `-v ON_ERROR_STOP=1 --single-transaction` via stdin through `compose exec -T db`), `QueryInstalled` (read
  `p4a_meta.capabilities`), `WaitHealthy`, `BuildUp` (up -d --build --remove-orphans + DOCKER_BUILDKIT=0
  fallback), `UpDB` (up -d --remove-orphans db), `RestartPostgrest`, `EnvValue(dir, key)` (read build/.env).
- **`cmd/postgres4all/update.go`** (replace stub): flags `--config`, `--allow-drop`, `--dry-run`,
  `--installed`; the orchestration (validate target, secret preservation via regenerating build/ with
  reused secrets, determine installed, compute delta, refuse REMOVE without `--allow-drop`, up-to-date
  short-circuit, dry-run print, else phased execution).

## Data flow (mirrors bash)

```
config.json -> Load+Validate (target) -> regenerate build/ reusing existing build/.env secrets
            -> installed = --installed csv OR QueryInstalled(live db)
            -> add/remove = Delta(target, installed); refuse remove w/o --allow-drop; up-to-date if empty
dry-run: print plan + "===== PRE/REMOVE/ADD =====" sections -> exit
live: UpDB+WaitHealthy -> [Phase0 EmitPreSQL|ApplySQL if api added]
     -> [Phase1 EmitRemoveSQL|ApplySQL if remove] -> BuildUp+WaitHealthy
     -> [Phase3 EmitAddSQL|ApplySQL if add; RestartPostgrest if api added]
```

## Secret preservation

Before regenerating `build/`, capture the existing `build/.env` `POSTGRES_PASSWORD`/`AUTHENTICATOR_PASSWORD`/
`JWT_SECRET`; feed them as the resolved secrets so `Generate` reuses them (config value > existing > random).
This requires `Generate` (Phase 1) to accept caller-provided secret overrides — add a small
`GenerateWithSecrets(cfg, outDir, sec Secrets)` or pre-populate the config's secret fields before calling
`Generate`. Simplest: the update command reads old secrets, writes them into the in-memory `config` (Password,
API.AuthenticatorPassword, API.JWTSecret) before `Generate`, so `Generate`'s "from config" path uses them.

## Error handling

- `--allow-drop`/`--installed` require `update` (they're flags on the `update` subcommand, so this is moot;
  cobra scopes them). REMOVE non-empty without `--allow-drop` → error listing the caps.
- `--dry-run` without `--installed` → error (no live DB to query in dry-run) — mirrors bash.
- No existing install (no pgdata volume) on a live update → error "run install first".
- Each phase via `ApplySQL` is `ON_ERROR_STOP=1 --single-transaction` (atomic; rolls back on failure).

## Testing

- **`internal/update` unit tests**: `Delta` table tests (add/remove computation, canonical order); golden
  tests for `EmitPreSQL`/`EmitAddSQL`/`EmitRemoveSQL` across the same scenarios as bash `test_update.sh`
  (new data cap, api-add grant split, create-before-grant ordering, remove revoke-before-drop, etc.).
- **`cmd` dry-run test** (optional): `postgres4all update --dry-run --installed ...` prints the plan +
  sections; assert via a small exec test or by calling the command's RunE with buffers.
- **Docker e2e** (a plan task): install document_store; insert sentinel; `postgres4all update` to add vector
  → data preserved + documents exists; add api+search → PostgREST serves; remove vector `--allow-drop`.
  Mirrors the bash update e2e, driving the Go binary.
- Bash `setup.sh` + `test_update.sh` stay green (coexistence); the Go `update` operates on the same
  `build/` + `p4a_meta` format.

## Open choices (non-blocking)

- Where the extension/read-table maps + canonical order live so both `generate` and `update` use one copy
  (export from `generate`, or a tiny shared `internal/caps`). Leaning: export the maps from `internal/generate`.
- Whether `update` regenerates the full `build/` (simplest, matches bash) or only what phases need. Leaning:
  full regenerate (bash does this), reusing secrets.
