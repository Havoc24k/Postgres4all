# functions/

Drop your business-logic SQL here. Each `.sql` file should contain `CREATE OR REPLACE FUNCTION …`
plus a `GRANT EXECUTE … TO anon|authenticated|<role>`. PostgREST exposes any function in the
`public` schema at `POST /rpc/<name>` (or `GET` if the function is marked `STABLE`/`IMMUTABLE`).

Apply them to a running install (idempotent, all-or-nothing, reloads PostgREST):

    ./postgres4all apply-functions

Preview without applying:

    ./postgres4all apply-functions --dry-run

## `SECURITY DEFINER` and ownership

A function that does privileged writes on behalf of an unprivileged caller (`anon`/`authenticated`,
who only hold `SELECT`) must be declared `SECURITY DEFINER` with a pinned `SET search_path = public,
pg_temp`. A `SECURITY DEFINER` function runs with the privileges of its **owner**, so the owner must
not be the superuser.

You don't manage that ownership. `apply-functions` runs your SQL under `SET ROLE api_owner` — a
non-superuser role (created when `api` is enabled, recorded as `P4A_FUNCTION_OWNER` in `build/.env`)
that holds DML on the app tables but no superuser rights. So:

- Keep your files plain — just `CREATE OR REPLACE FUNCTION …` + `GRANT EXECUTE …`. **No `ALTER …
  OWNER` lines.** The function is owned by `api_owner` by construction.
- The definer runs as that scoped role, never the superuser, so row-level security (e.g. on `notes`)
  is **not** bypassed.
- `apply-functions` prints an advisory (non-blocking) warning for any `SECURITY DEFINER` function
  missing `SET search_path` — the one safety step the tool can't do for you.

Notes:
- Use `CREATE OR REPLACE` so re-applying is safe — that's how you ship edits. (A function an older
  install created as the superuser can't be replaced *as* `api_owner` — `DROP FUNCTION` it once as
  the superuser, then re-apply.)
- All files are applied in one transaction; a syntax error in any file rolls everything back.
- A function written in a non-default language (e.g. `plperl`) needs that language enabled in
  `config.json`'s `languages` block at install time.
- Granting `EXECUTE … TO anon, authenticated` only works when `api` is enabled (those roles exist
  only then). The shipped `example_submit.sql` therefore needs `document_store`, `job_queue`, AND
  `api`; its grant is guarded so it still applies cleanly without `api`.
- **Deleting a function file does NOT drop the function from the database** — run
  `DROP FUNCTION <name>(<args>)` yourself if you want it gone.
