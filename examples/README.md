# Examples

One runnable example per capability, against the seeded demo data.

1. Enable the capability (and its deps) in `config.json`, then `./postgres4all install`.
2. Run the example (from the repo root). The `.sql` ones run against the database; the `.sh` ones
   talk to PostgREST on `http://localhost:3000`.

### Run a `.sql` example

The reliable way (runs inside the db container — no host Postgres client needed):

```bash
docker compose --env-file build/.env -f build/docker-compose.yml exec -T db \
  psql -U postgres -d app < examples/document_store.sql
```

…or, if you have `psql` on your host and host→container networking is happy:

```bash
DB_URL="postgres://postgres:$(grep '^POSTGRES_PASSWORD=' build/.env | cut -d= -f2-)@localhost:5432/app"
psql "$DB_URL" -f examples/document_store.sql
```

### All examples

| Example | Capability needed |
|---|---|
| `document_store.sql` | 📄 `document_store` |
| `job_queue.sql` | 📬 `job_queue` |
| `search.sql` | 🔍 `search` |
| `vector.sql` | 🧠 `vector` |
| `gis.sql` | 🗺️ `gis` |
| `timeseries.sql` | 📈 `timeseries` |
| `dashboards.sql` | 📊 `dashboards` + `timeseries` |
| `api.sh` | 🔌 `api` + `document_store` — `bash examples/api.sh` |
| `auth.sh` | 🔐 `auth` + `api` — `bash examples/auth.sh` (needs `openssl` to sign a test JWT) |

Each file's header comment lists the exact capabilities it needs.
