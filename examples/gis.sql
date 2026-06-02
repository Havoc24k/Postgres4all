-- 🗺️ gis  (replaces GIS systems)  — PostGIS + GiST spatial index
-- Enable: "capabilities": { "gis": true }
-- Run:    psql "$DB_URL" -f examples/gis.sql

-- Nearest places to a point, with the real distance in metres. The <-> operator in
-- ORDER BY uses the places_geom_gist index for an index-assisted nearest-neighbour scan.
SELECT name,
       round(ST_DistanceSphere(geom, ST_SetSRID(ST_MakePoint(-122.41, 37.78), 4326))::numeric, 1) AS metres
FROM places
ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-122.41, 37.78), 4326)
LIMIT 5;
