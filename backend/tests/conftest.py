"""
Shared fixtures: a small synthetic SQLite DB (3 years x 17 days, hourly), a frozen HCMC clock,
and TestClients bound to either the synthetic DB or the real backend/data/weather.db.
"""
import math
import os
import shutil
import sqlite3
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# Never start the background ingest scheduler (and never hit the network) during tests.
os.environ["INGEST_ENABLED"] = "0"

import database
import main
from database import LOCAL_TZ
from routers import weather as weather_router

REAL_DB = Path(__file__).resolve().parent.parent / "data" / "weather.db"

COLUMNS = ["timestamp", "temperature", "humidity", "dew_point", "apparent_temperature",
           "precipitation_probability", "precipitation", "rain", "weather_code", "visibility",
           "cloud_cover", "surface_pressure", "pressure_msl", "wind_speed", "wind_direction", "wind_gusts"]

SYN_YEARS = (2021, 2022, 2023)
SYN_FIRST_DAY = (6, 8)    # June 8 ...
SYN_LAST_DAY = (6, 24)    # ... June 24 (inclusive), every year
# Frozen "now": inside the synthetic window so /hourly (168 h) and /daily (14 d) are fully covered.
FROZEN_NOW = datetime(2024, 6, 10, 14, 23, 45, tzinfo=LOCAL_TZ)
# Row whose observable fields are all zero (checks that 0 is not turned into null).
ZERO_TS = datetime(2023, 6, 15, 3, 0)
LAST_TS = datetime(2023, 6, 24, 23, 0)

WMO_CODES = {0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77,
             80, 81, 82, 85, 86, 95, 96, 99}

SCHEMA = (
    'CREATE TABLE "hourly_weather" ("timestamp" TIMESTAMP, '
    + ", ".join(f'"{c}" REAL' for c in COLUMNS[1:]) + ")"
)


def _row(ts: datetime) -> dict:
    """Deterministic, roughly realistic HCMC rainy-season hour."""
    h, doy, year = ts.hour, ts.timetuple().tm_yday, ts.year
    temp = round(27 + 4 * math.sin(2 * math.pi * (h - 9) / 24) + 0.3 * (year - 2022) + 0.05 * (doy % 7), 1)
    rainy = 14 <= h <= 17 and (doy + year) % 3 == 0          # exactly 1 of 3 years per calendar day
    precip = round(0.5 + ((h + year) % 4) * 1.2, 1) if rainy else 0.0
    cloud = float((h * 7 + doy * 3) % 101)                    # hits 0 sometimes
    code = (63 if precip >= 2.5 else 61) if precip > 0 else (0 if cloud < 20 else 1 if cloud < 50 else 2 if cloud < 80 else 3)
    humidity = round(75 + 15 * math.cos(2 * math.pi * (h - 4) / 24), 1)
    return {
        "timestamp": ts.strftime("%Y-%m-%d %H:%M:%S"),
        "temperature": temp,
        "humidity": humidity,
        "dew_point": round(temp - (100 - humidity) / 5, 1),
        "apparent_temperature": round(temp + 3, 1),
        "precipitation_probability": float((h * 5 + doy) % 100),
        "precipitation": precip,
        "rain": precip,
        "weather_code": float(code),
        "visibility": 24000.0 - precip * 1000,
        "cloud_cover": cloud,
        "surface_pressure": round(1008 + math.sin(doy + h / 4), 1),
        "pressure_msl": round(1009 + math.sin(doy + h / 4), 1),
        "wind_speed": round(5 + (h % 6) * 1.5, 1),
        "wind_direction": float((h * 15 + doy * 10) % 360),  # hits 0 sometimes
        "wind_gusts": round(9 + (h % 6) * 2.0, 1),
    }


def _zero(row: dict) -> dict:
    row.update(temperature=0.0, precipitation_probability=0.0, precipitation=0.0, rain=0.0, weather_code=0.0,
               cloud_cover=0.0, wind_speed=0.0, wind_direction=0.0, wind_gusts=0.0)
    return row


def synthetic_rows() -> list[dict]:
    rows = []
    for year in SYN_YEARS:
        d = date(year, *SYN_FIRST_DAY)
        while d <= date(year, *SYN_LAST_DAY):
            for h in range(24):
                ts = datetime(d.year, d.month, d.day, h)
                r = _row(ts)
                rows.append(_zero(r) if ts in (ZERO_TS, LAST_TS) else r)
            d += timedelta(days=1)
    return rows


def write_db(path: Path, rows: list[dict], locations: bool = True) -> Path:
    """Old-schema DB with `rows` as the 'tsn' series. `locations`: migrate it and load the real
    locations/cells (multi-cell DB); False leaves the old single-location schema for migration tests."""
    with sqlite3.connect(path) as con:
        con.execute(SCHEMA)
        con.execute("CREATE INDEX idx_timestamp ON hourly_weather(timestamp)")
        insert_rows(con, rows)
        if locations:
            database.migrate(con)
            database.load_locations(con)
    con.close()
    return path


def insert_rows(con: sqlite3.Connection, rows: list[dict]) -> None:
    con.executemany(
        f"INSERT INTO hourly_weather ({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
        [tuple(r[c] for c in COLUMNS) for r in rows],
    )
    con.commit()


def point_app_at(mp: pytest.MonkeyPatch, db_path: Path) -> None:
    """DATABASE_PATH is imported by name in several modules; patch every copy."""
    mp.setattr(database, "DATABASE_PATH", db_path)
    mp.setattr(weather_router, "DATABASE_PATH", db_path)
    mp.setattr(main, "DATABASE_PATH", db_path)
    # Per-cell history sits next to it (data/history/ for the real DB; absent unless a test writes one).
    mp.setattr(weather_router, "HISTORY_DB_PATH", Path(db_path).parent / "history" / "cells_history.db")


def freeze_now(mp: pytest.MonkeyPatch, now: datetime = FROZEN_NOW) -> None:
    mp.setattr(weather_router, "now_local", lambda: now)
    mp.setattr(main, "now_local", lambda: now)


@pytest.fixture(autouse=True)
def _no_ingest_throttle(monkeypatch):
    """Ingest pacing (1 s between requests, rolling minute budget) is real sleeping: off in tests."""
    import ingest
    monkeypatch.setattr(ingest, "CHUNK_SLEEP", 0)
    monkeypatch.setattr(ingest, "MINUTE_BUDGET", 0)


@pytest.fixture
def syn_rows():
    return synthetic_rows()


@pytest.fixture
def syn_db(tmp_path, syn_rows, monkeypatch):
    path = write_db(tmp_path / "weather.db", syn_rows)
    point_app_at(monkeypatch, path)
    weather_router.invalidate_climatology()
    yield path
    weather_router.invalidate_climatology()


@pytest.fixture
def client(syn_db, monkeypatch):
    freeze_now(monkeypatch)
    # No `with`: skip the lifespan warm-up so tests that never touch climatology stay fast.
    yield TestClient(main.app)


@pytest.fixture(scope="module")
def real_client(tmp_path_factory):
    if not REAL_DB.exists():
        pytest.skip("real weather.db not found")
    snapshot = tmp_path_factory.mktemp('real-db-snapshot') / 'weather.db'
    # Lifespan migrations and seed loading must never write to the developer's live DB.
    with sqlite3.connect(REAL_DB.resolve().as_uri() + '?mode=ro', uri=True) as source:
        with sqlite3.connect(snapshot) as target:
            source.backup(target)
    with pytest.MonkeyPatch.context() as mp:
        point_app_at(mp, snapshot)
        weather_router.invalidate_climatology()
        with TestClient(main.app) as c:
            yield c
    weather_router.invalidate_climatology()


@pytest.fixture
def real_db_copy(tmp_path):
    if not REAL_DB.exists():
        pytest.skip("real weather.db not found")
    dst = tmp_path / "weather_copy.db"
    shutil.copyfile(REAL_DB, dst)
    return dst
