# 🗺️ Maps (replaces a PostGIS GIS stack)

Postgres with PostGIS does geospatial search natively: store points as geometry, index them with
GiST, and answer "what's nearest to me?" over the HTTP API. This example exposes a nearest-neighbour
distance search as an `/rpc` that takes a longitude/latitude and returns the closest places with
their distance in metres.

## Prerequisites

Enable this in `config.json` (PL/Python powers the second implementation):

```jsonc
{
  "capabilities": {
    "gis": true,
    "api": true
  },
  "languages": {
    "plpython": true,
    "allow_untrusted": true
  }
}
```

Build and start the stack (see [../README.md](../README.md) for full setup):

```bash
./postgres4all install
```

## Load the example's functions

Apply this folder's `/rpc` functions with the CLI and it reloads
PostgREST's schema cache (give it a second before calling):

```bash
./postgres4all apply-functions examples/gis
```

That loads [nearby_places.plpgsql.sql](nearby_places.plpgsql.sql) and
[nearby_places.plpython.sql](nearby_places.plpython.sql).

## Call the API

Responses are piped through `jq` to pretty-print them.

**Nearest places to a point — PL/pgSQL** (`<->` is the GiST-indexed KNN distance operator;
`ST_DistanceSphere` returns metres):

```bash
curl -s -X POST "http://localhost:3000/rpc/nearby_places_plpgsql" \
  -H 'Content-Type: application/json' -d '{"lon":-122.41,"lat":37.78}' | jq
```

```json
[
  {
    "name": "Cafe B",
    "metres": 562.7
  },
  {
    "name": "Cafe A",
    "metres": 1002.1
  }
]
```

The PL/Python variant (`/rpc/nearby_places_plpython`) returns the identical result.
