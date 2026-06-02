-- job_queue: Redis/RabbitMQ -> FOR UPDATE SKIP LOCKED
CREATE TABLE jobs (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload    jsonb       NOT NULL,
    status     text        NOT NULL DEFAULT 'pending',
    locked_at  timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_pending_idx ON jobs (created_at) WHERE status = 'pending';

CREATE OR REPLACE FUNCTION dequeue_job()
RETURNS jobs
LANGUAGE sql AS $$
    UPDATE jobs
       SET status = 'processing', locked_at = now()
     WHERE id = (
         SELECT id FROM jobs
          WHERE status = 'pending'
          ORDER BY created_at
          FOR UPDATE SKIP LOCKED
          LIMIT 1
     )
    RETURNING *;
$$;
