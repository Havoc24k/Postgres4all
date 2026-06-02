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
- Granting `EXECUTE … TO anon, authenticated` only works when `api` is enabled (those roles exist
  only then). The shipped `example_submit.sql` therefore needs `document_store`, `job_queue`, AND
  `api`; its grant is guarded so it still applies cleanly without `api`.
- **Deleting a function file does NOT drop the function from the database** — run
  `DROP FUNCTION <name>(<args>)` yourself if you want it gone.
