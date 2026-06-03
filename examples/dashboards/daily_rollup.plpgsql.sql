-- 📊 dashboards (Snowflake / a warehouse) — read the materialized daily rollup, in PL/pgSQL.
-- Handy when you want to shape/relabel the pre-aggregated event_daily matview.
CREATE OR REPLACE FUNCTION daily_rollup_plpgsql()
RETURNS TABLE(day date, kind text, events bigint) LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY SELECT e.day::date, e.kind, e.n FROM event_daily e ORDER BY e.day, e.kind;
END;
$fn$;
