-- 📊 dashboards  (replaces Snowflake / a warehouse)  — materialized views
-- Enable: "capabilities": { "dashboards": true, "timeseries": true }   (dashboards rolls up events)
-- Run:    psql "$DB_URL" -f examples/dashboards.sql

-- Refresh the pre-aggregated rollup WITHOUT blocking readers (needs the unique index,
-- which the dashboards capability creates), then query it like any table:
REFRESH MATERIALIZED VIEW CONCURRENTLY event_daily;

SELECT day, kind, n
FROM event_daily
ORDER BY day, kind;
