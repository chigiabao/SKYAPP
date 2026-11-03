"""
Map endpoints: /weather/map/meta and /weather/map (one item per grid series, live AI frames or replay).
"""
from fastapi import APIRouter, Query, HTTPException
from datetime import datetime, timedelta
from functools import lru_cache
import json
from typing import Dict, Optional
import sqlite3

from database import execute_query, to_local, weather_data_revision
import ai_model
import long_range_model_v2 as long_range_model
from routers import weather_core as core, weather_series as wseries
from routers.weather_core import AT_DESC, TS_FMT, _code, _floor_hour, _naive, _num, _resolve_at

router = APIRouter()


# --- Map ----------------------------------------------------------------------------------------------
MAP_ALERT_RAIN_MM = 10.0   # >= 10 mm in the next 3 h counts as heavy rain on the map


@lru_cache(maxsize=32)
def _replay_ai_rain(now: datetime, series: tuple, revision: tuple) -> Dict[str, float]:
    """Max AI rain probability over +1h/+3h for each (series_id, cell_id), issued exactly at `now` (naive)."""
    out = {}
    for sid, cell_id in series:
        hist = ai_model.load_history_from_db(db_path=str(core.DATABASE_PATH), until=now, location_id=sid)
        if len(hist) < ai_model.MIN_HISTORY_HOURS:
            continue
        try:
            res = long_range_model.predict(hist, ai_model.canonical_cell_id(cell_id))
        except (ValueError, OSError):
            continue
        if datetime.fromisoformat(str(res["issued_at"])[:19]) == now:
            probs = [res['predictions'][h].get('rain_probability') for h in ('1h', '2h', '3h')]
            if all(p is not None for p in probs):
                out[sid] = max(probs)
    return out


MAP_MAX_OFFSET_HOURS = 72  # map frames from our hourly AI; leave 3h for the outlook


def _map_now(eff: Optional[datetime]) -> datetime:
    return _naive(eff if eff is not None else _floor_hour(to_local(core.now_local())))


def _map_meta(now: datetime, replay: bool) -> dict:
    """Only advertise future frames covered by a trained model and fresh input."""
    info = long_range_model.status()
    issues = []
    try:
        rows = execute_query('SELECT DISTINCT c.series_id, '
                             '(SELECT MAX(timestamp) FROM hourly_weather h '
                             'WHERE h.location_id = c.series_id AND h.timestamp < ?) '
                             'FROM cells c',
                             (now.strftime(TS_FMT),)) if info['status'] == 'available' and not replay else []
    except sqlite3.OperationalError:
        rows = []
    for cid, timestamp in rows:
        if timestamp and ai_model.canonical_cell_id(cid) in info.get('cell_ids', []):
            issue = datetime.fromisoformat(timestamp)
            if timedelta(0) <= now - issue <= timedelta(hours=3) and to_local(issue) > to_local(info['trained_through']):
                try:
                    forecast = wseries._own_forecast_rows(cid, now)
                except HTTPException as exc:
                    if exc.status_code != 503:
                        raise
                    continue
                if any(any(getattr(item, field) is not None for field in
                           ('temperature', 'precipitation', 'rain_probability', 'wind_speed', 'cloud_cover'))
                       for item in forecast.values()):
                    issues.append(issue)
    issued = min(issues) if issues else None
    max_off = min(MAP_MAX_OFFSET_HOURS, long_range_model.MAX_HORIZON - int((now-issued).total_seconds()/3600) - 3) if issued else 0
    return {"now": to_local(now).isoformat(), "max_offset_hours": max_off,
            "issued_at": to_local(issued).isoformat() if issued else None, 'forecast_source': 'ai'}


@router.get("/map/meta")
def get_weather_map_meta(at: Optional[str] = Query(default=None, description=AT_DESC)):
    """Map slider coverage of our trained AI, capped at 72h. Replay supports only offset 0."""
    eff = _resolve_at(at)
    return _map_meta(_map_now(eff), eff is not None)


@router.get("/map")
def get_weather_map(at: Optional[str] = Query(default=None, description=AT_DESC),
                    offset_hours: int = Query(default=0, ge=0, le=MAP_MAX_OFFSET_HOURS,
                                              description="Map frame t = now + offset (hours, 0..72)")):
    """One item per grid cell. All live frames, including now, use only our trained AI.
    Unsupported cells have null forecasts, never an external forecast fallback.
    Replay + offset > 0 is rejected with 400: a future frame would need data issued after `at`.
    source/numeric fields are null for a cell with no data at t. max_offset_hours (same on every item, also
    /weather/map/meta) = how far the slider can go.
    alert = thunderstorm code or >= 10 mm in the next 3 h (model-based, not an official warning).
    One item per weather series: the 'tsn' alias cell is merged into the grid cell it duplicates."""
    eff = _resolve_at(at)
    if eff is not None and offset_hours > 0:
        raise HTTPException(status_code=400, detail="Chế độ xem lại (`at`) chỉ hỗ trợ offset_hours = 0: "
                            "khung tương lai cần dữ liệu phát hành sau thời điểm `at`")
    now = _map_now(eff)
    t = now + timedelta(hours=offset_hours)
    meta = _map_meta(now, eff is not None)
    try:
        cells = execute_query("SELECT cell_id, lat, lon, series_id, location_ids FROM cells "
                              "ORDER BY cell_id = series_id, cell_id")
    except sqlite3.OperationalError:
        cells = []
    if not cells:
        raise HTTPException(status_code=503, detail="Chưa nạp danh sách ô lưới")
    cols = ("h.location_id, h.temperature, h.weather_code, h.wind_speed, h.wind_direction, h.wind_gusts, "
            "h.precipitation, h.timestamp")
    if offset_hours == 0 and eff is not None:
        cur = {r["location_id"]: r for r in execute_query(
            f'SELECT {cols} FROM cells c JOIN hourly_weather h ON h.location_id = c.series_id '
            'AND h.timestamp = (SELECT MAX(timestamp) FROM hourly_weather latest '
            'WHERE latest.location_id = c.series_id AND latest.timestamp <= ?)', (now.strftime(TS_FMT),))}
    else:
        cur = {}
    nxt: Dict[str, list] = {}
    merged: Dict[str, dict] = {}
    for c in cells:   # non-alias cells sort first and keep their cell_id
        m = merged.setdefault(c["series_id"], {**dict(c), "location_ids": []})
        m["location_ids"] += [i for i in json.loads(c["location_ids"] or "[]") if i not in m["location_ids"]]
    if eff is None and long_range_model.status()['status'] == 'available':
        for sid in merged:
            try:
                forecast = wseries._own_forecast_rows(sid, now)
            except HTTPException as exc:
                if exc.status_code != 503:
                    raise
                continue
            if t in forecast:
                cur[sid] = forecast[t].model_dump()
            nxt[sid] = [(forecast[v].precipitation, forecast[v].rain_probability, forecast[v].weather_code)
                        for v in (t + timedelta(hours=h) for h in (1, 2, 3)) if v in forecast]
    revision = (str(core.DATABASE_PATH), *long_range_model.artifact_revision(), *weather_data_revision(core.DATABASE_PATH))
    ai_probs = _replay_ai_rain(now, tuple((sid, c['cell_id']) for sid, c in merged.items()), revision) if eff else {}
    source = "observed" if eff is not None else "ai"
    valid_time = to_local(t).isoformat()
    out = []
    for c in sorted(merged.values(), key=lambda m: m["cell_id"]):
        sid = c["series_id"]
        now_row, hours = cur.get(sid), nxt.get(sid, [])
        precip = [h[0] for h in hours if h[0] is not None]
        probs = [h[1] for h in hours if h[1] is not None]
        codes = [int(h[2]) for h in hours if h[2] is not None]
        if now_row is not None and now_row["weather_code"] is not None:
            codes.append(int(now_row["weather_code"]))
        total = round(sum(precip), 2) if precip else None

        def field(name, digits):
            return _num(now_row[name], digits) if now_row is not None else None
        out.append({
            "cell_id": c["cell_id"], "lat": c["lat"], "lon": c["lon"],
            "location_ids": c["location_ids"],
            "observed_at": to_local(now_row["timestamp"]).isoformat()
            if now_row is not None and source == "observed" else None,
            "temperature": field("temperature", 1),
            "weather_code": _code(now_row["weather_code"]) if now_row is not None else None,
            "rain_probability_next_3h": round(max(probs), 2) if probs else (
                round(ai_probs[sid], 2) if sid in ai_probs else None),
            "outlook_source": "ai" if probs or sid in ai_probs else None,
            "precipitation_next_3h": total,
            "alert": any(95 <= k <= 99 for k in codes) or (total is not None and total >= MAP_ALERT_RAIN_MM),
            "wind_speed": field("wind_speed", 1),
            "wind_direction": field("wind_direction", 0),
            "wind_gusts": field("wind_gusts", 1),
            "precipitation": field("precipitation", 2),
            "source": source if now_row is not None else None,
            "valid_time": valid_time,
            "max_offset_hours": meta["max_offset_hours"],
        })
    return out
