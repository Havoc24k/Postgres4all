-- 📬 job_queue  (replaces Redis / RabbitMQ)  — FOR UPDATE SKIP LOCKED
-- Enable: "capabilities": { "job_queue": true }
-- Run:    psql "$DB_URL" -f examples/job_queue.sql

-- Enqueue a job:
INSERT INTO jobs (payload) VALUES ('{"task":"send_email","to":"a@b.c"}');

-- Claim the next job atomically. Run this in N parallel workers and each gets a
-- DIFFERENT row (SKIP LOCKED steps over rows another worker already holds):
SELECT id, status, payload FROM dequeue_job();

-- Queue state:
SELECT status, count(*) FROM jobs GROUP BY status ORDER BY status;
