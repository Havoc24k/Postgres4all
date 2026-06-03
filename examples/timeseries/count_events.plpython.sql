-- 📈 timeseries (a time-series DB) — the same windowed count, in PL/Python. Identical result.
CREATE OR REPLACE FUNCTION count_events_plpython(from_ts timestamptz, to_ts timestamptz)
RETURNS bigint LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT count(*) AS n FROM events WHERE occurred_at >= $1 AND occurred_at < $2",
    ["timestamptz", "timestamptz"])
return plpy.execute(plan, [from_ts, to_ts])[0]["n"]
$fn$;
