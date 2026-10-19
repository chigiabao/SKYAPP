"""
Weather API endpoints.
"""
from fastapi import APIRouter, Query, HTTPException, Response
from fastapi.encoders import jsonable_encoder
from datetime import date, datetime, timedelta
from contextlib import closing
from functools import lru_cache
import json
from pathlib import Path
from typing import Dict, List, Optional
import sqlite3

import numpy as np
import pandas as pd

from database import (execute_query, execute_one, DATABASE_PATH, HISTORY_DB_PATH, DEFAULT_LOCATION_ID,
                      now_local, to_local)
from models import WeatherData, DailySummary
import ai_model
import long_range_model

router = APIRouter(prefix="/weather", tags=["weather"])


def _num(value, digits: int):
    if value is None or pd.isna(value):
        return None
    return round(float(value), digits)


def row_to_weather_data(row: sqlite3.Row, source: str = "observed", **extra) -> WeatherData:
    """Convert a hourly_weather / nwp_forecast row to WeatherData."""
    return WeatherData(
        timestamp=to_local(row['timestamp']),
        temperature=row['temperature'],
        humidity=row['humidity'],
        dew_point=row['dew_point'],
        apparent_temperature=row['apparent_temperature'],
        precipitation_probability=row['precipitation_probability'],
        precipitation=row['precipitation'],
        rain=row['rain'],
        weather_code=int(row['weather_code']) if row['weather_code'] is not None else None,
        visibility=row['visibility'],
        cloud_cover=row['cloud_cover'],
        surface_pressure=row['surface_pressure'],
        pressure_msl=row['pressure_msl'],
        wind_speed=row['wind_speed'],
        wind_direction=row['wind_direction'],
        wind_gusts=row['wind_gusts'],
        uv_index=row['uv_index'] if 'uv_index' in row.keys() else None,   # older DBs lack the column
        source=source,
        **extra,
    )


def _mode(series: pd.Series):
    counts = series.dropna().value_counts()
    return int(counts.index[0]) if len(counts) else None


def _circular_mean_deg(series: pd.Series):
    rad = np.deg2rad(series.dropna())
    if rad.empty:
        return None
    return float(np.rad2deg(np.arctan2(np.sin(rad).mean(), np.cos(rad).mean())) % 360)


RAIN_HOUR_MM = 0.1   # an hour counts as rainy at >= 0.1 mm
RAIN_DAY_MM = 1.0    # a day counts as rainy at >= 1 mm
UV_MIN_YEARS = 3     # uv_index climatology needs this many samples per calendar hour (column added in 2026)


def _derive_code(rain_prob, rainy_mode, rainy_median, cloud, light, moderate):
    # Rule: rain_prob>=0.5 -> 95 if storms dominate rainy years, 80 if showers do, else 61/63/65 by median rainy
    # intensity (<light/<moderate/else); 0.3-0.5 -> 80 scattered showers; else cloud <20/<50/<80/else -> 0/1/2/3.
    if rain_prob is not None and not pd.isna(rain_prob):
        if rain_prob >= 0.5:
            if rainy_mode is not None and rainy_mode >= 95:
                return 95
            if rainy_mode is not None and 80 <= rainy_mode <= 82:
                return 80
            if rainy_median is None or pd.isna(rainy_median) or rainy_median < light:
                return 61
            return 63 if rainy_median < moderate else 65
        if rain_prob >= 0.3:
            return 80
    if cloud is None or pd.isna(cloud):
        return None
    return 0 if cloud < 20 else 1 if cloud < 50 else 2 if cloud < 80 else 3


def _rain_stats(groups, amount_col, code_col, threshold):
    """Per group: share of rainy samples, mode of code and median amount among the rainy samples.
    Vectorized (a per-group .apply over ~8800 calendar hours took tens of seconds); only the mode is per group,
    and only over the groups that had rain."""
    obj, keys = groups.obj, groups.keys
    amount = obj[amount_col]
    flagged = obj.assign(_rainy=amount >= threshold).groupby(keys)
    rain_prob = flagged["_rainy"].mean().where(flagged[amount_col].count() > 0)
    rainy = obj[amount >= threshold].groupby(keys)
    return pd.DataFrame({
        "rain_prob": rain_prob,
        "rainy_mode": rainy[code_col].agg(_mode).reindex(rain_prob.index),
        "rainy_median": rainy[amount_col].median().reindex(rain_prob.index),
    })


# --- Locations -> weather series ---------------------------------------------------------------------
# A location (ward id, 'tsn' or a cell_id) maps to its Open-Meteo grid cell; the cell's series_id is the
# location_id column of the weather tables.

LOCATION_DESC = "Ward/commune id (GET /locations), a cell_id, or 'tsn'. Default: tsn."
CLIM_MIN_HOURS = 3 * 8760 * 0.9   # a series needs ~3 years to have its own climatology
HIST_CLIM_MIN_HOURS = 2 * 8760 * 0.9   # ~2 years once its cells_history.db rows are merged in


class Series:
    def __init__(self, location_id: str, cell_id: Optional[str], series_id: str):
        self.location_id, self.cell_id, self.series_id = location_id, cell_id, series_id


def _resolve_location(location_id: Optional[str]) -> Series:
    lid = (location_id or DEFAULT_LOCATION_ID).strip()
    if lid == DEFAULT_LOCATION_ID:
        return Series(lid, DEFAULT_LOCATION_ID, DEFAULT_LOCATION_ID)
    try:
        row = execute_one("SELECT c.cell_id, c.series_id FROM locations l JOIN cells c ON c.cell_id = l.cell_id "
                          "WHERE l.id = ?", (lid,))
        if row is None:
            row = execute_one("SELECT cell_id, series_id FROM cells WHERE cell_id = ?", (lid,))
    except sqlite3.OperationalError:   # DB without locations/cells tables
        row = None
    if row is None:
        raise HTTPException(status_code=404, detail=f"Không tìm thấy địa điểm '{lid}'")
    return Series(lid, row["cell_id"], row["series_id"])


def _clim_series(sid: str) -> str:
    """The series whose climatology is used: its own if it has ~3 years of rows in weather.db, or ~2 years with
    its cells_history.db rows merged in; else the 10-year 'tsn' one."""
    if sid == DEFAULT_LOCATION_ID:
        return sid
    row = execute_one("SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM hourly_weather WHERE location_id = ?",
                      (sid,))
    own = row[0] if row else 0
    if own >= CLIM_MIN_HOURS:
        return sid
    n_hist, lo, hi = _history_span(sid)
    if n_hist:   # weather.db hours inside the history span count as duplicates (dropped when merging)
        row = execute_one("SELECT COUNT(*) FROM hourly_weather WHERE location_id = ? "
                          "AND (timestamp < ? OR timestamp > ?)", (sid, lo, hi))
        own = row[0] if row else 0
    return sid if n_hist + own >= HIST_CLIM_MIN_HOURS else DEFAULT_LOCATION_ID


# --- Per-cell history (cells_history.db, filled by scripts/backfill_history.py) ------------------------
# Same Open-Meteo variables and units as hourly_weather, keyed by cell_id, naive local timestamps. It lacks
# precipitation_probability, rain, visibility and uv_index: rain is taken as precipitation (no snow here); the
# others stay NaN so their means come from the weather.db rows only (uv keeps its UV_MIN_YEARS gate).
# Opened read-only (backfill may be writing); a missing/locked file just means "no history".

def _history_connect() -> Optional[sqlite3.Connection]:
    path = Path(HISTORY_DB_PATH)
    if not path.is_file():
        return None
    return sqlite3.connect(f"file:{path.resolve().as_posix()}?mode=ro", uri=True, timeout=10)


def _history_cells(sid: str) -> List[str]:
    """cell_ids of a series (series_id == cell_id for Open-Meteo cells)."""
    try:
        rows = execute_query("SELECT cell_id FROM cells WHERE series_id = ?", (sid,))
    except sqlite3.OperationalError:
        rows = []
    return [r["cell_id"] for r in rows] or [sid]


@lru_cache(maxsize=128)
def _history_span(sid: str):
    """(row count, min timestamp, max timestamp) of the series in cells_history.db; (0, None, None) if none."""
    try:
        con = _history_connect()
        if con is None:
            return 0, None, None
        with closing(con):
            cells = _history_cells(sid)
            n, lo, hi = con.execute(f"SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM hourly WHERE cell_id "
                                    f"IN ({','.join('?' * len(cells))})", cells).fetchone()
    except sqlite3.Error:
        return 0, None, None
    return (n or 0), lo, hi


def _history_frame(sid: str) -> Optional[pd.DataFrame]:
    if sid == DEFAULT_LOCATION_ID or not _history_span(sid)[0]:
        return None
    try:
        con = _history_connect()
        if con is None:
            return None
        with closing(con):
            cells = _history_cells(sid)
            df = pd.read_sql(f"SELECT * FROM hourly WHERE cell_id IN ({','.join('?' * len(cells))})", con,
                             params=cells, parse_dates=["timestamp"])
    except (sqlite3.Error, pd.errors.DatabaseError):
        return None
    df = df.drop(columns=["cell_id"])
    df["rain"] = df["precipitation"]
    return df


def _climatology(sid: str = DEFAULT_LOCATION_ID):
    """Multi-year averages per calendar hour and per calendar day of one series, cached per process."""
    # Always pass sid positionally: lru_cache keys `f()` and `f('tsn')` separately (a second ~10-30 s build).
    return _climatology_of(sid)


@lru_cache(maxsize=16)
def _climatology_of(sid: str):
    with sqlite3.connect(DATABASE_PATH) as con:
        cols = {r[1] for r in con.execute("PRAGMA table_info(hourly_weather)")}
        if "location_id" in cols:
            df = pd.read_sql("SELECT * FROM hourly_weather WHERE location_id = ?", con, params=(sid,),
                             parse_dates=["timestamp"])
        else:
            df = pd.read_sql("SELECT * FROM hourly_weather", con, parse_dates=["timestamp"])
    hist = _history_frame(sid)
    if hist is not None and len(hist):   # weather.db wins on duplicate hours (it has every column)
        df = (hist.reindex(columns=df.columns) if df.empty else
              pd.concat([df, hist], ignore_index=True).drop_duplicates("timestamp", keep="first"))
        num = [c for c in hist.columns if c != "timestamp"]
        df[num] = df[num].apply(pd.to_numeric, errors="coerce")   # all-NULL weather.db columns come in as object
    ts = df["timestamp"]
    df["month"], df["day"], df["hour"], df["year"] = ts.dt.month, ts.dt.day, ts.dt.hour, ts.dt.year

    mean_cols = ["temperature", "humidity", "dew_point", "apparent_temperature", "precipitation_probability",
                 "precipitation", "rain", "visibility", "cloud_cover", "surface_pressure", "pressure_msl",
                 "wind_speed", "wind_gusts"]
    by_hour = df.groupby(["month", "day", "hour"])
    hourly = by_hour[mean_cols].mean()
    rad = np.deg2rad(df["wind_direction"])   # circular mean, vectorized (= _circular_mean_deg per group)
    trig = pd.DataFrame({"s": np.sin(rad), "c": np.cos(rad)}).groupby([df["month"], df["day"], df["hour"]]).mean()
    hourly["wind_direction"] = np.rad2deg(np.arctan2(trig["s"], trig["c"])) % 360
    hourly["precipitation_median"] = by_hour["precipitation"].median()
    if "uv_index" in df:
        hourly["uv_index"] = by_hour["uv_index"].mean().where(by_hour["uv_index"].count() >= UV_MIN_YEARS)
    else:
        hourly["uv_index"] = np.nan
    rs = _rain_stats(by_hour, "precipitation", "weather_code", RAIN_HOUR_MM)
    hourly["rain_probability"] = rs["rain_prob"]
    hourly["weather_code"] = [
        _derive_code(p, m, med, c, light=2.5, moderate=7.6)
        for p, m, med, c in zip(rs["rain_prob"], rs["rainy_mode"], rs["rainy_median"], hourly["cloud_cover"])]

    per_year = df.groupby(["year", "month", "day"]).agg(
        temp_min=("temperature", "min"), temp_max=("temperature", "max"),
        precip_total=("precipitation", "sum"), wind_max=("wind_speed", "max"),
        gust_max=("wind_gusts", "max"), code_max=("weather_code", "max"))
    by_day = df.groupby(["month", "day"])
    by_cal_day = per_year.groupby(["month", "day"])
    daily = by_cal_day[["temp_min", "temp_max", "precip_total", "wind_max", "gust_max"]].mean()
    daily["temp_avg"] = by_day["temperature"].mean()
    daily["humidity_avg"] = by_day["humidity"].mean()
    daily["cloud_avg"] = by_day["cloud_cover"].mean()
    daily["precip_median"] = by_cal_day["precip_total"].median()
    rs = _rain_stats(by_cal_day, "precip_total", "code_max", RAIN_DAY_MM)
    daily["rain_day_prob"] = rs["rain_prob"]
    daily["weather_code"] = [
        _derive_code(p, m, med, c, light=10, moderate=50)
        for p, m, med, c in zip(rs["rain_prob"], rs["rainy_mode"], rs["rainy_median"], daily["cloud_avg"])]
    return hourly, daily


def invalidate_climatology():
    """Drop the cached climatology so the next request recomputes it (call after ingesting new rows)."""
    _climatology_of.cache_clear()
    _history_span.cache_clear()
    _replay_ai_rain.cache_clear()
    _own_issue.cache_clear()


def _code(value):
    return None if value is None or pd.isna(value) else int(value)


# --- Time travel ("at") -------------------------------------------------------------------------------
# Live mode (no `at`): effective now = current HCMC hour. Replay mode: effective now = floor-to-hour(at);
# nothing after it may reach /current or the AI inputs. DB timestamps are naive local time.

TS_FMT = "%Y-%m-%d %H:%M:%S"
AT_DESC = "Replay time (ISO 8601, naive = HCMC time). Omit for live mode."


def _floor_hour(dt: datetime) -> datetime:
    return dt.replace(minute=0, second=0, microsecond=0)


def _naive(dt: datetime) -> datetime:
    """Aware -> naive HCMC wall time (the DB format)."""
    return to_local(dt).replace(tzinfo=None)


def _check_bounds(eff: datetime, sid: str = DEFAULT_LOCATION_ID) -> datetime:
    if eff > _floor_hour(to_local(now_local())):
        raise HTTPException(status_code=400, detail="`at` is after the current time")
    row = execute_one("SELECT MIN(timestamp) FROM hourly_weather WHERE location_id = ?", (sid,))
    if not row or row[0] is None:
        raise HTTPException(status_code=404, detail="No weather data available")
    earliest = to_local(row[0]) + timedelta(hours=ai_model.MIN_HISTORY_HOURS)
    if eff < earliest:
        raise HTTPException(status_code=400, detail=f"`at` must be >= {earliest.isoformat()}")
    return eff


def _resolve_at(at: Optional[str], sid: str = DEFAULT_LOCATION_ID) -> Optional[datetime]:
    """None in live mode, else the validated effective now (aware HCMC, floored to the hour)."""
    if at is None:
        return None
    text = at.strip()
    if "T" in text and " " in text:   # an unencoded "+07:00" arrives as " 07:00"
        text = text.replace(" ", "+")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid `at`; use ISO 8601, e.g. 2026-10-07T12:00")
    return _check_bounds(_floor_hour(to_local(parsed)), sid)


def _latest_observed(sid: str = DEFAULT_LOCATION_ID) -> Optional[datetime]:
    row = execute_one("SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ?", (sid,))
    return datetime.fromisoformat(row[0]) if row and row[0] else None


def _observed_rows(lo: datetime, hi: datetime, sid: str) -> Dict[datetime, sqlite3.Row]:
    rows = execute_query("SELECT * FROM hourly_weather WHERE location_id = ? AND timestamp >= ? AND timestamp <= ? "
                         "ORDER BY timestamp", (sid, lo.strftime(TS_FMT), hi.strftime(TS_FMT)))
    return {datetime.fromisoformat(r["timestamp"]): r for r in rows}


def _forecast_rows(lo: datetime, hi: datetime, sid: str) -> Dict[datetime, sqlite3.Row]:
    """Rows of the latest NWP issue in [lo, hi]; {} if there is no issue (or no nwp_forecast table)."""
    try:
        row = execute_one("SELECT MAX(issued_at) FROM nwp_forecast WHERE location_id = ?", (sid,))
        if not row or not row[0]:
            return {}
        rows = execute_query(
            "SELECT * FROM nwp_forecast WHERE location_id = ? AND issued_at = ? AND timestamp >= ? AND timestamp <= ?",
            (sid, row[0], lo.strftime(TS_FMT), hi.strftime(TS_FMT)))
    except sqlite3.OperationalError:   # DB not migrated (no nwp_forecast table)
        return {}
    return {datetime.fromisoformat(r["timestamp"]): r for r in rows}


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


def _aq_rows(lo: datetime, hi: datetime, sid: str) -> Dict[datetime, sqlite3.Row]:
    """air_quality rows in [lo, hi]; {} if the table does not exist yet."""
    try:
        rows = execute_query("SELECT * FROM air_quality WHERE location_id = ? AND timestamp >= ? AND timestamp <= ?",
                             (sid, lo.strftime(TS_FMT), hi.strftime(TS_FMT)))
    except sqlite3.OperationalError:
        return {}
    return {datetime.fromisoformat(r["timestamp"]): r for r in rows}


def _aq_fields(row) -> dict:
    return {"us_aqi": row["us_aqi"], "pm2_5": row["pm2_5"], "pm10": row["pm10"]} if row is not None else {}


def _series(times: List[datetime], obs_until: Optional[datetime], use_forecast: bool,
            sid: str = DEFAULT_LOCATION_ID) -> List[Optional[WeatherData]]:
    """Live uses our trained model only. Replay is a historical reference, not an AI backtest."""
    lo, hi = times[0], times[-1]
    if use_forecast:
        now = _naive(_floor_hour(to_local(now_local())))
        obs_until = min(obs_until, now) if obs_until is not None else None
        obs = _observed_rows(lo, min(hi, obs_until), sid) if obs_until is not None and lo <= obs_until else {}
        missing = [t for t in times if t not in obs]
        fc = _own_forecast_rows(sid, now) if missing else {}
        aq = _aq_rows(lo, min(hi, now), sid) if lo <= now else {}
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
                hourly, _ = _climatology(_clim_series(sid))
            out.append(_climatology_item(hourly, t))
    return out


@lru_cache(maxsize=128)
def _own_issue(db_path: str, sid: str, cell_id: str, issued_at: str,
               revision: tuple) -> Dict[datetime, WeatherData]:
    history = ai_model.load_history_from_db(db_path=db_path, until=datetime.fromisoformat(issued_at),
                                          location_id=sid)
    result = long_range_model.predict(history, cell_id)
    issue_time = _naive(to_local(result['issued_at']))
    out = {}
    for horizon, p in result['predictions'].items():
        t = issue_time + timedelta(hours=int(horizon.rstrip('h')))
        prob, amount, cloud = p.get('rain_probability'), p.get('precipitation_mm'), p.get('cloud_cover')
        out[t] = WeatherData(timestamp=to_local(t), temperature=p['temperature'],
                             humidity=p.get('humidity'), precipitation=amount, rain=amount,
                             wind_speed=p.get('wind_speed'), cloud_cover=cloud,
                             rain_probability=prob,
                             precipitation_probability=None if prob is None else round(prob * 100, 2),
                             weather_code=_derive_code(prob, None, amount, cloud, 2.5, 7.5), source='ai')
    return out


def _own_forecast_rows(sid: str, now: datetime) -> Dict[datetime, WeatherData]:
    row = execute_one('SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ? AND timestamp <= ?',
                      (sid, now.strftime(TS_FMT)))
    issued = datetime.fromisoformat(row[0]) if row and row[0] else None
    if issued is None or now - issued > timedelta(hours=3):
        raise HTTPException(status_code=503, detail='Chưa có dữ liệu đầu vào trong 3 giờ gần nhất để chạy AI riêng.')
    try:
        cell = execute_one('SELECT cell_id FROM cells WHERE series_id = ? ORDER BY cell_id = series_id DESC LIMIT 1',
                           (sid,))
        cid = ai_model.canonical_cell_id(cell[0] if cell else sid)
        # Another ingest process may revise existing hours without advancing the issue time.
        inputs = [Path(DATABASE_PATH), Path(str(DATABASE_PATH) + '-wal')]
        stamp = (*long_range_model.artifact_revision(),
                 *(path.stat().st_mtime_ns if path.exists() else 0 for path in inputs))
        return _own_issue(str(DATABASE_PATH), sid, cid, issued.isoformat(), stamp)
    except (ValueError, OSError) as e:
        raise HTTPException(status_code=503, detail=f'Dự báo AI riêng chưa sẵn sàng: {e}')


# WMO codes from least to most severe (showers rank with rain of the same intensity).
_SEVERITY = {c: i for i, c in enumerate(
    [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 80, 63, 81, 66, 65, 82, 67,
     71, 73, 75, 77, 85, 86, 95, 96, 99])}


def _severe_code(codes: List[Optional[int]]) -> Optional[int]:
    """Most severe code of an hour-ordered list, ignoring drizzle hours with no wet (>= 51) neighbour."""
    def wet(c):
        return c is not None and c >= 51

    kept = [c for i, c in enumerate(codes) if c is not None and not (
        51 <= c <= 57 and not wet(codes[i - 1] if i > 0 else None)
        and not wet(codes[i + 1] if i + 1 < len(codes) else None))]
    kept = kept or [c for c in codes if c is not None]
    return max(kept, key=lambda c: _SEVERITY.get(c, -1)) if kept else None


def _clim_daily_summary(day: date, row) -> DailySummary:
    return DailySummary(
        date=day.strftime("%Y-%m-%d"),
        temperature_min=_num(row['temp_min'], 1),
        temperature_max=_num(row['temp_max'], 1),
        temperature_avg=_num(row['temp_avg'], 1),
        humidity_avg=_num(row['humidity_avg'], 1),
        precipitation_total=_num(row['precip_total'], 2),
        weather_code=_code(row['weather_code']),
        wind_speed_max=_num(row['wind_max'], 1),
        cloud_cover_avg=_num(row['cloud_avg'], 1),
        rain_day_probability=_num(row['rain_day_prob'], 2),
        precipitation_median=_num(row['precip_median'], 2),
        wind_gusts_max=_num(row['gust_max'], 1),
        source="climatology",
    )


def _daily_summary(day: date, items: List[Optional[WeatherData]], clim_daily: pd.DataFrame) -> Optional[DailySummary]:
    """Aggregate one local day's hour items (see get_daily_forecast for the rules)."""
    present = [i for i in items if i is not None]
    kinds = {i.source for i in present}
    key = (day.month, day.day)
    crow = clim_daily.loc[key] if key in clim_daily.index else None

    def agg(field, fn, digits):
        v = [getattr(i, field) for i in present if getattr(i, field) is not None]
        if 'ai' in kinds and len(v) != 24:
            return None  # Partial known hours are not a forecast of the full-day statistic.
        return _num(fn(v), digits) if v else None

    if kinds <= {"climatology"}:
        if crow is None:
            return None
        summary = _clim_daily_summary(day, crow)
        summary.uv_index_max = agg("uv_index", max, 1)
        return summary

    def mean(v):
        return sum(v) / len(v)

    total = agg("precipitation", sum, 2)
    obs_precip = [i.precipitation for i in present if i.source == "observed" and i.precipitation is not None]
    obs_rain_day = (1.0 if sum(obs_precip) >= RAIN_DAY_MM else 0.0) if obs_precip else None
    clim_prob = _num(crow['rain_day_prob'], 2) if crow is not None else None
    # Codes of the real (observed/forecast) hours only; climatology hours break drizzle adjacency.
    codes = [i.weather_code if i is not None and i.source != "climatology" else None for i in items]

    if "forecast" in kinds or "ai" in kinds:
        source = "ai" if "ai" in kinds else "forecast"
        probs = [i.rain_probability for i in present if i.source in {"forecast", "ai"} and i.rain_probability is not None]
        if obs_rain_day is not None:
            probs.append(obs_rain_day)
        # Hourly probabilities do not estimate the distinct daily-total >=1mm event.
        rain_day_prob = None if source == 'ai' else max(probs) if probs else clim_prob
        code, median = _severe_code(codes), None if source == "ai" else total
    elif kinds == {"observed"} and len(present) == 24:
        source = "observed"
        rain_day_prob = obs_rain_day
        code, median = _severe_code(codes), total
    else:   # observed hours + climatology for the rest of the day
        source = "climatology"
        known = [p for p in (clim_prob, obs_rain_day) if p is not None]
        rain_day_prob = max(known) if known else None
        both = [c for c in (_code(crow['weather_code']) if crow is not None else None, _severe_code(codes))
                if c is not None]
        code = max(both, key=lambda c: _SEVERITY.get(c, -1)) if both else None
        median = _num(crow['precip_median'], 2) if crow is not None else total

    return DailySummary(
        date=day.strftime("%Y-%m-%d"),
        temperature_min=agg("temperature", min, 1),
        temperature_max=agg("temperature", max, 1),
        temperature_avg=agg("temperature", mean, 1),
        humidity_avg=agg("humidity", mean, 1),
        precipitation_total=total,
        weather_code=code,
        wind_speed_max=agg("wind_speed", max, 1),
        cloud_cover_avg=agg("cloud_cover", mean, 1),
        rain_day_probability=_num(rain_day_prob, 2),
        precipitation_median=median,
        wind_gusts_max=agg("wind_gusts", max, 1),
        uv_index_max=agg("uv_index", max, 1),
        us_aqi_max=agg("us_aqi", max, 0),
        source=source,
    )


# --- Endpoints ----------------------------------------------------------------------------------------

@router.get("/current", response_model=WeatherData)
def get_current_weather(at: Optional[str] = Query(default=None, description=AT_DESC),
                        location_id: Optional[str] = Query(default=None, description=LOCATION_DESC)):
    """Latest record of the location's series (replay: latest record <= floor-to-hour(at))."""
    loc = _resolve_location(location_id)
    sid = loc.series_id
    eff = _resolve_at(at, sid)
    if eff is None:
        row = execute_one('SELECT * FROM hourly_weather WHERE location_id = ? AND timestamp <= ? '
                          'ORDER BY timestamp DESC LIMIT 1', (sid, _naive(now_local()).strftime(TS_FMT)))
    else:
        row = execute_one("SELECT * FROM hourly_weather WHERE location_id = ? AND timestamp <= ? "
                          "ORDER BY timestamp DESC LIMIT 1", (sid, _naive(eff).strftime(TS_FMT)))
    if not row:
        raise HTTPException(status_code=404, detail="No weather data available")
    # Air quality at the same hour, else the nearest within +-1 h, never after the effective now.
    ts = datetime.fromisoformat(row["timestamp"])
    now = _naive(eff if eff is not None else _floor_hour(to_local(now_local())))
    aq = _aq_rows(ts - timedelta(hours=1), min(ts + timedelta(hours=1), now), sid)
    best = min(aq, key=lambda t: (abs(t - ts), t > ts)) if aq else None
    return row_to_weather_data(row, **_aq_fields(aq.get(best)))


@lru_cache(maxsize=1)
def _v2_tsn_evaluation() -> Optional[dict]:
    """Test-set metrics of the single-point v2 model (trained and tested on the 'tsn' series only)."""
    path = Path(ai_model.__file__).resolve().parent / "models" / "model_metadata.json"
    if not path.exists():
        return None
    meta = json.loads(path.read_text(encoding="utf-8"))
    if "test_metrics_temperature" not in meta:
        return None
    out = {"cell_id": DEFAULT_LOCATION_ID, "test_period": "..".join(t[:10] for t in meta["test"])}
    beats = True
    for h in ("1h", "3h", "6h"):
        t = {m["Model"]: m["MAE"] for m in meta["test_metrics_temperature"] if m["Horizon"] == h}
        r = {m["Model"]: m["F1"] for m in meta["test_metrics_rain"] if m["Horizon"] == h}
        lgbm_f1 = next((v for k, v in r.items() if k.startswith("LightGBM") and "val-tuned" in k), None)
        out[f"temperature_mae_{h}"] = round(t["LightGBM"], 3)
        out[f"rain_f1_{h}"] = None if lgbm_f1 is None else round(lgbm_f1, 3)
        base_mae = [t[k] for k in ("Persistence", "Climatology") if k in t]
        base_f1 = [r[k] for k in ("Persistence", "Climatology") if k in r]
        beats &= bool(base_mae) and t["LightGBM"] < min(base_mae)
        beats &= lgbm_f1 is not None and bool(base_f1) and lgbm_f1 > max(base_f1)
    out["beats_baselines"] = beats
    return out


def _evaluation(loc: Series) -> Optional[dict]:
    """Test-set evaluation of the serving model at the location's cell; None if it was never evaluated there."""
    if hasattr(ai_model, "evaluation_for"):
        ev = ai_model.evaluation_for(loc.cell_id)
        if ev is not None or loc.series_id != DEFAULT_LOCATION_ID:
            return ev
    return _v2_tsn_evaluation() if loc.series_id == DEFAULT_LOCATION_ID else None


def _ai_issue(until: Optional[datetime], loc: Series) -> dict:
    """AI forecast issued at the series' last stored hour <= until (naive local; None = latest)."""
    history = ai_model.load_history_from_db(db_path=str(DATABASE_PATH),
                                          until=until if until is not None else _naive(now_local()),
                                          location_id=loc.series_id)
    if len(history) < ai_model.MIN_HISTORY_HOURS:
        raise HTTPException(status_code=503, detail="Không đủ dữ liệu lịch sử để dự báo")
    try:
        if hasattr(ai_model, "predict_for_location"):
            result = ai_model.predict_for_location(history, loc.cell_id)
        else:
            result = ai_model.predict_from_history(history)
    except ValueError as e:
        raise HTTPException(status_code=503, detail=f"Không thể dự báo AI: {e}")
    issued = to_local(result["issued_at"])
    result["issued_at"] = issued.isoformat()
    for key, pred in result["predictions"].items():
        pred["target_time"] = (issued + timedelta(hours=int(key.rstrip("h")))).isoformat()
    result["location_id"], result["cell_id"] = loc.location_id, loc.cell_id
    result["evaluation"] = _evaluation(loc)
    return result


@router.get("/ai-forecast")
def get_ai_forecast(at: Optional[str] = Query(default=None, description=AT_DESC),
                    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC)):
    """LightGBM forecast of temperature and rain probability 1/3/6 h after the latest observation (<= at)."""
    loc = _resolve_location(location_id)
    eff = _resolve_at(at, loc.series_id)
    return _ai_issue(None if eff is None else _naive(eff), loc)


@router.get("/ai-verify")
def get_ai_verify(at: Optional[str] = Query(default=None, description="Issue time (ISO 8601); default now - 6 h"),
                  location_id: Optional[str] = Query(default=None, description=LOCATION_DESC)):
    """The AI forecast issued at `at` next to what was actually observed at each target hour."""
    loc = _resolve_location(location_id)
    eff = _resolve_at(at, loc.series_id)
    if eff is None:
        eff = _check_bounds(_floor_hour(to_local(now_local())) - timedelta(hours=6), loc.series_id)
    issue = _ai_issue(_naive(eff), loc)
    horizons = []
    for key, pred in issue["predictions"].items():
        target = datetime.fromisoformat(pred["target_time"])
        row = execute_one("SELECT temperature, precipitation FROM hourly_weather "
                          "WHERE location_id = ? AND timestamp = ?",
                          (loc.series_id, _naive(target).strftime(TS_FMT)))
        temp = row["temperature"] if row else None
        precip = row["precipitation"] if row else None
        horizons.append({
            "horizon": key,
            "target_time": pred["target_time"],
            "predicted_temperature": pred["temperature"],
            "predicted_rain_probability": pred["rain_probability"],
            "actual_temperature": temp,
            "actual_precipitation": precip,
            "actual_rain": None if precip is None else precip >= RAIN_HOUR_MM,
            "abs_error_temperature": None if temp is None else round(abs(pred["temperature"] - temp), 2),
        })
    return {"issued_at": issue["issued_at"], "model_version": issue["model_version"], "horizons": horizons,
            "location_id": loc.location_id, "cell_id": loc.cell_id, "evaluation": issue["evaluation"]}


@router.get("/hourly", response_model=List[WeatherData])
def get_hourly_forecast(
    hours: int = Query(default=24, ge=1, le=168, description="Number of hours to forecast (1-168)"),
    at: Optional[str] = Query(default=None, description=AT_DESC),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """N hours from now: current analysis then our own AI, without external forecast fallback.
    Replay is historical analysis/climatology, not an AI backtest."""
    sid = _resolve_location(location_id).series_id
    eff = _resolve_at(at, sid)
    start = _naive(eff if eff is not None else _floor_hour(to_local(now_local())))
    times = [start + timedelta(hours=i) for i in range(hours)]
    items = [i for i in _series(times, _latest_observed(sid), use_forecast=eff is None, sid=sid) if i is not None]
    if not items:
        raise HTTPException(status_code=404, detail="No forecast data available")
    return items


@router.get('/forecast-status')
def get_forecast_status():
    """Artifact capabilities and held-out evaluation; availability is not a skill claim."""
    info = long_range_model.status()
    info['experimental'] = True
    if info['status'] == 'available':
        info['evaluation'] = _own_evaluation(long_range_model.artifact_revision())
    return info


@lru_cache(maxsize=2)
def _own_evaluation(revision: tuple) -> Optional[dict]:
    try:
        path = Path(revision[0])
        report = json.loads((path / 'evaluation.json').read_text(encoding='utf-8'))
        meta = json.loads((path / 'metadata.json').read_text(encoding='utf-8'))
        return {'test_period': meta['split']['test'], 'targets': {
            name: {'metric': result['test']['primary_metric'], 'overall': result['test']['overall'],
                   'by_day': result['test']['by_day']} for name, result in report.items()}}
    except (OSError, ValueError, KeyError, TypeError):
        return None


@router.get("/daily", response_model=List[DailySummary])
def get_daily_forecast(
    days: int = Query(default=7, ge=1, le=14, description="Number of days to forecast (1-14)"),
    at: Optional[str] = Query(default=None, description=AT_DESC),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """Daily aggregation of our hourly AI plus already known hours today.
    rain_day_probability is null for AI until a daily-event model is trained and evaluated.
    Replay is a separately labelled historical reference."""
    sid = _resolve_location(location_id).series_id
    eff = _resolve_at(at, sid)
    now = _naive(eff if eff is not None else _floor_hour(to_local(now_local())))
    first = datetime(now.year, now.month, now.day)
    times = [first + timedelta(hours=i) for i in range(days * 24)]
    items = _series(times, _latest_observed(sid), use_forecast=eff is None, sid=sid)
    clim_daily = _climatology(_clim_series(sid))[1] if eff is not None else pd.DataFrame()
    forecasts = []
    for d in range(days):
        summary = _daily_summary((first + timedelta(days=d)).date(), items[d * 24:(d + 1) * 24], clim_daily)
        if summary is not None:
            forecasts.append(summary)
    if not forecasts:
        raise HTTPException(status_code=404, detail="No forecast data available")
    return forecasts


@router.get("/bundle")
def get_weather_bundle(
    response: Response,
    hours: int = Query(default=48, ge=1, le=168, description="Number of hours (1-168)"),
    days: int = Query(default=7, ge=1, le=14, description="Number of days (1-14)"),
    at: Optional[str] = Query(default=None, description=AT_DESC),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """/current + /hourly + /daily + /ai-forecast in one call (same handlers, same output).
    An AI 503 does not fail the bundle: ai_forecast = null and ai_error = its detail."""
    loc = _resolve_location(location_id)
    eff = _resolve_at(at, loc.series_id)   # validate `at` once, before any work
    try:
        ai, ai_error = get_ai_forecast(at=at, location_id=location_id), None
    except HTTPException as e:
        if e.status_code != 503:
            raise
        ai, ai_error = None, e.detail
    if eff is None:
        response.headers["Cache-Control"] = "max-age=60"
    forecast_error = None
    try:
        hourly = get_hourly_forecast(hours=hours, at=at, location_id=location_id)
    except HTTPException as e:
        if e.status_code != 503:
            raise
        hourly, forecast_error = [], e.detail
    try:
        daily = get_daily_forecast(days=days, at=at, location_id=location_id)
    except HTTPException as e:
        if e.status_code != 503:
            raise
        daily, forecast_error = [], forecast_error or e.detail
    return {
        "location_id": loc.location_id,
        "cell_id": loc.cell_id,
        "generated_at": to_local(now_local()).isoformat(),
        "current": jsonable_encoder(get_current_weather(at=at, location_id=location_id)),
        "hourly": jsonable_encoder(hourly),
        "daily": jsonable_encoder(daily),
        "forecast_provider": "historical_reference" if eff is not None else "sky_weather_ai",
        "forecast_error": forecast_error,
        "ai_forecast": ai,
        "ai_error": ai_error,
    }


@router.get("/history")
def get_historical_weather(
    start_date: str = Query(..., description="Start date (YYYY-MM-DD)"),
    end_date: str = Query(..., description="End date (YYYY-MM-DD)"),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """Observed hourly rows of the location's series for a date range (max 365 days)."""
    try:
        start = datetime.strptime(start_date, "%Y-%m-%d")
        end = datetime.strptime(end_date, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")
    if end < start:
        raise HTTPException(status_code=400, detail="End date must be after start date")
    if (end - start).days > 365:
        raise HTTPException(status_code=400, detail="Date range cannot exceed 365 days")
    sid = _resolve_location(location_id).series_id
    rows = execute_query(
        "SELECT * FROM hourly_weather WHERE location_id = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
        (sid, start.strftime("%Y-%m-%d 00:00:00"), end.strftime("%Y-%m-%d 23:59:59")))
    return [row_to_weather_data(row) for row in rows]


# --- Map ----------------------------------------------------------------------------------------------
MAP_ALERT_RAIN_MM = 10.0   # >= 10 mm in the next 3 h counts as heavy rain on the map


@lru_cache(maxsize=32)
def _replay_ai_rain(now: datetime, series: tuple, revision: tuple) -> Dict[str, float]:
    """Max AI rain probability over +1h/+3h for each (series_id, cell_id), issued exactly at `now` (naive)."""
    out = {}
    for sid, cell_id in series:
        hist = ai_model.load_history_from_db(db_path=str(DATABASE_PATH), until=now, location_id=sid)
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
    return _naive(eff if eff is not None else _floor_hour(to_local(now_local())))


def _map_meta(now: datetime, replay: bool) -> dict:
    """Only advertise future frames covered by a trained model and fresh input."""
    info = long_range_model.status()
    issues = []
    try:
        rows = execute_query('SELECT DISTINCT c.series_id, '
                             '(SELECT MAX(timestamp) FROM hourly_weather h '
                             'WHERE h.location_id = c.series_id AND h.timestamp <= ?) '
                             'FROM cells c',
                             (now.strftime(TS_FMT),)) if info['status'] == 'available' and not replay else []
    except sqlite3.OperationalError:
        rows = []
    for cid, timestamp in rows:
        if timestamp and ai_model.canonical_cell_id(cid) in info.get('cell_ids', []):
            issue = datetime.fromisoformat(timestamp)
            if timedelta(0) <= now - issue <= timedelta(hours=3) and to_local(issue) > to_local(info['trained_through']):
                try:
                    forecast = _own_forecast_rows(cid, now)
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
    """One item per grid cell. Live outlook and future frames use only our trained AI.
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
    lo, hi = (t + timedelta(hours=1)).strftime(TS_FMT), (t + timedelta(hours=3)).strftime(TS_FMT)
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
    if offset_hours == 0:
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
                forecast = _own_forecast_rows(sid, now)
            except HTTPException as exc:
                if exc.status_code != 503:
                    raise
                continue
            if offset_hours > 0 and t in forecast:
                cur[sid] = forecast[t].model_dump()
            nxt[sid] = [(forecast[v].precipitation, forecast[v].rain_probability, forecast[v].weather_code)
                        for v in (t + timedelta(hours=h) for h in (1, 2, 3)) if v in forecast]
    inputs = [Path(DATABASE_PATH), Path(str(DATABASE_PATH) + '-wal')]
    revision = (str(DATABASE_PATH), *long_range_model.artifact_revision(),
                *(path.stat().st_mtime_ns if path.exists() else 0 for path in inputs))
    ai_probs = _replay_ai_rain(now, tuple((sid, c['cell_id']) for sid, c in merged.items()), revision) if eff else {}
    source = "observed" if offset_hours == 0 else "ai"
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
