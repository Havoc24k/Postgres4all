-- gis: PostGIS + GiST
CREATE TABLE places (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    geom geometry(Point, 4326) NOT NULL
);
CREATE INDEX places_geom_gist ON places USING gist (geom);
