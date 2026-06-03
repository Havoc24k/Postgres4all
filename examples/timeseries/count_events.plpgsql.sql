-- 📈 timeseries (a time-series DB) — windowed count over a time range, in PL/pgSQL.
CREATE OR REPLACE FUNCTION count_events_plpgsql(from_ts timestamptz, to_ts timestamptz)
RETURNS bigint LANGUAGE plpgsql STABLE AS $fn$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM events WHERE occurred_at >= from_ts AND occurred_at < to_ts;
    RETURN n;
END;
$fn$;
