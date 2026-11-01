"""
Multi-year climatology per series (weather.db merged with the per-cell cells_history.db), cached per process.
"""
from contextlib import closing
from functools import lru_cache
from pathlib import Path
from typing import List, Optional
import sqlite3

import numpy as np
import pandas as pd

from database import execute_query, execute_one, DEFAULT_LOCATION_ID
from routers import weather_core as core
from routers.weather_core import RAIN_HOUR_MM, RAIN_DAY_MM


def _mode(series: pd.Series):
    counts = series.dropna().value_counts()
    return int(counts.index[0]) if len(counts) else None


def _circular_mean_deg(series: pd.Series):
    rad = np.deg2rad(series.dropna())
    if rad.empty:
        return None
    return float(np.rad2deg(np.arctan2(np.sin(rad).mean(), np.cos(rad).mean())) % 360)


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


CLIM_MIN_HOURS = 3 * 8760 * 0.9   # a series needs ~3 years to have its own climatology
HIST_CLIM_MIN_HOURS = 2 * 8760 * 0.9   # ~2 years once its cells_history.db rows are merged in


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
    path = Path(core.HISTORY_DB_PATH)
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
    with sqlite3.connect(core.DATABASE_PATH) as con:
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
