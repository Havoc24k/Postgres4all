# 🗺️ Maps (replaces a PostGIS GIS stack)

Postgres with PostGIS does geospatial search natively: store points as geometry, index them with GiST, and answer "what's nearest to me?" over the HTTP API. This example exposes a nearest-neighbour distance search as a `/rpc` endpoint that takes a longitude/latitude and returns the closest places with their distance in metres.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": { "gis": true, "api": true },
  "languages": { "plpython": true, "allow_untrusted": true }
}
```

Then build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Run it

```bash
bash examples/gis/run.sh
```

Or follow the steps below by hand against `http://localhost:3000`.

## Nearest cafes via /rpc — PL/pgSQL

The `<->` GiST-indexed KNN distance operator orders rows by proximity and `ST_DistanceSphere` returns the gap in metres; it lives in a function because PostgREST exposes callable SQL as `/rpc` endpoints.

```bash
curl -s -X POST "http://localhost:3000/rpc/nearby_places_plpgsql" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}'
```

```json
[{"name":"Cafe B","metres":562.7}, 
 {"name":"Cafe A","metres":1002.1}]
```

## Same via /rpc — PL/Python (identical)

The same nearest-neighbour query, implemented in PL/Python with a prepared plan, returns the identical result through its own `/rpc` endpoint.

```bash
curl -s -X POST "http://localhost:3000/rpc/nearby_places_plpython" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}'
```

```json
[{"name":"Cafe B","metres":562.7}, 
 {"name":"Cafe A","metres":1002.1}]
```

## The two implementations

[nearby_places.plpgsql.sql](nearby_places.plpgsql.sql) and [nearby_places.plpython.sql](nearby_places.plpython.sql) implement the same nearest-neighbour search two ways and return identically. In a real project they'd live in `functions/` and be applied with `./postgres4all apply-functions`.
