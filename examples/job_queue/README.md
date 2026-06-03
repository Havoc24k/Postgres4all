# 📬 Job queue (replaces Redis/RabbitMQ)

A durable work queue backed by a single Postgres table, with workers dequeuing jobs over the HTTP API. Each claim is an atomic, contention-free dequeue — `FOR UPDATE SKIP LOCKED` hands every concurrent worker a *different* pending row — so you get Redis/RabbitMQ-style task distribution without a second system.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "job_queue": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/job_queue/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## The queue

PostgREST exposes the `jobs` table directly, so a plain `select` over HTTP shows the seeded backlog — ten rows, all `pending`.

```bash
curl -s "http://localhost:3000/jobs?select=id,status&order=id&limit=5"; echo
```

```json
[{"id":1,"status":"pending"}, 
 {"id":2,"status":"pending"}, 
 {"id":3,"status":"pending"}, 
 {"id":4,"status":"pending"}, 
 {"id":5,"status":"pending"}]
```

## Claim the next job (PL/pgSQL)

Dequeuing needs a function: the atomic "find one pending row, lock it, flip it to `processing`, return it" can't be expressed as a single REST write, so a `SECURITY DEFINER` function exposed at `/rpc` runs that controlled write for the unprivileged caller.

```bash
curl -s -X POST "http://localhost:3000/rpc/claim_job_plpgsql" -H 'Content-Type: application/json'; echo
```

```json
[{"id":1,"payload":{"n": 1},"status":"processing","locked_at":"2026-06-03T06:32:33.886558+00:00","created_at":"2026-06-03T06:27:41.143102+00:00"}]
```

(timestamps and ids will differ on your run)

## Claim another (PL/Python)

A second worker calls the PL/Python variant; `FOR UPDATE SKIP LOCKED` skips the row the first claim already took, so this call returns a *different* job.

```bash
curl -s -X POST "http://localhost:3000/rpc/claim_job_plpython" -H 'Content-Type: application/json'; echo
```

```json
[{"id":2,"payload":{"n": 2},"status":"processing","locked_at":"2026-06-03T06:32:33.895971+00:00","created_at":"2026-06-03T06:27:41.143102+00:00"}]
```

(timestamps and ids will differ on your run)

## Inspect the queue state

A final `select` confirms the result: the two claimed jobs are now `processing` and the remaining eight are still `pending`.

```bash
curl -s "http://localhost:3000/jobs?select=id,status&order=id"; echo
```

```json
[{"id":1,"status":"processing"}, 
 {"id":2,"status":"processing"}, 
 {"id":3,"status":"pending"}, 
 {"id":4,"status":"pending"}, 
 {"id":5,"status":"pending"}, 
 {"id":6,"status":"pending"}, 
 {"id":7,"status":"pending"}, 
 {"id":8,"status":"pending"}, 
 {"id":9,"status":"pending"}, 
 {"id":10,"status":"pending"}]
```

(ids will differ on your run)

## The two implementations

[claim_job.plpgsql.sql](claim_job.plpgsql.sql) and [claim_job.plpython.sql](claim_job.plpython.sql) implement the same atomic dequeue and return identically — one in PL/pgSQL, one in PL/Python. In a real project these would live in `functions/` and be applied with `./postgres4all apply-functions`.
