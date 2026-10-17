"""Build the Sky Weather location list for the new Ho Chi Minh City (post-2025 merger).

Sources
  * OpenStreetMap via Overpass API (c) OpenStreetMap contributors, ODbL.
      - rel 1973756  Thanh pho Ho Chi Minh (admin_level=4, ISO3166-2=VN-SG) and its
        `subarea` members (the commune-level units: phuong / xa / dac khu, admin_level=6).
      - historic (pre-2025-07-01) province boundaries used to derive `region`:
        19267904 "Thanh pho Ho Chi Minh cu", 1906037 "Tinh Binh Duong",
        1904296 "Tinh Ba Ria - Vung Tau".
  * Open-Meteo elevation API (90 m DEM) and forecast API (grid-cell snapping).

Outputs (backend/data/locations/):
  locations.json, cells.json, hcmc_boundary.geojson, wards.geojson, SOURCES.md

Reproducibility: every network response is cached as raw JSON in --cache-dir
(default %TEMP%/skyweather_locations_cache). A re-run reuses the cache and produces
byte-identical outputs; pass --refresh to re-download (OSM / Open-Meteo may change).

Usage:  python backend/scripts/build_locations.py [--refresh] [--cache-dir DIR]
Requires: requests, shapely>=2
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

import requests
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, mapping, shape
from shapely.ops import polygonize_full, unary_union
from shapely.validation import make_valid

USER_AGENT = "SkyWeather-student-project/1.0 (+student project)"
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
ELEVATION_URL = "https://api.open-meteo.com/v1/elevation"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

HCMC_REL = 1973756
HISTORIC = {  # relation id -> (expected name, region label)
    19267904: ("Thành phố Hồ Chí Minh cũ", "TP.HCM cũ"),
    1906037: ("Tỉnh Bình Dương", "Bình Dương cũ"),
    1904296: ("Tỉnh Bà Rịa - Vũng Tàu", "Bà Rịa–Vũng Tàu cũ"),
}
OFFICIAL_TOTAL = 168
KIND_PREFIX = [("Đặc khu ", "dac_khu"), ("Phường ", "phuong"), ("Xã ", "xa")]

TSN = {"id": "tsn", "name": "Tân Sơn Nhất (điểm huấn luyện AI)", "kind": "training_point",
       "lat": 10.7909, "lon": 106.6313, "elevation": 6.0, "osm_relation_id": None}

BOUNDARY_TOLERANCE = 0.002   # degrees, outer HCMC boundary
WARD_TOLERANCE = 0.0005      # degrees, ward polygons for the map
COORD_DECIMALS = 5           # ~1 m

OVERPASS_QUERY = f"""[out:json][timeout:600];
rel({HCMC_REL})->.hc;
.hc out geom;
rel(r.hc:"subarea")->.w;
.w out geom;
rel(id:{",".join(str(i) for i in HISTORIC)});
out geom;"""

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "data" / "locations"


# ----------------------------------------------------------------------------- network + cache
class Cache:
    def __init__(self, directory: Path, refresh: bool):
        self.dir = directory
        self.refresh = refresh
        self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, key: str, fetch):
        path = self.dir / (hashlib.sha1(key.encode("utf-8")).hexdigest()[:16] + ".json")
        if path.exists() and not self.refresh:
            return json.loads(path.read_text(encoding="utf-8"))
        data = fetch()
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return data


def overpass(query: str) -> dict:
    last = None
    for attempt in range(9):
        url = OVERPASS_URLS[attempt % len(OVERPASS_URLS)]
        try:
            r = requests.post(url, data={"data": query}, headers={"User-Agent": USER_AGENT}, timeout=900)
            if r.status_code == 200:
                return r.json()
            last = f"{url}: HTTP {r.status_code}"
        except (requests.RequestException, ValueError) as e:
            last = f"{url}: {e}"
        print("  overpass retry:", last, file=sys.stderr)
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"Overpass failed: {last}")


def open_meteo(url: str, params: dict):
    last = None
    for attempt in range(6):
        try:
            r = requests.get(url, params=params, headers={"User-Agent": USER_AGENT}, timeout=120)
            data = r.json()
            if r.status_code == 200 and not (isinstance(data, dict) and data.get("error")):
                time.sleep(1.0)  # be polite
                return data
            last = f"HTTP {r.status_code}: {str(data)[:200]}"
        except (requests.RequestException, ValueError) as e:
            last = str(e)
        print("  open-meteo retry:", last, file=sys.stderr)
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"Open-Meteo failed: {last}")


# ----------------------------------------------------------------------------- geometry
def relation_polygon(rel: dict) -> tuple[MultiPolygon, int]:
    """Assemble a relation's outer/inner way geometries into a (Multi)Polygon.
    Returns (geometry, number_of_dangling_or_cut_lines) as a quality signal."""
    lines = {"outer": [], "inner": []}
    for m in rel.get("members", []):
        if m["type"] != "way" or "geometry" not in m:
            continue
        role = "inner" if m.get("role") == "inner" else "outer"
        coords = [(p["lon"], p["lat"]) for p in m["geometry"] if p]
        if len(coords) >= 2:
            lines[role].append(LineString(coords))
    problems = 0
    parts = {}
    for role, ls in lines.items():
        if not ls:
            parts[role] = None
            continue
        polys, cuts, dangles, invalid = polygonize_full(unary_union(ls))
        problems += len(cuts.geoms) + len(dangles.geoms) + len(invalid.geoms)
        parts[role] = unary_union(list(polys.geoms)) if not polys.is_empty else None
    geom = parts["outer"]
    if geom is None:
        raise ValueError(f"relation {rel['id']} has no closed outer ring")
    if parts["inner"] is not None:
        geom = geom.difference(parts["inner"])
    geom = make_valid(geom)
    if geom.geom_type == "GeometryCollection":
        geom = unary_union([g for g in geom.geoms if g.geom_type in ("Polygon", "MultiPolygon")])
    if isinstance(geom, Polygon):
        geom = MultiPolygon([geom])
    return geom, problems


def rounded(geom, decimals=COORD_DECIMALS) -> dict:
    """GeoJSON mapping with rounded coordinates (deterministic, compact)."""
    def rnd(obj):
        if isinstance(obj, (list, tuple)):
            if obj and isinstance(obj[0], (int, float)):
                return [round(float(v), decimals) for v in obj]
            return [rnd(o) for o in obj]
        return obj
    m = mapping(geom)
    return {"type": m["type"], "coordinates": rnd(m["coordinates"])}


# ----------------------------------------------------------------------------- naming
def slugify(text: str) -> str:
    text = text.replace("Đ", "D").replace("đ", "d")
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    out, prev_dash = [], False
    for c in text:
        if c.isascii() and c.isalnum():
            out.append(c)
            prev_dash = False
        elif not prev_dash:
            out.append("-")
            prev_dash = True
    return "".join(out).strip("-")


def kind_of(name: str) -> str | None:
    for prefix, kind in KIND_PREFIX:
        if name.startswith(prefix):
            return kind
    return None


def cell_id(lat: float, lon: float) -> str:
    return f"om-{lat:.4f}-{lon:.4f}"


# ----------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--refresh", action="store_true", help="ignore cache and re-download")
    ap.add_argument("--cache-dir", type=Path,
                    default=Path(tempfile.gettempdir()) / "skyweather_locations_cache")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    cache = Cache(args.cache_dir, args.refresh)
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- 1. OSM ---------------------------------------------------------------------------
    print("Overpass: HCMC + subareas + historic provinces ...", file=sys.stderr)
    osm = cache.get("overpass:" + OVERPASS_QUERY, lambda: overpass(OVERPASS_QUERY))
    osm_timestamp = osm.get("osm3s", {}).get("timestamp_osm_base", "unknown")
    rels = {e["id"]: e for e in osm["elements"] if e["type"] == "relation"}

    hc = rels[HCMC_REL]
    assert hc["tags"].get("admin_level") == "4" and hc["tags"].get("ISO3166-2") == "VN-SG", hc["tags"]
    hc_poly, hc_problems = relation_polygon(hc)
    subarea_ids = sorted(m["ref"] for m in hc["members"] if m["type"] == "relation" and m["role"] == "subarea")

    historic = {}
    for rid, (expected, label) in HISTORIC.items():
        r = rels.get(rid)
        if r is None or r["tags"].get("name") != expected:
            print(f"  WARNING historic relation {rid} missing or renamed", file=sys.stderr)
            continue
        historic[label] = relation_polygon(r)[0]

    wards, warnings = [], []
    levels = {}
    for rid in subarea_ids:
        r = rels.get(rid)
        if r is None:
            warnings.append(f"subarea relation {rid} not returned by Overpass")
            continue
        t = r["tags"]
        name = t.get("name:vi") or t.get("name", "")
        levels[t.get("admin_level")] = levels.get(t.get("admin_level"), 0) + 1
        kind = kind_of(name)
        if kind is None:
            warnings.append(f"relation {rid} '{name}': unknown kind prefix")
        poly, problems = relation_polygon(r)
        if problems:
            warnings.append(f"relation {rid} '{name}': {problems} unclosed/dangling way pieces")
        # representative point: label node > admin_centre node > point-on-surface
        point, source = None, None
        for role in ("label", "admin_centre"):
            for m in r["members"]:
                if m["type"] == "node" and m.get("role") == role and "lat" in m:
                    p = Point(m["lon"], m["lat"])
                    if poly.contains(p):
                        point, source = p, role
                    else:
                        warnings.append(f"relation {rid} '{name}': {role} node outside polygon, ignored")
                    break
            if point is not None:
                break
        if point is None:
            point, source = poly.representative_point(), "point_on_surface"
        wards.append({"rid": rid, "name": name, "kind": kind, "poly": poly, "point": point,
                      "point_source": source, "tags": t})

    # --- 2. records ------------------------------------------------------------------------
    def region_of(p: Point):
        hits = [label for label, g in historic.items() if g.covers(p)]
        if len(hits) == 1:
            return hits[0], "contains"
        if not historic:
            return None, "no_historic_data"
        # outside all / ambiguous: nearest historic polygon (only within ~2 km)
        label, g = min(historic.items(), key=lambda kv: kv[1].distance(p))
        return (label, "nearest") if g.distance(p) < 0.02 else (None, "none")

    locations = []
    for w in wards:
        lat = round(w["point"].y, COORD_DECIMALS)
        lon = round(w["point"].x, COORD_DECIMALS)
        region, region_method = region_of(w["point"])
        locations.append({
            "id": slugify(w["name"]), "name": w["name"], "kind": w["kind"], "lat": lat, "lon": lon,
            "elevation": None, "region": region, "cell_id": None, "osm_relation_id": w["rid"],
            "point_source": w["point_source"], "region_method": region_method,
            "inside_hcmc": bool(hc_poly.buffer(1e-6).covers(w["point"])), "verified": True,
        })
    ids = [l["id"] for l in locations]
    dupes = {i for i in ids if ids.count(i) > 1}
    region_code = {"TP.HCM cũ": "hcm", "Bình Dương cũ": "bd", "Bà Rịa–Vũng Tàu cũ": "brvt"}
    for l in locations:  # ASCII collisions (e.g. Xã Thanh An / Xã Thạnh An): add former-region code
        if l["id"] in dupes:
            l["id"] = f"{l['id']}-{region_code.get(l['region'], l['osm_relation_id'])}"
    ids = [l["id"] for l in locations]
    assert len(ids) == len(set(ids)), "duplicate ids after disambiguation"
    locations.sort(key=lambda l: l["id"])
    tsn_region, tsn_method = region_of(Point(TSN["lon"], TSN["lat"]))
    tsn = dict(TSN, region=tsn_region, cell_id=None, point_source="fixed_training_point",
               region_method=tsn_method, inside_hcmc=bool(hc_poly.covers(Point(TSN["lon"], TSN["lat"]))),
               verified=True)

    # --- 3. elevation (Open-Meteo, 100 per request) -----------------------------------------
    for i in range(0, len(locations), 100):
        batch = locations[i:i + 100]
        params = {"latitude": ",".join(str(l["lat"]) for l in batch),
                  "longitude": ",".join(str(l["lon"]) for l in batch)}
        data = cache.get("elev:" + json.dumps(params, sort_keys=True), lambda: open_meteo(ELEVATION_URL, params))
        for l, e in zip(batch, data["elevation"], strict=True):
            l["elevation"] = None if e is None else float(e)

    # --- 4. grid cells (Open-Meteo forecast snapping, same params style as ingest.py) -------
    def snap(points: list[dict]) -> list[tuple[float, float]]:
        res = []
        for i in range(0, len(points), 50):
            batch = points[i:i + 50]
            params = {"latitude": ",".join(str(p["lat"]) for p in batch),
                      "longitude": ",".join(str(p["lon"]) for p in batch),
                      "elevation": ",".join(str(p["elevation"]) for p in batch),
                      "current": "temperature_2m", "timezone": "Asia/Ho_Chi_Minh"}
            data = cache.get("snap:" + json.dumps(params, sort_keys=True), lambda: open_meteo(FORECAST_URL, params))
            if isinstance(data, dict):
                data = [data]
            res += [(round(d["latitude"], 6), round(d["longitude"], 6)) for d in data]
        return res

    cells: dict[str, dict] = {}
    for l, (clat, clon) in zip(locations, snap(locations), strict=True):
        cid = cell_id(clat, clon)
        l["cell_id"] = cid
        c = cells.setdefault(cid, {"cell_id": cid, "lat": clat, "lon": clon, "location_ids": []})
        c["location_ids"].append(l["id"])
    (tlat, tlon), = snap([tsn])
    tsn["cell_id"] = "tsn"
    tsn_shares = cell_id(tlat, tlon) in cells
    cells_list = sorted(cells.values(), key=lambda c: (c["lat"], c["lon"]))
    for c in cells_list:
        c["location_ids"].sort()
        c["elevation_mean_of_locations"] = round(
            sum(l["elevation"] for l in locations if l["cell_id"] == c["cell_id"]) / len(c["location_ids"]), 1)
    cells_list.append({"cell_id": "tsn", "lat": tlat, "lon": tlon, "location_ids": ["tsn"],
                       "elevation_mean_of_locations": tsn["elevation"],
                       "note": "dedicated AI-training cell; same grid point as ward cell "
                               + cell_id(tlat, tlon) if tsn_shares else "dedicated AI-training cell"})
    # idempotence check: querying a cell's own coordinates should return the same grid point
    probe = cells_list[:: max(1, len(cells_list) // 10)]
    back = snap([{"lat": c["lat"], "lon": c["lon"], "elevation": c["elevation_mean_of_locations"]} for c in probe])
    unstable = [c["cell_id"] for c, b in zip(probe, back) if (c["lat"], c["lon"]) != b]
    if unstable:
        warnings.append(f"cells not idempotent when re-queried at own coords: {unstable}")

    all_locations = locations + [tsn]

    # --- 5. write outputs ---------------------------------------------------------------
    def dump(name: str, obj, compact=False):
        path = out_dir / name
        text = json.dumps(obj, ensure_ascii=False, separators=(",", ":") if compact else None,
                          indent=None if compact else 1)
        path.write_text(text + "\n", encoding="utf-8", newline="\n")
        return path

    dump("locations.json", all_locations)
    dump("cells.json", cells_list)
    hc_simple = hc_poly.simplify(BOUNDARY_TOLERANCE, preserve_topology=True)
    dump("hcmc_boundary.geojson", {"type": "FeatureCollection", "features": [{
        "type": "Feature", "properties": {"name": hc["tags"]["name"], "osm_relation_id": HCMC_REL,
                                          "simplify_tolerance_deg": BOUNDARY_TOLERANCE},
        "geometry": rounded(hc_simple)}]}, compact=True)
    by_rid = {l["osm_relation_id"]: l for l in locations}
    feats = []
    for w in sorted(wards, key=lambda w: by_rid[w["rid"]]["id"]):
        g = w["poly"].simplify(WARD_TOLERANCE, preserve_topology=True)
        feats.append({"type": "Feature", "properties": {
            "id": by_rid[w["rid"]]["id"], "name": w["name"], "kind": w["kind"],
            "osm_relation_id": w["rid"], "cell_id": by_rid[w["rid"]]["cell_id"]},
            "geometry": rounded(g)})
    dump("wards.geojson", {"type": "FeatureCollection", "features": feats}, compact=True)

    # --- 6. stats + SOURCES.md -----------------------------------------------------------
    def count(key, items=locations):
        out = {}
        for l in items:
            out[str(l[key])] = out.get(str(l[key]), 0) + 1
        return dict(sorted(out.items()))

    stats = {
        "osm_timestamp": osm_timestamp, "subareas": len(subarea_ids), "locations": len(locations),
        "admin_levels": levels, "by_kind": count("kind"), "by_region": count("region"),
        "region_method": count("region_method"), "point_source": count("point_source"),
        "cells_wards": len(cells), "cells_total_incl_tsn": len(cells_list),
        "tsn_shares_grid_point_with_ward_cell": tsn_shares,
        "outside_hcmc_polygon": [l["id"] for l in locations if not l["inside_hcmc"]],
        "hcmc_ring_problems": hc_problems, "warnings": warnings,
        "historic_found": sorted(historic),
    }
    sizes = {p.name: p.stat().st_size for p in sorted(out_dir.glob("*")) if p.suffix in (".json", ".geojson")}
    sources = f"""# Location data sources (Sky Weather, new Ho Chi Minh City)

Generated by `backend/scripts/build_locations.py` (do not edit by hand; re-run the script).

## Attribution
- Administrative boundaries, names and label points: **© OpenStreetMap contributors, ODbL**
  (https://www.openstreetmap.org/copyright). Derived files (`locations.json`, `wards.geojson`,
  `hcmc_boundary.geojson`) are a Derived Database under ODbL 1.0.
- Elevation: Open-Meteo Elevation API (Copernicus DEM GLO-90), https://open-meteo.com (CC BY 4.0).
- Grid cells: Open-Meteo Forecast API, default `best_match` model, default `cell_selection=land`;
  `lat`/`lon` in `cells.json` are the grid coordinates returned by the API.

## OSM snapshot
- Overpass `timestamp_osm_base`: **{osm_timestamp}**
- City relation: r{HCMC_REL} "{hc['tags']['name']}" (admin_level=4, ISO3166-2=VN-SG).
- Commune-level units = the relation's `subarea` members; in OSM these use **admin_level=6**
  (the abolished districts are no longer level-6 relations).
- Former provinces (`region`): historic relations {", ".join(f"r{k} \"{v[0]}\"" for k, v in HISTORIC.items())}
  (`boundary=historic`, `end_date=2025-06-30`). Region = which one contains the location point.

Overpass query:
```
{OVERPASS_QUERY}
```

## Method
- Point: relation `label` node, else `admin_centre` node (only if inside the polygon), else shapely
  `representative_point()` (point-on-surface) of the assembled polygon.
- `id`: ASCII slug of the Vietnamese name (đ→d, diacritics stripped); ASCII collisions get a former-region
  suffix (-hcm/-bd/-brvt), e.g. Xã Thanh An (Bình Dương cũ) vs Xã Thạnh An (TP.HCM cũ).
- Cells: all points sent to the forecast API in batches of 50 (with their DEM elevation, as ingest does);
  wards that come back with the same grid lat/lon share a `cell_id` (`om-<lat>-<lon>`).
  The best_match grid here is ~0.07° lat x ~0.08° lon (not 0.1°).
- `tsn` (Tân Sơn Nhất, the existing AI training point, elevation 6 m fixed) keeps its own cell `tsn`.
- Simplification: city boundary {BOUNDARY_TOLERANCE}°, wards {WARD_TOLERANCE}° (topology preserved per polygon,
  so small gaps/overlaps between neighbouring wards are possible); coordinates rounded to {COORD_DECIMALS} decimals.

## Counts
- Official number after the 2025 reform (Nghị quyết of UBTVQH on rearranging HCMC commune-level units, 2025),
  as given in the task brief: 168 (breakdown not independently verified here).
- OSM subareas: **{stats['subareas']}**, locations built: **{stats['locations']}** (+1 `tsn`).
- By kind: {stats['by_kind']}
- By former region: {stats['by_region']} (method: {stats['region_method']})
- Point source: {stats['point_source']}
- Grid cells: {stats['cells_wards']} for wards, {stats['cells_total_incl_tsn']} incl. `tsn`
  (tsn grid point shared with a ward cell: {tsn_shares})
- File sizes (bytes): {sizes}

## Known gaps / caveats
- All {stats['locations']} units are taken from OSM as-is; `verified=true` means "present in OSM as a
  subarea of r{HCMC_REL} with a phường/xã/đặc khu name", not checked one-by-one against the Nghị quyết text.
- Total matches the official 168: {stats['locations'] == OFFICIAL_TOTAL}.
- Ward polygons are OSM community-mapped boundaries (approximate, not legal cadastral lines).
- Côn Đảo special zone is ~180 km offshore; its weather comes from its own grid cell.
- Warnings from the build: {warnings if warnings else "none"}
"""
    (out_dir / "SOURCES.md").write_text(sources, encoding="utf-8", newline="\n")
    print(json.dumps(stats, ensure_ascii=False, indent=1))
    print("sizes:", sizes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
