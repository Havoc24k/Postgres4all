# 📬 Job queue (replaces Redis/RabbitMQ)

A durable work queue backed by a single Postgres table, with workers dequeuing over the HTTP API.
Each claim is an atomic, contention-free dequeue — `FOR UPDATE SKIP LOCKED` hands every concurrent
worker a *different* pending row — so you get Redis/RabbitMQ-style task distribution without a second
system.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
    "job_queue": true,
    "api": true
  },
  "languages": {
    "plpython": true,
    "allow_untrusted": true
  }
}
```

Build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Load the example's functions

The dequeue is a `SECURITY DEFINER` function — it lets an unprivileged API caller run exactly one
controlled write. Apply this folder's functions with the CLI (it reloads PostgREST's schema cache;
give it a second before calling):

```bash
./postgres4all apply-functions examples/job_queue
```

That loads [claim_job.plpgsql.sql](claim_job.plpgsql.sql) and
[claim_job.plpython.sql](claim_job.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**Native REST — the queue** (seeded with 10 pending jobs):

```bash
curl -s "http://localhost:3000/jobs?select=id,status&order=id&limit=5" | jq
```

```json
[
  {
    "id": 1,
    "status": "pending"
  },
  {
    "id": 2,
    "status": "pending"
  },
  {
    "id": 3,
    "status": "pending"
  },
  {
    "id": 4,
    "status": "pending"
  },
  {
    "id": 5,
    "status": "pending"
  }
]
```

**Claim the next job atomically — PL/pgSQL:**

```bash
curl -s -X POST "http://localhost:3000/rpc/claim_job_plpgsql" -H 'Content-Type: application/json' | jq
```

```json
[
  {
    "id": 1,
    "payload": {
      "n": 1
    },
    "status": "processing",
    "locked_at": "2026-06-03T07:07:33.944891+00:00",
    "created_at": "2026-06-03T07:07:12.953404+00:00"
  }
]
```

**Claim another — PL/Python** — `SKIP LOCKED` skips the row already taken, so a second worker gets a
*different* job:

```bash
curl -s -X POST "http://localhost:3000/rpc/claim_job_plpython" -H 'Content-Type: application/json' | jq
```

```json
[
  {
    "id": 2,
    "payload": {
      "n": 2
    },
    "status": "processing",
    "locked_at": "2026-06-03T07:07:33.961846+00:00",
    "created_at": "2026-06-03T07:07:12.953404+00:00"
  }
]
```

(timestamps and ids will differ on your run)

**Inspect the queue** — the two claimed jobs are now `processing`, the rest still `pending`:

```bash
curl -s "http://localhost:3000/jobs?select=id,status&order=id" | jq
```

```json
[
  {
    "id": 1,
    "status": "processing"
  },
  {
    "id": 2,
    "status": "processing"
  },
  {
    "id": 3,
    "status": "pending"
  },
  {
    "id": 4,
    "status": "pending"
  },
  {
    "id": 5,
    "status": "pending"
  },
  {
    "id": 6,
    "status": "pending"
  },
  {
    "id": 7,
    "status": "pending"
  },
  {
    "id": 8,
    "status": "pending"
  },
  {
    "id": 9,
    "status": "pending"
  },
  {
    "id": 10,
    "status": "pending"
  }
]
```
