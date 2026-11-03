"""
Per-hour items of a location's series: observed rows, our own long-range AI issue, or climatology (replay).
"""
import logging
import threading
from collections import defaultdict
from fastapi import HTTPException
from datetime import datetime, timedelta
from functools import lru_cache
from typing import Dict, List, Optional

import pandas as pd

from database import execute_one, DEFAULT_LOCATION_ID, to_local, weather_data_revision
from models import WeatherData
import ai_model
import long_range_model_v2 as long_range_model
from routers import weather_core as core, weather_climatology as clim
from routers.weather_core import (RAIN_HOUR_MM, TS_FMT, _aq_fields, _aq_rows, _code, _floor_hour, _naive, _num,
                                  _observed_rows, row_to_weather_data)
from routers.weather_climatology import _clim_series, _derive_code

log = logging.getLogger(__name__)


# --- Per-hour items -----------------------------------------------------------------------------------

def _observed_item(row, aq=None) -> WeatherData:
    p = row["precipitation"]
    return row_to_weather_data(row, "observed", precipitation_median=p, **_aq_fields(aq),
                               rain_probability=None if p is None else (1.0 if p >= RAIN_HOUR_MM else 0.0))


def _forecast_item(row, aq=None) -> WeatherData:
    pp = row["precipitation_probability"]
    return row_to_weather_data(row, "forecast", precipitation_median=row["precipitation"], **_aq_fields(aq),
                               rain_probability=None if pp is None else round(pp / 100, 2))


def _climatology_item(hourly: pd.DataFrame, t: datetime) -> Optional[WeatherData]:
    key = (t.month, t.day, t.hour)
    if key not in hourly.index:
        return None
    row = hourly.loc[key]
    return WeatherData(
        timestamp=to_local(t),
        temperature=_num(row['temperature'], 1),
        humidity=_num(row['humidity'], 1),
        dew_point=_num(row['dew_point'], 1),
        apparent_temperature=_num(row['apparent_temperature'], 1),
        precipitation_probability=_num(row['precipitation_probability'], 1),
        precipitation=_num(row['precipitation'], 2),
        rain=_num(row['rain'], 2),
        weather_code=_code(row['weather_code']),
        visibility=_num(row['visibility'], 0),
        cloud_cover=_num(row['cloud_cover'], 1),
        surface_pressure=_num(row['surface_pressure'], 1),
        pressure_msl=_num(row['pressure_msl'], 1),
        wind_speed=_num(row['wind_speed'], 1),
        wind_direction=_num(row['wind_direction'], 0),
        wind_gusts=_num(row['wind_gusts'], 1),
        rain_probability=_num(row['rain_probability'], 2),
        precipitation_median=_num(row['precipitation_median'], 2),
        uv_index=_num(row['uv_index'], 1),
        source="climatology",
    )



def _series(times: List[datetime], obs_until: Optional[datetime], use_forecast: bool,
            sid: str = DEFAULT_LOCATION_ID) -> List[Optional[WeatherData]]:
    """Live uses our trained model only. Replay is a historical reference, not an AI backtest."""
    lo, hi = times[0], times[-1]
    if use_forecast:
        now = _naive(_floor_hour(to_local(core.now_local())))
        obs_until = min(obs_until, now - timedelta(hours=1)) if obs_until is not None else None
        obs = _observed_rows(lo, min(hi, obs_until), sid) if obs_until is not None and lo <= obs_until else {}
        missing = [t for t in times if t not in obs]
        fc = _own_forecast_rows(sid, now) if missing else {}
        aq = _aq_rows(lo, min(hi, now - timedelta(hours=1)), sid) if lo < now else {}
        items = [_observed_item(obs[t], aq.get(t)) if t in obs else fc.get(t) for t in times]
        if any(i is None for i in items):
            raise HTTPException(status_code=503, detail='Dự báo AI chưa phủ đủ khoảng thời gian yêu cầu; '
                                'cần dữ liệu đầu vào mới và model đã huấn luyện đúng phạm vi.')
        return items
    obs = _observed_rows(lo, min(hi, obs_until), sid) if obs_until is not None and lo <= obs_until else {}
    aq = _aq_rows(lo, hi, sid)
    hourly = None
    out = []
    for t in times:
        if t in obs:
            out.append(_observed_item(obs[t], aq.get(t)))
        else:
            if hourly is None:
                hourly, _ = clim._climatology(_clim_series(sid))
            out.append(_climatology_item(hourly, t))
    return out


# Single-flight: concurrent first requests for a series (e.g. /map right after an ingest bumps the data
# revision) wait for one computation and then hit the cache instead of each recomputing the forecast.
_issue_locks: Dict[str, threading.Lock] = defaultdict(threading.Lock)
_issue_locks_guard = threading.Lock()


_INTERVAL_FIELDS = ('temperature_p10', 'temperature_p90', 'humidity_p10', 'humidity_p90', 'wind_speed_p10',
                    'wind_speed_p90', 'cloud_cover_p10', 'cloud_cover_p90')


@lru_cache(maxsize=128)
def _own_issue(db_path: str, sid: str, cell_id: str, issued_at: str,
               revision: tuple) -> Dict[datetime, WeatherData]:
    history = ai_model.load_history_from_db(db_path=db_path, until=datetime.fromisoformat(issued_at),
                                          location_id=sid)
    result = long_range_model.predict(history, cell_id)
    issue_time = _naive(to_local(result['issued_at']))
    if issue_time != _naive(datetime.fromisoformat(issued_at)):
        raise ValueError('Model issue does not match the selected input cutoff')
    level = result.get('interval_level')
    out = {}
    for horizon, p in result['predictions'].items():
        t = issue_time + timedelta(hours=int(horizon.rstrip('h')))
        prob, amount, cloud = p.get('rain_probability'), p.get('precipitation_mm'), p.get('cloud_cover')
        bounds = {key: p.get(key) for key in _INTERVAL_FIELDS}
        bounds['precipitation_p90'] = p.get('precipitation_mm_p90')
        has_interval = level is not None and any(v is not None for v in bounds.values())
        out[t] = WeatherData(timestamp=to_local(t), temperature=p['temperature'],
                             issued_at=to_local(issue_time), model_version=result.get('model_version'),
                             humidity=p.get('humidity'), precipitation=amount, rain=amount,
                             wind_speed=p.get('wind_speed'), cloud_cover=cloud,
                             rain_probability=prob,
                             precipitation_probability=None if prob is None else round(prob * 100, 2),
                             weather_code=_derive_code(prob, None, amount, cloud, 2.5, 7.5), source='ai',
                             **(bounds if has_interval else {}),
                             interval_level=level if has_interval else None)
    return out


def _own_forecast_rows(sid: str, now: datetime) -> Dict[datetime, WeatherData]:
    # Forecast the current hour too: never feed its reference value into the model.
    cutoff = now - timedelta(hours=1)
    row = execute_one('SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ? AND timestamp <= ?',
                      (sid, cutoff.strftime(TS_FMT)))
    issued = datetime.fromisoformat(row[0]) if row and row[0] else None
    if issued is None or now - issued > timedelta(hours=3):
        raise HTTPException(status_code=503, detail='Chưa có dữ liệu đầu vào trong 3 giờ gần nhất để chạy AI riêng.')
    try:
        cell = execute_one('SELECT cell_id FROM cells WHERE series_id = ? ORDER BY cell_id = series_id DESC LIMIT 1',
                           (sid,))
        cid = ai_model.canonical_cell_id(cell[0] if cell else sid)
        # Another ingest process may revise existing hours without advancing the issue time.
        stamp = (*long_range_model.artifact_revision(), *weather_data_revision(core.DATABASE_PATH))
        with _issue_locks_guard:
            lock = _issue_locks[sid]
        with lock:
            return _own_issue(str(core.DATABASE_PATH), sid, cid, issued.isoformat(), stamp)
    except (ValueError, OSError):
        log.warning('own long-range forecast unavailable for %s', sid, exc_info=True)
        raise HTTPException(status_code=503, detail='Dự báo AI riêng chưa sẵn sàng, vui lòng thử lại sau.') from None
