-- 📊 dashboards (Snowflake / a warehouse) — the same rollup, in PL/Python. Identical result.
CREATE OR REPLACE FUNCTION daily_rollup_plpython()
RETURNS TABLE(day date, kind text, events bigint) LANGUAGE plpython3u AS $fn$
return plpy.execute("SELECT day::date, kind, n AS events FROM event_daily ORDER BY day, kind")
$fn$;
