-- timeseries: declarative partitioning + BRIN
CREATE TABLE events (
    occurred_at timestamptz NOT NULL,
    kind        text        NOT NULL,
    data        jsonb       NOT NULL DEFAULT '{}'::jsonb
) PARTITION BY RANGE (occurred_at);

CREATE TABLE events_2026_06 PARTITION OF events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE events_2026_07 PARTITION OF events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

CREATE INDEX events_brin ON events USING brin (occurred_at);
