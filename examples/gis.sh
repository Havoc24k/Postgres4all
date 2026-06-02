#!/usr/bin/env bash
# 🗺️ maps (replaces a PostGIS GIS stack) — nearest-neighbour search over the API.
# Enable: { "gis": true, "api": true, "languages": { "plpython": true, "allow_untrusted": true } }
# Run:    bash examples/gis.sh
source "$(dirname "$0")/lib.sh"

# Distance-ranked search (ORDER BY geom <-> point, distance in metres) is parametrized geometry,
# so it's an /rpc function — in BOTH languages. '<->' is the GiST-indexed KNN distance operator.
define_sql <<'SQL'
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

CREATE OR REPLACE FUNCTION nearby_places_plpython(lon float8, lat float8, k int DEFAULT 5)
RETURNS TABLE(name text, metres real) LANGUAGE plpython3u AS $fn$
plan = plpy.prepare(
    "SELECT name, round(ST_DistanceSphere(geom, ST_SetSRID(ST_MakePoint($1,$2),4326))::numeric,1)::real AS metres "
    "FROM places ORDER BY geom <-> ST_SetSRID(ST_MakePoint($1,$2),4326) LIMIT $3",
    ["float8", "float8", "int"])
return plpy.execute(plan, [lon, lat, k])
$fn$;
SQL

echo "# Cafes nearest to (-122.41, 37.78) — PL/pgSQL (Cafe B ≈ 562 m, Cafe A ≈ 1002 m):"
curl -s -X POST "$BASE/rpc/nearby_places_plpgsql" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}'; echo
echo "# …and PL/Python (identical):"
curl -s -X POST "$BASE/rpc/nearby_places_plpython" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}'; echo
