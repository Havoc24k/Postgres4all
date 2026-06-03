-- 🗺️ maps (PostGIS GIS stack) — the same distance search, in PL/Python. Identical result.
CREATE OR REPLACE FUNCTION nearby_places_plpython(lon float8, lat float8, k int DEFAULT 5)
RETURNS TABLE(name text, metres real) LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT name, round(ST_DistanceSphere(geom, ST_SetSRID(ST_MakePoint($1,$2),4326))::numeric,1)::real AS metres "
    "FROM places ORDER BY geom <-> ST_SetSRID(ST_MakePoint($1,$2),4326) LIMIT $3",
    ["float8", "float8", "int"])
return plpy.execute(plan, [lon, lat, k])
$fn$;
