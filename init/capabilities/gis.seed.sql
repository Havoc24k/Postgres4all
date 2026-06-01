INSERT INTO places (name, geom) VALUES
    ('Cafe A', ST_SetSRID(ST_MakePoint(-122.4194, 37.7749), 4326)),
    ('Cafe B', ST_SetSRID(ST_MakePoint(-122.4084, 37.7849), 4326));
