INSERT INTO jobs (payload)
SELECT jsonb_build_object('n', g) FROM generate_series(1, 10) AS g;
