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


# Hourly ingest and auth/sync writes share one file: the busy timeout makes a second writer wait
# instead of failing at once with "database is locked". WAL (set once in init_db; the mode is stored in
# the file) lets readers run alongside the writer. The forecast caches in routers/weather.py key on
# weather_data_revision(): a counter bumped by triggers on hourly_weather (their only DB input), so auth,
# sync, feedback and API-call writes no longer invalidate them.
BUSY_TIMEOUT_SECONDS = 30


def configure_connection(conn: sqlite3.Connection) -> sqlite3.Connection:
    """Apply the busy timeout (a per-connection setting)."""
    conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_SECONDS * 1000}")
    return conn


def database_revision(path=None) -> tuple:
    """File-stat stamp that changes when committed data changes, not when a connection merely reads.

    Main file (mtime, size) moves on rollback-journal commits and WAL checkpoints; a non-empty -wal moves on
    WAL commits. An empty -wal is (re)created by every reader, so its mtime is ignored.
    """
    db = Path(path or DATABASE_PATH)
    stamp = []
    for f in (db, Path(str(db) + "-wal")):
        try:
            st = f.stat()
        except FileNotFoundError:
            stamp += [0, 0]
            continue
        stamp += [st.st_size, st.st_mtime_ns if st.st_size or f == db else 0]
    return tuple(stamp)


WEATHER_REVISION_KEY = "hourly_weather"


def weather_data_revision(path=None) -> tuple:
    """O(1) stamp of hourly_weather: triggers (see SCHEMA_SQL) bump data_revision on every INSERT, UPDATE
    (incl. ON CONFLICT DO UPDATE of an old hour) and DELETE, from any writer. A DB without the counter
    (never migrated) falls back to the file-stat stamp, which is correct but changes on every write."""
    db = Path(path or DATABASE_PATH)
    row = None
    try:
        if not db.exists():   # connect() would create an empty file
            raise sqlite3.OperationalError("no database file")
        conn = configure_connection(sqlite3.connect(db, timeout=BUSY_TIMEOUT_SECONDS))
        try:
            row = conn.execute("SELECT value FROM data_revision WHERE name = ?",
                               (WEATHER_REVISION_KEY,)).fetchone()
        finally:
            conn.close()
    except sqlite3.Error:
        pass
    return ("rows", row[0]) if row else ("file", *database_revision(db))


def get_db_connection():
    """Create a database connection."""
    conn = sqlite3.connect(DATABASE_PATH, timeout=BUSY_TIMEOUT_SECONDS)
    conn.row_factory = sqlite3.Row
    configure_connection(conn)
    conn.execute("PRAGMA foreign_keys = ON")
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

_ACCOUNT_TABLES = {
    "sessions": "token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
                "created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL",
    "user_data": "user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, "
                 "version INTEGER NOT NULL, data TEXT NOT NULL, updated_at INTEGER NOT NULL",
}

SCHEMA_SQL = [
    """CREATE TABLE IF NOT EXISTS locations (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
        elevation REAL, kind TEXT, source TEXT)""",
    # Existing single point (Open-Meteo Historical Forecast export, Tan Son Nhat area).
    """INSERT OR IGNORE INTO locations (id, name, lat, lon, elevation, kind, source)
       VALUES ('tsn', 'Ho Chi Minh City (Tan Son Nhat)', 10.7909, 106.6313, 6, 'grid', 'open-meteo')""",
    f"""CREATE TABLE IF NOT EXISTS hourly_weather (
        "timestamp" TIMESTAMP, {_WEATHER_COLS_SQL}, location_id TEXT NOT NULL DEFAULT 'tsn')""",
    # Change counter for the forecast caches (weather_data_revision). Triggers cover every writer.
    "CREATE TABLE IF NOT EXISTS data_revision (name TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0)",
    f"INSERT OR IGNORE INTO data_revision (name, value) VALUES ('{WEATHER_REVISION_KEY}', 0)",
    *(f"""CREATE TRIGGER IF NOT EXISTS trg_hourly_weather_rev_{op.lower()} AFTER {op} ON hourly_weather
        BEGIN UPDATE data_revision SET value = value + 1 WHERE name = '{WEATHER_REVISION_KEY}'; END"""
      for op in ("INSERT", "UPDATE", "DELETE")),
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
        model_version TEXT, logged_at TEXT NOT NULL, rain_threshold REAL,
        PRIMARY KEY (series_id, source, issued_at, horizon_h))""",
    "CREATE INDEX IF NOT EXISTS idx_ai_forecast_log_issued ON ai_forecast_log(issued_at)",
    # Outbound API calls per day and service (OSRM; Open-Meteo is counted in ingest_log.api_calls).
    """CREATE TABLE IF NOT EXISTS api_call_log (
        day TEXT NOT NULL, service TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0,
        errors INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, service))""",
    # Optional accounts (routers/auth.py, routers/sync.py). Times are Unix seconds (UTC). No raw IP / GPS.
    """CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL)""",
    # Only the sha256 of the bearer token is stored.
    f"CREATE TABLE IF NOT EXISTS sessions ({_ACCOUNT_TABLES['sessions']})",
    "CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)",
    f"CREATE TABLE IF NOT EXISTS user_data ({_ACCOUNT_TABLES['user_data']})",
    # Failed logins keyed by email and by hashed email/source markers (never raw IP addresses).
    "CREATE TABLE IF NOT EXISTS login_attempts (email TEXT NOT NULL, attempted_at INTEGER NOT NULL)",
    "CREATE INDEX IF NOT EXISTS idx_login_attempts_email ON login_attempts(email, attempted_at)",
    # Registration throttle keyed by hashed IP address.
    "CREATE TABLE IF NOT EXISTS registration_attempts (ip_hash TEXT NOT NULL, attempted_at INTEGER NOT NULL)",
    "CREATE INDEX IF NOT EXISTS idx_registration_attempts_ip ON registration_attempts(ip_hash, attempted_at)",
    # Recovery secrets are high-entropy token hashes only; deleted with their account.
    """CREATE TABLE IF NOT EXISTS password_resets (
        user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        token_hash TEXT NOT NULL UNIQUE, expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_password_resets_expiry ON password_resets(expires_at)",
    """CREATE TABLE IF NOT EXISTS password_reset_attempts (
        key_hash TEXT NOT NULL, attempted_at INTEGER NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS idx_password_reset_attempts ON password_reset_attempts(key_hash, attempted_at)",
]

# Columns added after the first release: table -> {column: SQL type}
_ADDED_COLUMNS = {
    "ai_forecast_log": {"rain_threshold": "REAL"},
    "locations": {"region": "TEXT", "cell_id": "TEXT", "osm_relation_id": "INTEGER"},
    "ingest_log": {"cells_ok": "INTEGER", "cells_failed": "INTEGER", "failed_cells": "TEXT",
                   "api_calls": "INTEGER", "duration_s": "REAL"},
}


def _migrate_account_foreign_keys(conn: sqlite3.Connection) -> None:
    # SQLite cannot add a foreign key in place. Keep both rebuilds atomic, including on legacy orphans.
    conn.execute("SAVEPOINT account_foreign_keys")
    try:
        for table, columns in _ACCOUNT_TABLES.items():
            if any(r[2] == "users" and r[3] == "user_id" and r[4] == "id" and r[6] == "CASCADE"
                   for r in conn.execute(f"PRAGMA foreign_key_list({table})")):
                continue
            objects = conn.execute("SELECT sql FROM sqlite_master WHERE tbl_name = ? "
                                   "AND type IN ('index', 'trigger') AND sql IS NOT NULL", (table,)).fetchall()
            replacement = f"{table}_with_foreign_key"
            conn.execute(f"CREATE TABLE {replacement} ({columns})")
            old_columns = [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]
            new_columns = [r[1] for r in conn.execute(f"PRAGMA table_info({replacement})")]
            if set(old_columns) != set(new_columns):
                raise sqlite3.IntegrityError(f"Unexpected columns in {table}; migration left data unchanged")
            names = ", ".join(f'"{name}"' for name in new_columns)
            conn.execute(f"INSERT INTO {replacement} ({names}) SELECT {names} FROM {table}")
            if conn.execute(f"PRAGMA foreign_key_check({replacement})").fetchone():
                raise sqlite3.IntegrityError(f"Orphan rows in {table}; migration left data unchanged")
            conn.execute(f"DROP TABLE {table}")
            conn.execute(f"ALTER TABLE {replacement} RENAME TO {table}")
            for (sql,) in objects:
                conn.execute(sql)
    except Exception:
        conn.execute("ROLLBACK TO account_foreign_keys")
        raise
    finally:
        conn.execute("RELEASE account_foreign_keys")


def migrate(conn: sqlite3.Connection) -> None:
    """Create/upgrade tables. Safe to run repeatedly; existing rows are backfilled with location_id='tsn'."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(hourly_weather)")}
    if cols and "location_id" not in cols:
        # ADD COLUMN with a constant default backfills every existing row in place.
        conn.execute("ALTER TABLE hourly_weather ADD COLUMN location_id TEXT NOT NULL DEFAULT 'tsn'")
    for sql in SCHEMA_SQL:
        conn.execute(sql)
    _migrate_account_foreign_keys(conn)
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
    conn.execute("PRAGMA foreign_keys = ON")


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
    """Create/upgrade the configured database and seed locations, but never invent weather rows."""
    DATABASE_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = configure_connection(sqlite3.connect(DATABASE_PATH, timeout=BUSY_TIMEOUT_SECONDS))
    try:
        conn.execute("PRAGMA journal_mode=WAL")   # persistent: later connections inherit it
        migrate(conn)
        load_locations(conn)
    finally:
        conn.close()
