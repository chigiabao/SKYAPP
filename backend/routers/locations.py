"""
Location API endpoints: the 168 wards/communes of new Ho Chi Minh City (+ the 'tsn' training point),
accent-insensitive search, nearest ward for a GPS point, and the boundary / ward GeoJSON.

Data: the locations table, loaded at startup from data/locations/*.json (database.load_locations);
polygons are read from data/locations/*.geojson.
"""
import hashlib
import json
import math
import unicodedata
from functools import lru_cache
from typing import List, Optional

from fastapi import APIRouter, HTTPException, Query, Request, Response
from pydantic import BaseModel

import database
from database import DEFAULT_LOCATION_ID, execute_query
from models import LocationInfo

router = APIRouter(prefix="/locations", tags=["locations"])

OUTSIDE_DETAIL = "Ngoài vùng hỗ trợ (TP.HCM)"
SEARCH_LIMIT = 20
GEOJSON_MAX_AGE = 86400   # seconds; the files only change when scripts/build_locations.py is re-run


# Default location: Ho Chi Minh City (near Tan Son Nhat airport)
DEFAULT_LOCATION = LocationInfo(
    latitude=10.7909,
    longitude=106.6313,
    name="Ho Chi Minh City",
    timezone="Asia/Ho_Chi_Minh"
)


class Location(BaseModel):
    id: str
    name: str
    kind: Optional[str] = None       # phuong | xa | dac_khu | training_point ('tsn')
    region: Optional[str] = None     # former province (TP.HCM cũ, Bình Dương cũ, Bà Rịa–Vũng Tàu cũ)
    lat: float
    lon: float
    cell_id: Optional[str] = None


class NearestLocation(Location):
    method: str                      # "polygon" (point inside the ward) | "nearest" (closest ward point)
    distance_km: float               # from the query point to the ward's point


def all_locations() -> List[dict]:
    rows = execute_query("SELECT id, name, kind, region, lat, lon, cell_id FROM locations ORDER BY id")
    return [dict(r) for r in rows]


def fold(text: str) -> str:
    """Lower-case, strip Vietnamese diacritics (đ -> d), collapse non-alphanumerics to single spaces."""
    text = text.lower().replace("đ", "d")
    text = "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")
    return " ".join("".join(c if c.isalnum() else " " for c in text).split())


_KIND_PREFIXES = ("phuong ", "xa ", "dac khu ")


def _rank(q: str, name: str) -> Optional[int]:
    """0 exact, 1 prefix, 2 word-prefix, 3 substring, None = no match. The name is also tried without its
    kind prefix ("Phường Thủ Đức" matches "thu duc" exactly)."""
    names = [name] + [name[len(p):] for p in _KIND_PREFIXES if name.startswith(p)]
    best = None
    for n in names:
        if n == q:
            r = 0
        elif n.startswith(q):
            r = 1
        elif f" {q}" in f" {n}":
            r = 2
        elif q in n:
            r = 3
        else:
            continue
        best = r if best is None else min(best, r)
    return best


@router.get("/current", response_model=LocationInfo)
async def get_current_location():
    """Legacy: the fixed HCMC point (Tan Son Nhat)."""
    return DEFAULT_LOCATION


@router.get("", response_model=List[Location])
@router.get("/", response_model=List[Location], include_in_schema=False)
def list_locations():
    """All supported locations: 168 wards/communes of new HCMC + 'tsn' (AI training point)."""
    return all_locations()


@router.get("/search", response_model=List[Location])
def search_locations(q: str = Query(..., min_length=1, max_length=100, description="Tên phường/xã, có dấu hoặc không")):
    """Accent-insensitive name search. Ranking: exact, prefix, word-prefix, substring; then name. Max 20."""
    fq = fold(q)
    if not fq:
        return []
    hits = []
    for loc in all_locations():
        r = _rank(fq, fold(loc["name"]))
        if r is None:
            r = _rank(fq, fold(loc["id"]))
            r = None if r is None else r + 0.5   # id-only matches rank after name matches of the same kind
        if r is not None:
            hits.append((r, loc["id"] == DEFAULT_LOCATION_ID, fold(loc["name"]), loc))
    hits.sort(key=lambda h: h[:3])
    return [h[3] for h in hits[:SEARCH_LIMIT]]


# --- Geometry -----------------------------------------------------------------------------------------

def _read_geojson(name: str) -> bytes:
    path = database.LOCATIONS_DIR / name
    if not path.exists():
        raise HTTPException(status_code=503, detail=f"Thiếu dữ liệu {name}")
    return path.read_bytes()


def _point_in_ring(x: float, y: float, ring) -> bool:
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


class _Geom:
    """Point-in-polygon for a GeoJSON Polygon/MultiPolygon: shapely if installed, else ray casting."""

    def __init__(self, geometry: dict):
        self.geometry = geometry
        try:
            from shapely.geometry import shape
            from shapely.prepared import prep
            self._shape = prep(shape(geometry))
        except ImportError:   # pragma: no cover - shapely is optional
            self._shape = None

    def contains(self, lon: float, lat: float) -> bool:
        if self._shape is not None:
            from shapely.geometry import Point
            return self._shape.covers(Point(lon, lat))
        polys = self.geometry["coordinates"]
        if self.geometry["type"] == "Polygon":
            polys = [polys]
        for poly in polys:
            if _point_in_ring(lon, lat, poly[0]) and not any(_point_in_ring(lon, lat, h) for h in poly[1:]):
                return True
        return False


@lru_cache(maxsize=4)
def _geoms(path_key: str):
    """(boundary geometries, [(ward id, geometry)]) for the files under `path_key` (cache key = directory)."""
    boundary = json.loads(_read_geojson("hcmc_boundary.geojson"))
    wards = json.loads(_read_geojson("wards.geojson"))
    feats = boundary["features"] if boundary.get("type") == "FeatureCollection" else [boundary]
    return ([_Geom(f["geometry"]) for f in feats],
            [(f["properties"]["id"], _Geom(f["geometry"])) for f in wards["features"]])


def _haversine_km(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(a))


@router.get("/nearest", response_model=NearestLocation)
def nearest_location(lat: float = Query(..., ge=-90, le=90), lon: float = Query(..., ge=-180, le=180)):
    """Ward for a GPS point: 404 outside the HCMC boundary; else the ward polygon containing the point,
    falling back to the ward with the nearest point (e.g. on water or in a gap between simplified polygons)."""
    boundary, wards = _geoms(str(database.LOCATIONS_DIR))
    ward_hit = next((wid for wid, g in wards if g.contains(lon, lat)), None)
    if ward_hit is None and not any(g.contains(lon, lat) for g in boundary):
        raise HTTPException(status_code=404, detail=OUTSIDE_DETAIL)
    candidates = [loc for loc in all_locations() if loc["id"] != DEFAULT_LOCATION_ID]
    if ward_hit is not None:
        loc = next((x for x in candidates if x["id"] == ward_hit), None)
        if loc is not None:
            return {**loc, "method": "polygon",
                    "distance_km": round(_haversine_km(lat, lon, loc["lat"], loc["lon"]), 2)}
    dist, loc = min(((_haversine_km(lat, lon, x["lat"], x["lon"]), x) for x in candidates), key=lambda t: t[0])
    return {**loc, "method": "nearest", "distance_km": round(dist, 2)}


def _geojson_response(name: str, request: Request) -> Response:
    body = _read_geojson(name)
    etag = '"' + hashlib.sha1(body).hexdigest()[:16] + '"'
    headers = {"Cache-Control": f"public, max-age={GEOJSON_MAX_AGE}", "ETag": etag}
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    return Response(content=body, media_type="application/geo+json; charset=utf-8", headers=headers)


@router.get("/boundary")
def get_boundary(request: Request):
    """New HCMC outer boundary (GeoJSON FeatureCollection, simplified; © OpenStreetMap contributors, ODbL)."""
    return _geojson_response("hcmc_boundary.geojson", request)


@router.get("/wards")
def get_wards(request: Request):
    """Ward/commune polygons (GeoJSON FeatureCollection; properties id, name, kind, cell_id; © OSM, ODbL)."""
    return _geojson_response("wards.geojson", request)
