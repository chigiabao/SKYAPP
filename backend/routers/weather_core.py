"""
Shared helpers of the /weather endpoints: locations -> series, time travel (`at`), DB row readers.

DATABASE_PATH, HISTORY_DB_PATH and now_local live here as the single patch point for the weather_* modules
(they read them as core.X at call time).
"""
from fastapi import HTTPException
from datetime import datetime, timedelta
from typing import Dict, Optional
import sqlite3

import pandas as pd

from database import (execute_query, execute_one, DATABASE_PATH, HISTORY_DB_PATH, DEFAULT_LOCATION_ID,  # noqa: F401
                      now_local, to_local)
from models import WeatherData
import ai_model


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



RAIN_HOUR_MM = 0.1   # an hour counts as rainy at >= 0.1 mm
RAIN_DAY_MM = 1.0    # a day counts as rainy at >= 1 mm


# --- Locations -> weather series ---------------------------------------------------------------------
# A location (ward id, 'tsn' or a cell_id) maps to its Open-Meteo grid cell; the cell's series_id is the
# location_id column of the weather tables.

LOCATION_DESC = "Ward/commune id (GET /locations), a cell_id, or 'tsn'. Default: tsn."




class Series:
    def __init__(self, location_id: str, cell_id: Optional[str], series_id: str):
        self.location_id, self.cell_id, self.series_id = location_id, cell_id, series_id


def resolve_location(location_id: Optional[str]) -> Series:
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


_resolve_location = resolve_location



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


def _check_bounds(eff: datetime, sid: str = DEFAULT_LOCATION_ID, *, require_history: bool = True) -> datetime:
    if eff > _floor_hour(to_local(now_local())):
        raise HTTPException(status_code=400, detail="Thời điểm `at` nằm sau thời điểm hiện tại.")
    if not require_history:
        return eff
    row = execute_one("SELECT MIN(timestamp) FROM hourly_weather WHERE location_id = ?", (sid,))
    if not row or row[0] is None:
        raise HTTPException(status_code=404, detail="Chưa có dữ liệu thời tiết.")
    earliest = to_local(row[0]) + timedelta(hours=ai_model.MIN_HISTORY_HOURS)
    if eff < earliest:
        raise HTTPException(status_code=400, detail=f"Thời điểm `at` phải từ {earliest.isoformat()} trở về sau.")
    return eff


def _resolve_at(at: Optional[str], sid: str = DEFAULT_LOCATION_ID, *, require_history: bool = True) -> Optional[datetime]:
    """None in live mode, else the validated effective now (aware HCMC, floored to the hour)."""
    if at is None:
        return None
    text = at.strip()
    if "T" in text and " " in text:   # an unencoded "+07:00" arrives as " 07:00"
        text = text.replace(" ", "+")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        raise HTTPException(status_code=400, detail="Thời điểm `at` không hợp lệ; dùng ISO 8601, ví dụ 2026-10-07T12:00.")
    return _check_bounds(_floor_hour(to_local(parsed)), sid, require_history=require_history)


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
