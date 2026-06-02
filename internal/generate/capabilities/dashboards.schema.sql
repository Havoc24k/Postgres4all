-- dashboards: Snowflake -> materialized view (requires timeseries' events table)
CREATE MATERIALIZED VIEW event_daily AS
    SELECT date_trunc('day', occurred_at) AS day,
           kind,
           count(*) AS n
    FROM events
    GROUP BY 1, 2
    WITH DATA;
CREATE UNIQUE INDEX event_daily_pk ON event_daily (day, kind);
