"""
Database connection and session management.
"""
import json
import sqlite3
from pathlib import Path
from contextlib import contextmanager
from datetime import datetime
from zoneinfo import ZoneInfo

DATABASE_PATH = Path(__file__).parent / "data" / "weather.db"
# Built by scripts/build_locations.py (C1): locations.json, cells.json, hcmc_boundary.geojson, wards.geojson.
LOCATIONS_DIR = Path(__file__).parent / "data" / "locations"
# Per-cell multi-year history written by scripts/backfill_history.py (optional; read-only for the API).
HISTORY_DB_PATH = Path(__file__).parent / "data" / "history" / "cells_history.db"

# DB timestamps are naive local time (GMT+7); the API always emits them with an explicit +07:00 offset.
LOCAL_TZ = ZoneInfo("Asia/Ho_Chi_Minh")


def now_local() -> datetime:
    """Current time in Ho Chi Minh City, independent of the server's clock zone."""
    return datetime.now(LOCAL_TZ)


def to_local(value) -> datetime:
    """Parse/attach Asia/Ho_Chi_Minh to a DB timestamp (naive = local); aware values are converted."""
    dt = datetime.fromisoformat(value) if isinstance(value, str) else value
    return dt.replace(tzinfo=LOCAL_TZ) if dt.tzinfo is None else dt.astimezone(LOCAL_TZ)


def get_db_connection():
    """Create a database connection."""
    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    return conn


@contextmanager
def get_db():
    """Context manager for database connections."""
    conn = get_db_connection()
    try:
        yield conn
    finally:
        conn.close()


def execute_query(query: str, params: tuple = ()):
    """Execute a query and return results."""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(query, params)
        return cursor.fetchall()


def execute_one(query: str, params: tuple = ()):
    """Execute a query and return single result."""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(query, params)
        return cursor.fetchone()


# --- Schema migration (idempotent; run at startup and by ingest.py) -------------------------------

DEFAULT_LOCATION_ID = "tsn"

# DB column -> Open-Meteo hourly variable (units: degC, %, mm, m, hPa, km/h, deg)
WEATHER_COLUMNS = {
    "temperature": "temperature_2m",
    "humidity": "relative_humidity_2m",
    "dew_point": "dew_point_2m",
    "apparent_temperature": "apparent_temperature",
    "precipitation_probability": "precipitation_probability",
    "precipitation": "precipitation",
    "rain": "rain",
    "weather_code": "weather_code",
    "visibility": "visibility",
    "cloud_cover": "cloud_cover",
    "surface_pressure": "surface_pressure",
    "pressure_msl": "pressure_msl",
    "wind_speed": "wind_speed_10m",
    "wind_direction": "wind_direction_10m",
    "wind_gusts": "wind_gusts_10m",
    "uv_index": "uv_index",   # added later: NULL for hours ingested before the column existed
}

# Open-Meteo Air Quality API hourly variables (same names in the DB). us_aqi: US AQI, pm: ug/m3.
AIR_QUALITY_COLUMNS = ["us_aqi", "pm2_5", "pm10"]

_WEATHER_COLS_SQL = ", ".join(f'"{c}" REAL' for c in WEATHER_COLUMNS)

SCHEMA_SQL = [
    """CREATE TABLE IF NOT EXISTS locations (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
        elevation REAL, kind TEXT, source TEXT)""",
    # Existing single point (Open-Meteo Historical Forecast export, Tan Son Nhat area).
    """INSERT OR IGNORE INTO locations (id, name, lat, lon, elevation, kind, source)
       VALUES ('tsn', 'Ho Chi Minh City (Tan Son Nhat)', 10.7909, 106.6313, 6, 'grid', 'open-meteo')""",
    f"""CREATE TABLE IF NOT EXISTS hourly_weather (
        "timestamp" TIMESTAMP, {_WEATHER_COLS_SQL}, location_id TEXT NOT NULL DEFAULT 'tsn')""",
    f"""CREATE TABLE IF NOT EXISTS nwp_forecast (
        location_id TEXT NOT NULL, issued_at TEXT NOT NULL, "timestamp" TEXT NOT NULL, {_WEATHER_COLS_SQL},
        PRIMARY KEY (location_id, issued_at, "timestamp"))""",
    """CREATE TABLE IF NOT EXISTS air_quality (
        location_id TEXT NOT NULL, "timestamp" TEXT NOT NULL, us_aqi REAL, pm2_5 REAL, pm10 REAL,
        PRIMARY KEY (location_id, "timestamp"))""",
    """CREATE TABLE IF NOT EXISTS ingest_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, finished_at TEXT, source TEXT,
        location_id TEXT, rows_inserted INTEGER DEFAULT 0, rows_updated INTEGER DEFAULT 0,
        status TEXT NOT NULL, message TEXT)""",
    # Open-Meteo grid cells. series_id = key of the weather tables (location_id column there): the cell_id,
    # or 'tsn' for the ward cell on the same grid point as the 10-year 'tsn' series (alias, ingested once).
    """CREATE TABLE IF NOT EXISTS cells (
        cell_id TEXT PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL, elevation REAL,
        series_id TEXT NOT NULL, location_ids TEXT NOT NULL DEFAULT '[]')""",
    # Per-series ingest state (latest run outcome + gap report), updated by every ingest run.
    """CREATE TABLE IF NOT EXISTS series_status (
        series_id TEXT PRIMARY KEY, last_attempt_at TEXT, last_ok_at TEXT, status TEXT, error TEXT,
        latest_timestamp TEXT, gaps INTEGER, missing_hours INTEGER)""",
    # User feedback (routers/feedback.py). Never mixed into hourly_weather; verified stays 0 (unverified
    # user report, not an observation). No IP address is stored.
    """CREATE TABLE IF NOT EXISTS feedback (
        id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, kind TEXT NOT NULL, message TEXT,
        location_id TEXT, cell_id TEXT, observed_raining INTEGER, temperature_feel TEXT, forecast_snapshot TEXT,
        app_version TEXT, platform TEXT, verified INTEGER NOT NULL DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_feedback_created ON feedback(created_at)",
    # Published forecasts, logged by every hourly ingest (routers/monitor.py): source 'ai' = AI forecast per
    # horizon (1/3/6 h); source 'map_alert' = the /weather/map alert rule on the NWP issue (horizon 3 = next 3 h).
    """CREATE TABLE IF NOT EXISTS ai_forecast_log (
        series_id TEXT NOT NULL, source TEXT NOT NULL, issued_at TEXT NOT NULL, horizon_h INTEGER NOT NULL,
        target_time TEXT NOT NULL, temperature REAL, rain_probability REAL, precipitation REAL, alert INTEGER,
        model_version TEXT, logged_at TEXT NOT NULL, PRIMARY KEY (series_id, source, issued_at, horizon_h))""",
    "CREATE INDEX IF NOT EXISTS idx_ai_forecast_log_issued ON ai_forecast_log(issued_at)",
    # Outbound API calls per day and service (OSRM; Open-Meteo is counted in ingest_log.api_calls).
    """CREATE TABLE IF NOT EXISTS api_call_log (
        day TEXT NOT NULL, service TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0,
        errors INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, service))""",
    # Optional accounts (routers/auth.py, routers/sync.py). Times are Unix epoch seconds (UTC). No IP / GPS.
    """CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL)""",
    # Only the sha256 of the bearer token is stored.
    """CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)",
    """CREATE TABLE IF NOT EXISTS user_data (
        user_id INTEGER PRIMARY KEY, version INTEGER NOT NULL, data TEXT NOT NULL, updated_at INTEGER NOT NULL)""",
    # Failed logins per (normalised) email, for the 5-per-15-minutes lockout.
    "CREATE TABLE IF NOT EXISTS login_attempts (email TEXT NOT NULL, attempted_at INTEGER NOT NULL)",
    "CREATE INDEX IF NOT EXISTS idx_login_attempts_email ON login_attempts(email, attempted_at)",
]

# Columns added after the first release: table -> {column: SQL type}
_ADDED_COLUMNS = {
    "locations": {"region": "TEXT", "cell_id": "TEXT", "osm_relation_id": "INTEGER"},
    "ingest_log": {"cells_ok": "INTEGER", "cells_failed": "INTEGER", "failed_cells": "TEXT",
                   "api_calls": "INTEGER", "duration_s": "REAL"},
}


def migrate(conn: sqlite3.Connection) -> None:
    """Create/upgrade tables. Safe to run repeatedly; existing rows are backfilled with location_id='tsn'."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(hourly_weather)")}
    if cols and "location_id" not in cols:
        # ADD COLUMN with a constant default backfills every existing row in place.
        conn.execute("ALTER TABLE hourly_weather ADD COLUMN location_id TEXT NOT NULL DEFAULT 'tsn'")
    for sql in SCHEMA_SQL:
        conn.execute(sql)
    for table in ("hourly_weather", "nwp_forecast"):   # weather columns added after the table was created
        have = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        for col in WEATHER_COLUMNS:
            if col not in have:
                conn.execute(f'ALTER TABLE {table} ADD COLUMN "{col}" REAL')
    for table, cols in _ADDED_COLUMNS.items():
        have = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        for col, typ in cols.items():
            if col not in have:
                conn.execute(f'ALTER TABLE {table} ADD COLUMN "{col}" {typ}')
    conn.execute("CREATE INDEX IF NOT EXISTS idx_timestamp ON hourly_weather(timestamp)")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS ux_hourly_location_ts ON hourly_weather(location_id, timestamp)")
    conn.commit()


def load_locations(conn: sqlite3.Connection, locations_dir: Path = None) -> int:
    """(Re)load locations + cells from locations.json / cells.json (idempotent: the tables are replaced in one
    transaction). Ward cells on the same grid point as the 'tsn' cell get series_id 'tsn'. Returns the number
    of locations loaded (0 = files missing, tables left as they are)."""
    d = Path(locations_dir or LOCATIONS_DIR)
    if not (d / "locations.json").exists() or not (d / "cells.json").exists():
        return 0
    locs = json.loads((d / "locations.json").read_text(encoding="utf-8"))
    cells = json.loads((d / "cells.json").read_text(encoding="utf-8"))
    tsn = next((c for c in cells if c["cell_id"] == DEFAULT_LOCATION_ID), None)

    def series_of(c):
        if tsn is not None and (c["lat"], c["lon"]) == (tsn["lat"], tsn["lon"]):
            return DEFAULT_LOCATION_ID
        return c["cell_id"]

    with conn:
        conn.execute("DELETE FROM locations")
        conn.executemany(
            "INSERT INTO locations (id, name, lat, lon, elevation, kind, source, region, cell_id, osm_relation_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [(x["id"], x["name"], x["lat"], x["lon"], x.get("elevation"), x.get("kind"),
              "open-meteo" if x["id"] == DEFAULT_LOCATION_ID else "osm", x.get("region"), x.get("cell_id"),
              x.get("osm_relation_id")) for x in locs])
        conn.execute("DELETE FROM cells")
        conn.executemany(
            "INSERT INTO cells (cell_id, lat, lon, elevation, series_id, location_ids) VALUES (?, ?, ?, ?, ?, ?)",
            [(c["cell_id"], c["lat"], c["lon"], c.get("elevation_mean_of_locations"), series_of(c),
              json.dumps(c.get("location_ids", []))) for c in cells])
    return len(locs)


def init_db() -> None:
    """Run the migration and load locations/cells on the configured DATABASE_PATH (no-op if the DB file does
    not exist)."""
    if not DATABASE_PATH.exists():
        return
    conn = sqlite3.connect(DATABASE_PATH)
    try:
        migrate(conn)
        load_locations(conn)
    finally:
        conn.close()
