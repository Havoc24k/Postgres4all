-- 🗺️ maps (PostGIS GIS stack) — nearest-neighbour distance search, in PL/pgSQL.
-- '<->' is the GiST-indexed KNN distance operator; ST_DistanceSphere returns metres.
CREATE OR REPLACE FUNCTION nearby_places_plpgsql(lon float8, lat float8, k int DEFAULT 5)
RETURNS TABLE(name text, metres real) LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN QUERY
    SELECT p.name,
           round(ST_DistanceSphere(p.geom, ST_SetSRID(ST_MakePoint(lon, lat), 4326))::numeric, 1)::real
    FROM places p
    ORDER BY p.geom <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)
    LIMIT k;
END;
$fn$;
