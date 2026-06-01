INSERT INTO events (occurred_at, kind)
SELECT TIMESTAMPTZ '2026-06-01' + (g || ' minutes')::interval, 'click'
FROM generate_series(1, 1000) AS g;
