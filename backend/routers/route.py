"""
Route with weather along the way (groups 6/7).

GET  /route?from_lat&from_lon&to_lat&to_lon&depart_at&profile   route from OSRM + weather samples every ~2 km
POST /route/along-weather {geometry, depart_at?, duration_min?, profile?}   refresh the weather of a route the
     app already has, without calling OSRM again.

The app only talks to this backend; the backend calls OSRM (httpx, 10 s timeout, own User-Agent, at most one
request per second, LRU cache keyed by profile + coordinates rounded to 4 decimals). driving uses the OSRM demo
server router.project-osrm.org (car only); cycling / foot use the FOSSGIS OSRM servers (routing.openstreetmap.de),
because the demo server ignores the profile and always routes by car. Route data (c) OpenStreetMap contributors.

Each sample: ETA = depart_at + cumulative OSRM duration; the nearest grid cell (cells table) if the point lies
inside the new-HCMC boundary (else cell_id null); the weather of that cell at the ETA hour from
routers.weather._series (observed or our own AI; unavailable forecasts stay null).
alert = thunderstorm code 95-99, or >= 5 mm/h, or gusts >= 50 km/h (model-based, not an official warning).
An alert being false is not a safety conclusion; own AI does not predict storms or gusts.
"""
import json
import math
import threading
import time
from bisect import bisect_right
from collections import OrderedDict
from datetime import datetime, timedelta
from functools import lru_cache
from typing import Dict, List, Literal, Optional, Tuple

import httpx
import numpy as np
from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field

import database
from database import now_local, to_local
from routers import monitor
from routers.weather import _SEVERITY, _floor_hour, _latest_observed, _naive, _num, _series

OSRM_URLS = {
    "driving": "https://router.project-osrm.org/route/v1/driving",
    "cycling": "https://routing.openstreetmap.de/routed-bike/route/v1/driving",
    "foot": "https://routing.openstreetmap.de/routed-foot/route/v1/driving",
}
USER_AGENT = "SkyWeatherHCMC/1.0 (student weather app backend; route weather)"
OSRM_TIMEOUT = 10.0
OSRM_MIN_INTERVAL = 1.0      # seconds between two OSRM requests (usage policy: max 1 req/s)
CACHE_SIZE = 256
MAX_ROUTE_KM = 300.0
SAMPLE_STEP_KM = 2.0
MAX_GEOMETRY_POINTS = 300
MAX_INPUT_POINTS = 20000
CELL_FALLBACK_KM = 10.0      # without the boundary file: "inside" = within this distance of a cell
DEPART_PAST_HOURS = 24       # depart_at may be at most this far in the past ...
DEPART_FUTURE_DAYS = 7       # ... or this far in the future
ALERT_RAIN_MM_H = 5.0
ALERT_GUST_KMH = 50.0
DEFAULT_SPEED_KMH = {"driving": 30.0, "cycling": 15.0, "foot": 5.0}   # along-weather without duration_min
ATTRIBUTION = "© OpenStreetMap contributors, OSRM"
Profile = Literal["driving", "cycling", "foot"]

router = APIRouter(prefix="/route", tags=["route"])


# --- Geometry -------------------------------------------------------------------------------------------

def _haversine_km(a: Tuple[float, float], b: Tuple[float, float]) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371.0088 * math.asin(math.sqrt(min(1.0, h)))


def _rdp(xy: np.ndarray, eps: float) -> np.ndarray:
    """Ramer-Douglas-Peucker (iterative, vectorised) on planar points; returns the kept indices."""
    n = len(xy)
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        s, e = stack.pop()
        if e - s < 2:
            continue
        p1, d = xy[s], xy[e] - xy[s]
        seg = xy[s + 1:e] - p1
        norm = math.hypot(d[0], d[1])
        dist = np.abs(d[1] * seg[:, 0] - d[0] * seg[:, 1]) / norm if norm else np.hypot(seg[:, 0], seg[:, 1])
        i = int(np.argmax(dist))
        if dist[i] > eps:
            keep[s + 1 + i] = True
            stack += [(s, s + 1 + i), (s + 1 + i, e)]
    return np.flatnonzero(keep)


def simplify(pts: List[Tuple[float, float]], max_points: int = MAX_GEOMETRY_POINTS) -> List[List[float]]:
    """At most max_points [lat, lon] (first and last kept), coordinates rounded to 5 decimals (~1 m).
    Planar on (lon * cos(lat), lat); the tolerance doubles from 1e-5 deg (~1 m) until the cap is met."""
    idx = np.arange(len(pts))
    if len(pts) > max_points:
        arr = np.asarray(pts, dtype=float)
        xy = np.column_stack([arr[:, 1] * math.cos(math.radians(arr[0, 0])), arr[:, 0]])
        eps = 1e-5
        while len(idx) > max_points:
            idx = _rdp(xy, eps)
            eps *= 2
    return [[round(pts[i][0], 5), round(pts[i][1], 5)] for i in idx]


def _cumulative_km(pts: List[Tuple[float, float]]) -> List[float]:
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + _haversine_km(a, b))
    return cum


def _sample_points(pts, cum_km: List[float], cum_s: List[float]) -> List[Tuple[float, float, float]]:
    """(lat, lon, seconds from departure) at 0, 2, 4 ... km and at the destination."""
    total = cum_km[-1]
    targets = [i * SAMPLE_STEP_KM for i in range(int(total // SAMPLE_STEP_KM) + 1)]
    if total - targets[-1] > 1e-6:
        targets.append(total)
    out = []
    for d in targets:
        i = min(max(bisect_right(cum_km, d) - 1, 0), len(pts) - 2) if len(pts) > 1 else 0
        if len(pts) == 1:
            out.append((pts[0][0], pts[0][1], 0.0))
            continue
        seg = cum_km[i + 1] - cum_km[i]
        f = 0.0 if seg <= 0 else min(max((d - cum_km[i]) / seg, 0.0), 1.0)
        lat = pts[i][0] + f * (pts[i + 1][0] - pts[i][0])
        lon = pts[i][1] + f * (pts[i + 1][1] - pts[i][1])
        out.append((lat, lon, cum_s[i] + f * (cum_s[i + 1] - cum_s[i])))
    return out


# --- HCMC boundary and cells ----------------------------------------------------------------------------

@lru_cache(maxsize=4)
def _boundary(path: str) -> Optional[List[List[List[Tuple[float, float]]]]]:
    """Polygons as lists of rings of (lon, lat); None if the file is missing."""
    try:
        g = json.loads(open(path, encoding="utf-8").read())
    except (OSError, ValueError):
        return None
    polys = []
    for f in g.get("features", [g]):
        geom = f.get("geometry", f)
        if geom.get("type") == "Polygon":
            polys.append(geom["coordinates"])
        elif geom.get("type") == "MultiPolygon":
            polys.extend(geom["coordinates"])
    return polys or None


def _in_ring(lon: float, lat: float, ring) -> bool:
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


@lru_cache(maxsize=4)
def _cells(db_path: str) -> Tuple[tuple, ...]:
    """(cell_id, series_id, lat, lon) of every grid cell; the 'tsn' alias row is dropped (same point)."""
    try:
        rows = database.execute_query("SELECT cell_id, series_id, lat, lon FROM cells ORDER BY cell_id")
    except Exception:  # noqa: BLE001 - DB without cells table
        return ()
    rows = [tuple(r) for r in rows]
    real = [r for r in rows if r[0] != database.DEFAULT_LOCATION_ID]
    return tuple(real or rows)


def _locate(lat: float, lon: float) -> Optional[tuple]:
    """Nearest cell (cell_id, series_id, lat, lon) if (lat, lon) is inside new HCMC, else None."""
    cells = _cells(str(database.DATABASE_PATH))
    if not cells:
        return None
    best = min(cells, key=lambda c: _haversine_km((lat, lon), (c[2], c[3])))
    polys = _boundary(str(database.LOCATIONS_DIR / "hcmc_boundary.geojson"))
    if polys is None:
        return best if _haversine_km((lat, lon), (best[2], best[3])) <= CELL_FALLBACK_KM else None
    for rings in polys:
        if _in_ring(lon, lat, rings[0]) and not any(_in_ring(lon, lat, h) for h in rings[1:]):
            return best
    return None


# --- Weather along the route ----------------------------------------------------------------------------

def _alert(item) -> Tuple[bool, Optional[str]]:
    if item is None:
        return False, None
    reasons = []
    if item.weather_code is not None and 95 <= item.weather_code <= 99:
        reasons.append("Dông")
    if item.precipitation is not None and item.precipitation >= ALERT_RAIN_MM_H:
        reasons.append(f"Mưa to ({item.precipitation:.1f} mm/h)")
    if item.wind_gusts is not None and item.wind_gusts >= ALERT_GUST_KMH:
        reasons.append(f"Gió giật mạnh ({item.wind_gusts:.0f} km/h)")
    return bool(reasons), "; ".join(reasons) or None


def _worst_key(s: dict):
    return (s["alert"], _SEVERITY.get(s["weather_code"], -1) if s["weather_code"] is not None else -1,
            s["precipitation"] or 0.0, s["rain_probability"] or 0.0, s["wind_gusts"] or 0.0)


def _weather_samples(points: List[Tuple[float, float, float]], depart: datetime) -> List[dict]:
    """points: (lat, lon, seconds from departure); depart: aware HCMC time."""
    located = [_locate(lat, lon) for lat, lon, _ in points]
    etas = [depart + timedelta(seconds=s) for _, _, s in points]
    hours = [_floor_hour(_naive(e) + timedelta(minutes=30)) for e in etas]   # nearest hour
    wanted: Dict[str, set] = {}
    for cell, h in zip(located, hours):
        if cell is not None:
            wanted.setdefault(cell[1], set()).add(h)
    weather: Dict[Tuple[str, datetime], object] = {}
    for sid, hs in wanted.items():
        times = sorted(hs)
        try:
            items = _series(times, _latest_observed(sid), True, sid)
        except HTTPException as exc:
            if exc.status_code != 503:
                raise
            items = [None] * len(times)
        for t, item in zip(times, items):
            weather[(sid, t)] = item
    out = []
    for (lat, lon, _), cell, eta, h in zip(points, located, etas, hours):
        item = weather.get((cell[1], h)) if cell is not None else None
        alert, reason = _alert(item)
        out.append({
            "lat": round(lat, 5), "lon": round(lon, 5), "eta": eta.isoformat(timespec="seconds"),
            "cell_id": cell[0] if cell is not None else None,
            "temperature": _num(item.temperature, 1) if item is not None else None,
            "precipitation": _num(item.precipitation, 2) if item is not None else None,
            "rain_probability": _num(item.rain_probability, 2) if item is not None else None,
            "weather_code": item.weather_code if item is not None else None,
            "wind_gusts": _num(item.wind_gusts, 1) if item is not None else None,
            "source": item.source if item is not None else None,
            "forecast_available": item is not None and any(getattr(item, field) is not None for field in
                                                          ("temperature", "precipitation", "rain_probability",
                                                           "weather_code", "wind_gusts")),
            "hazard_assessment_complete": item is not None and item.source in {"observed", "forecast"}
                                          and all(getattr(item, field) is not None for field in
                                                  ("precipitation", "weather_code", "wind_gusts")),
            "alert": alert, "alert_reason": reason,
        })
    return out


def _parse_depart(depart_at: Optional[str]) -> datetime:
    now = to_local(now_local())
    if depart_at is None:
        return now.replace(microsecond=0)
    text = depart_at.strip()
    if "T" in text and " " in text:   # an unencoded "+07:00" arrives as " 07:00"
        text = text.replace(" ", "+")
    try:
        t = to_local(datetime.fromisoformat(text))
    except ValueError:
        raise HTTPException(status_code=400, detail="depart_at không hợp lệ; dùng ISO 8601, ví dụ 2026-10-17T07:30")
    if t < now - timedelta(hours=DEPART_PAST_HOURS) or t > now + timedelta(days=DEPART_FUTURE_DAYS):
        raise HTTPException(status_code=400, detail=f"depart_at phải trong khoảng {DEPART_PAST_HOURS} giờ trước "
                            f"đến {DEPART_FUTURE_DAYS} ngày sau thời điểm hiện tại")
    return t


def _check_endpoints(a: Tuple[float, float], b: Tuple[float, float]) -> None:
    if _locate(*a) is None and _locate(*b) is None:
        raise HTTPException(status_code=400, detail="Cả điểm đi và điểm đến đều nằm ngoài TP.HCM")


def _too_long() -> HTTPException:
    return HTTPException(status_code=400, detail=f"Tuyến đường dài hơn {MAX_ROUTE_KM:.0f} km, không hỗ trợ")


def _build(pts, cum_s: List[float], depart: datetime, profile: str, **extra) -> dict:
    cum_km = _cumulative_km(pts)
    samples = _weather_samples(_sample_points(pts, cum_km, cum_s), depart)
    worst = max(samples, key=_worst_key) if samples else None
    duration_s = cum_s[-1]
    return {
        "profile": profile,
        "depart_at": depart.isoformat(timespec="seconds"),
        "arrive_at": (depart + timedelta(seconds=duration_s)).isoformat(timespec="seconds"),
        "distance_km": round(extra.pop("distance_km", cum_km[-1]), 2),
        "duration_min": round(duration_s / 60, 1),
        "geometry": simplify(pts),
        "samples": samples,
        "worst": dict(worst) if worst is not None else None,
        "alert": any(s["alert"] for s in samples),
        "attribution": ATTRIBUTION,
        **extra,
    }


# --- OSRM -----------------------------------------------------------------------------------------------

class OsrmError(RuntimeError):
    pass


class NoRoute(RuntimeError):
    pass


_cache: "OrderedDict[tuple, dict]" = OrderedDict()
_cache_lock = threading.Lock()
_osrm_lock = threading.Lock()
_last_call = [0.0]


def _http_get(url: str, params: dict) -> httpx.Response:
    """Single OSRM GET (patched in tests)."""
    return httpx.get(url, params=params, timeout=OSRM_TIMEOUT, headers={"User-Agent": USER_AGENT})


def _osrm_request(profile: str, a: Tuple[float, float], b: Tuple[float, float]) -> dict:
    url = f"{OSRM_URLS[profile]}/{a[1]:.6f},{a[0]:.6f};{b[1]:.6f},{b[0]:.6f}"
    params = {"overview": "full", "geometries": "geojson", "annotations": "duration", "steps": "false"}
    with _osrm_lock:   # serialises OSRM calls: at most one per OSRM_MIN_INTERVAL
        wait = OSRM_MIN_INTERVAL - (time.monotonic() - _last_call[0])
        if wait > 0:
            time.sleep(wait)
        try:
            r = _http_get(url, params)
        except httpx.HTTPError as e:
            monitor.record_api_call("osrm", ok=False)
            raise OsrmError(f"{type(e).__name__}: {e}")
        finally:
            _last_call[0] = time.monotonic()
    try:
        data = r.json()
    except ValueError:
        data = {}
    code = data.get("code") if isinstance(data, dict) else None
    if code in ("NoRoute", "NoSegment"):
        monitor.record_api_call("osrm", ok=True)
        raise NoRoute(code)
    if r.status_code != 200 or code != "Ok" or not data.get("routes"):
        monitor.record_api_call("osrm", ok=False)
        raise OsrmError(f"HTTP {r.status_code}, code {code}")
    monitor.record_api_call("osrm", ok=True)
    route = data["routes"][0]
    coords = [(float(c[1]), float(c[0])) for c in route["geometry"]["coordinates"]]
    durs = []
    for leg in route.get("legs", []):
        durs += (leg.get("annotation") or {}).get("duration") or []
    if len(coords) < 2:
        coords = [a, b]
    cum_km = _cumulative_km(coords)
    total_s = float(route.get("duration") or 0.0)
    if len(durs) == len(coords) - 1:
        cum_s = [0.0]
        for d in durs:
            cum_s.append(cum_s[-1] + float(d))
    else:   # no per-segment annotation: spread the total duration over the distance
        cum_s = [total_s * (k / cum_km[-1]) if cum_km[-1] else 0.0 for k in cum_km]
    return {"coords": coords, "cum_s": cum_s, "distance_km": float(route.get("distance") or 0.0) / 1000}


def get_osrm_route(profile: str, a: Tuple[float, float], b: Tuple[float, float]) -> Tuple[dict, bool]:
    """(route, from_cache). LRU-cached by profile and coordinates rounded to 4 decimals (~11 m)."""
    key = (profile, round(a[0], 4), round(a[1], 4), round(b[0], 4), round(b[1], 4))
    with _cache_lock:
        if key in _cache:
            _cache.move_to_end(key)
            return _cache[key], True
    route = _osrm_request(profile, (key[1], key[2]), (key[3], key[4]))
    with _cache_lock:
        _cache[key] = route
        while len(_cache) > CACHE_SIZE:
            _cache.popitem(last=False)
    return route, False


# --- Endpoints ------------------------------------------------------------------------------------------

@router.get("")
def get_route(from_lat: float = Query(..., ge=-90, le=90), from_lon: float = Query(..., ge=-180, le=180),
              to_lat: float = Query(..., ge=-90, le=90), to_lon: float = Query(..., ge=-180, le=180),
              depart_at: Optional[str] = Query(default=None, description="ISO 8601, naive = HCMC time; default now"),
              profile: Profile = Query(default="driving")):
    """Route from OSRM with the weather expected at each ~2 km sample when passing it."""
    a, b = (from_lat, from_lon), (to_lat, to_lon)
    depart = _parse_depart(depart_at)
    _check_endpoints(a, b)
    if _haversine_km(a, b) > MAX_ROUTE_KM:
        raise _too_long()
    try:
        route, cached = get_osrm_route(profile, a, b)
    except NoRoute:
        raise HTTPException(status_code=404, detail="Không tìm thấy đường đi giữa hai điểm")
    except OsrmError:
        raise HTTPException(status_code=503, detail="Dịch vụ tìm đường (OSRM) đang lỗi hoặc quá tải, vui lòng thử lại sau")
    if route["distance_km"] > MAX_ROUTE_KM:
        raise _too_long()
    return _build(route["coords"], route["cum_s"], depart, profile, distance_km=route["distance_km"], cached=cached)


class AlongWeatherIn(BaseModel):
    geometry: List[List[float]] = Field(..., min_length=2, max_length=MAX_INPUT_POINTS,
                                        description="[[lat, lon], ...] e.g. the geometry returned by GET /route")
    depart_at: Optional[str] = None
    duration_min: Optional[float] = Field(default=None, gt=0, le=24 * 60,
                                          description="total travel time; default from the profile's speed")
    profile: Profile = "driving"


@router.post("/along-weather")
def post_along_weather(body: AlongWeatherIn):
    """Weather along an existing route (no OSRM call). ETAs spread duration_min over the distance."""
    pts = []
    for p in body.geometry:
        if len(p) != 2 or not (-90 <= p[0] <= 90 and -180 <= p[1] <= 180):
            raise HTTPException(status_code=422, detail="Mỗi điểm của geometry phải là [lat, lon]")
        pts.append((float(p[0]), float(p[1])))
    depart = _parse_depart(body.depart_at)
    _check_endpoints(pts[0], pts[-1])
    cum_km = _cumulative_km(pts)
    if cum_km[-1] > MAX_ROUTE_KM:
        raise _too_long()
    total_s = body.duration_min * 60 if body.duration_min else cum_km[-1] / DEFAULT_SPEED_KMH[body.profile] * 3600
    cum_s = [total_s * (k / cum_km[-1]) if cum_km[-1] else 0.0 for k in cum_km]
    return _build(pts, cum_s, depart, body.profile, distance_km=cum_km[-1])
