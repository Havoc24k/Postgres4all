-- 📈 timeseries  (replaces a time-series DB)  — declarative partitioning + BRIN index
-- Enable: "capabilities": { "timeseries": true }
-- Run:    psql "$DB_URL" -f examples/timeseries.sql

-- Count events in a time window. On append-only, time-ordered data the BRIN index makes
-- this a tiny scan (a few pages) instead of a full table scan:
SELECT count(*)
FROM events
WHERE occurred_at >= '2026-06-01' AND occurred_at < '2026-06-02';

-- Per-hour rollup:
SELECT date_trunc('hour', occurred_at) AS hour, count(*)
FROM events
GROUP BY 1
ORDER BY 1
LIMIT 5;
