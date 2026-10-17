"""
Backfill hourly history for every Open-Meteo grid cell of new HCMC into a SEPARATE SQLite file
(backend/data/history/cells_history.db). Resumable and idempotent.

Source: Open-Meteo Historical Forecast API (same endpoint/params as ingest.py and the v2 TSN series):
  https://historical-forecast-api.open-meteo.com/v1/forecast, timezone=Asia/Ho_Chi_Minh,
  each cell's own grid lat/lon and elevation (cells.json `elevation_mean_of_locations`).

Quota: Open-Meteo's free tier counts fractional calls,
  weight = n_locations * max(1, n_vars/10) * max(1, n_days/14)
(the API returns no usage headers, so the weight is computed from this documented rule and kept in
the `request_log` table). The script stays under conservative rolling budgets (default
500/min, 4500/h, 9000/24h), sleeps when a budget is used up and backs off on HTTP 429.

Only the 12 variables used by ai_model.build_features are downloaded (weight 1.2 instead of 1.5
for all 15 serving columns); rain/visibility/precipitation_probability/uv_index are not used as features.

The `tsn` cell is an alias of om-10.7909-106.6313: that cell's series is copied read-only from
weather.db (location_id='tsn', elevation 6 m) instead of downloaded. For the sanity check the
script additionally downloads 2025 for the alias cell (table hourly_check, variants
'own_elev' = 10.6 m and 'tsn_6m' = 6 m) to compare with weather.db.

Priority: (a) 2023-01-01 -> yesterday for all cells, (b) then whole years backwards to 2017.

Usage:
  python scripts/backfill_history.py                 # run until done (sleeps on budget)
  python scripts/backfill_history.py --max-hours 3   # stop after 3 h wall clock
  python scripts/backfill_history.py --status        # print coverage + API usage
"""
from __future__ import annotations

import argparse
import json
import logging
import sqlite3
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import httpx

BACKEND = Path(__file__).resolve().parent.parent
CELLS_JSON = BACKEND / "data" / "locations" / "cells.json"
WEATHER_DB = BACKEND / "data" / "weather.db"
HIST_DIR = BACKEND / "data" / "history"
HIST_DB = HIST_DIR / "cells_history.db"
LOG_FILE = HIST_DIR / "backfill.log"

URL = "https://historical-forecast-api.open-meteo.com/v1/forecast"
TIMEZONE = "Asia/Ho_Chi_Minh"
TS_FMT = "%Y-%m-%d %H:%M:%S"
# DB column -> API variable (subset of database.WEATHER_COLUMNS used by build_features)
VARS = {
    "temperature": "temperature_2m",
    "humidity": "relative_humidity_2m",
    "dew_point": "dew_point_2m",
    "apparent_temperature": "apparent_temperature",
    "precipitation": "precipitation",
    "weather_code": "weather_code",
    "cloud_cover": "cloud_cover",
    "surface_pressure": "surface_pressure",
    "pressure_msl": "pressure_msl",
    "wind_speed": "wind_speed_10m",
    "wind_direction": "wind_direction_10m",
    "wind_gusts": "wind_gusts_10m",
}
COLS = list(VARS)
ALIAS_OF_TSN = "om-10.7909-106.6313"
TSN_ELEVATION = 6.0
FIRST_YEAR = 2017
PRIORITY_START_YEAR = 2023
BATCH_CELLS = 10           # coordinates per request
HTTP_TIMEOUT = 120.0
BUDGET = {"minute": (60, 500.0), "hour": (3600, 4500.0), "day": (86400, 9000.0)}

log = logging.getLogger("backfill")

SCHEMA = [
    f"""CREATE TABLE IF NOT EXISTS hourly (
        cell_id TEXT NOT NULL, timestamp TEXT NOT NULL,
        {', '.join(f'"{c}" REAL' for c in COLS)},
        PRIMARY KEY (cell_id, timestamp))""",
    f"""CREATE TABLE IF NOT EXISTS hourly_check (
        variant TEXT NOT NULL, cell_id TEXT NOT NULL, timestamp TEXT NOT NULL,
        {', '.join(f'"{c}" REAL' for c in COLS)},
        PRIMARY KEY (variant, cell_id, timestamp))""",
    """CREATE TABLE IF NOT EXISTS cells (
        cell_id TEXT PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL, elevation REAL NOT NULL,
        source TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS chunks (
        cell_id TEXT NOT NULL, year INTEGER NOT NULL, start_date TEXT NOT NULL, end_date TEXT NOT NULL,
        rows INTEGER NOT NULL, null_values INTEGER NOT NULL, source TEXT NOT NULL, fetched_at TEXT NOT NULL,
        PRIMARY KEY (cell_id, year))""",
    """CREATE TABLE IF NOT EXISTS request_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts_utc REAL NOT NULL, weight REAL NOT NULL,
        n_cells INTEGER, start_date TEXT, end_date TEXT, http_status INTEGER, seconds REAL, note TEXT)""",
]


def connect() -> sqlite3.Connection:
    HIST_DIR.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(HIST_DB, timeout=60)
    con.execute("PRAGMA journal_mode=WAL")
    for s in SCHEMA:
        con.execute(s)
    con.commit()
    return con


def load_cells() -> list[dict]:
    cells = json.loads(CELLS_JSON.read_text(encoding="utf-8"))
    out = []
    for c in cells:
        if c["cell_id"] == "tsn":
            continue
        out.append({"cell_id": c["cell_id"], "lat": c["lat"], "lon": c["lon"],
                    "elevation": float(c["elevation_mean_of_locations"])})
    return out


def weight(n_cells: int, start: date, end: date, n_vars: int = len(VARS)) -> float:
    days = (end - start).days + 1
    return n_cells * max(1.0, n_vars / 10) * max(1.0, days / 14)


# ------------------------------------------------------------------ budget
def used(con, seconds: int) -> float:
    r = con.execute("SELECT COALESCE(SUM(weight),0) FROM request_log WHERE ts_utc > ?",
                    (time.time() - seconds,)).fetchone()
    return float(r[0])


def wait_for_budget(con, w: float, deadline: float) -> bool:
    """Sleep until a request of weight w fits every rolling budget. False if past deadline."""
    while True:
        waits = []
        for name, (sec, cap) in BUDGET.items():
            if w > cap:
                raise ValueError(f"request weight {w:.0f} exceeds the {name} cap {cap}")
            if used(con, sec) + w > cap:
                # earliest time enough weight ages out of this window
                rows = con.execute("SELECT ts_utc, weight FROM request_log WHERE ts_utc > ? ORDER BY ts_utc",
                                   (time.time() - sec,)).fetchall()
                need, acc, t_free = used(con, sec) + w - cap, 0.0, time.time() + sec
                for ts, wt in rows:
                    acc += wt
                    if acc >= need:
                        t_free = ts + sec + 1
                        break
                waits.append((t_free - time.time(), name))
        if not waits:
            return True
        delay, name = max(waits)
        if time.time() + delay > deadline:
            log.info("budget '%s' exhausted; next slot in %.0f min is past the deadline -> stop", name, delay / 60)
            return False
        log.info("budget '%s' full; sleeping %.1f min", name, delay / 60)
        time.sleep(min(max(delay, 1), 900))


def fetch(con, cells: list[dict], start: date, end: date, deadline: float, elevations=None):
    """One multi-coordinate request. Returns list of payloads (one per cell) or None if stopped."""
    w = weight(len(cells), start, end)
    params = {
        "latitude": ",".join(f"{c['lat']}" for c in cells),
        "longitude": ",".join(f"{c['lon']}" for c in cells),
        "elevation": ",".join(f"{e}" for e in (elevations or [c["elevation"] for c in cells])),
        "hourly": ",".join(VARS.values()), "timezone": TIMEZONE,
        "temperature_unit": "celsius", "wind_speed_unit": "kmh", "precipitation_unit": "mm",
        "start_date": start.isoformat(), "end_date": end.isoformat(),
    }
    backoff = 30
    for attempt in range(8):
        if not wait_for_budget(con, w, deadline):
            return None
        t0 = time.time()
        status, note = None, ""
        try:
            r = httpx.get(URL, params=params, timeout=HTTP_TIMEOUT)
            status = r.status_code
            if status == 200:
                data = r.json()
                data = data if isinstance(data, list) else [data]
                con.execute("INSERT INTO request_log (ts_utc, weight, n_cells, start_date, end_date, http_status,"
                            " seconds, note) VALUES (?,?,?,?,?,?,?,?)",
                            (t0, w, len(cells), start.isoformat(), end.isoformat(), status, time.time() - t0, ""))
                con.commit()
                return data
            note = r.text[:200]
        except (httpx.HTTPError, ValueError) as e:
            note = f"{type(e).__name__}: {e}"[:200]
        # failed attempts are logged (weight counted conservatively for 429/5xx)
        con.execute("INSERT INTO request_log (ts_utc, weight, n_cells, start_date, end_date, http_status,"
                    " seconds, note) VALUES (?,?,?,?,?,?,?,?)",
                    (t0, 1.0, len(cells), start.isoformat(), end.isoformat(), status, time.time() - t0, note))
        con.commit()
        log.warning("request failed (status=%s): %s", status, note)
        if status == 429:
            low = note.lower()
            sleep = 65 if "minut" in low else 3700 if "hour" in low else 6 * 3600 if "daily" in low else backoff
        elif status is not None and 400 <= status < 500:
            raise RuntimeError(f"HTTP {status}: {note}")
        else:
            sleep = backoff
        if time.time() + sleep > deadline:
            return None
        log.info("backing off %.0f s", sleep)
        time.sleep(sleep)
        backoff = min(backoff * 2, 900)
    raise RuntimeError("too many failed attempts")


def parse(payload: dict) -> list[tuple]:
    h = payload["hourly"]
    times = h["time"]
    rows = []
    for i, t in enumerate(times):
        vals = [h[v][i] for v in VARS.values()]
        if all(v is None for v in vals):
            continue
        rows.append((datetime.fromisoformat(t).strftime(TS_FMT), *[None if v is None else float(v) for v in vals]))
    return rows


def store(con, table: str, key: tuple, rows: list[tuple]) -> None:
    ph = ",".join("?" * (len(key) + 1 + len(COLS)))
    keycols = "cell_id" if table == "hourly" else "variant, cell_id"
    con.executemany(f"INSERT OR REPLACE INTO {table} ({keycols}, timestamp, {', '.join(COLS)}) VALUES ({ph})",
                    [(*key, *r) for r in rows])


# ------------------------------------------------------------------ steps
def import_tsn(con, yesterday: date) -> None:
    """Copy weather.db tsn series (read-only) as the alias cell's history."""
    src = sqlite3.connect(f"file:{WEATHER_DB.as_posix()}?mode=ro", uri=True)
    q = (f"SELECT timestamp, {', '.join(COLS)} FROM hourly_weather WHERE location_id='tsn' "
         "AND timestamp <= ? ORDER BY timestamp")
    rows = src.execute(q, (f"{yesterday.isoformat()} 23:00:00",)).fetchall()
    src.close()
    store(con, "hourly", (ALIAS_OF_TSN,), rows)
    by_year: dict[int, list] = {}
    for r in rows:
        by_year.setdefault(int(r[0][:4]), []).append(r)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    for y, rs in by_year.items():
        nulls = sum(v is None for r in rs for v in r[1:])
        con.execute("INSERT OR REPLACE INTO chunks VALUES (?,?,?,?,?,?,?,?)",
                    (ALIAS_OF_TSN, y, rs[0][0][:10], rs[-1][0][:10], len(rs), nulls, "weather.db:tsn (6 m)", now))
    con.commit()
    log.info("imported %d tsn rows from weather.db as %s (%s .. %s)", len(rows), ALIAS_OF_TSN, rows[0][0], rows[-1][0])


def plan(con, cells: list[dict], yesterday: date) -> list[tuple[int, date, date, list[dict]]]:
    """Work items (year, start, end, cells) still missing, in priority order."""
    done = {(c, y): e for c, y, e in con.execute("SELECT cell_id, year, end_date FROM chunks")}
    years = list(range(PRIORITY_START_YEAR, yesterday.year + 1)) + list(range(PRIORITY_START_YEAR - 1, FIRST_YEAR - 1, -1))
    items = []
    for y in years:
        y_end = min(date(y, 12, 31), yesterday)
        groups: dict[date, list] = {}
        for c in cells:
            if c["cell_id"] == ALIAS_OF_TSN:
                continue
            e = done.get((c["cell_id"], y))
            if e is not None and date.fromisoformat(e) >= y_end:
                continue
            start = date(y, 1, 1) if e is None else date.fromisoformat(e) - timedelta(days=1)
            groups.setdefault(start, []).append(c)
        for start, cs in groups.items():
            for i in range(0, len(cs), BATCH_CELLS):
                items.append((y, start, y_end, cs[i:i + BATCH_CELLS]))
    return items


def run_check(con, cells: list[dict], deadline: float) -> None:
    """2025 at the alias cell: own elevation and tsn's 6 m (for the weather.db comparison)."""
    have = {v for (v,) in con.execute("SELECT DISTINCT variant FROM hourly_check")}
    alias = next(c for c in cells if c["cell_id"] == ALIAS_OF_TSN)
    for variant, elev in (("own_elev", alias["elevation"]), ("tsn_6m", TSN_ELEVATION)):
        if variant in have:
            continue
        data = fetch(con, [alias], date(2025, 1, 1), date(2025, 12, 31), deadline, elevations=[elev])
        if data is None:
            return
        store(con, "hourly_check", (variant, ALIAS_OF_TSN), parse(data[0]))
        con.commit()
        log.info("check variant %s (elevation %.1f m) stored", variant, elev)


def status(con) -> None:
    print("coverage (rows per cell x year):")
    df = con.execute("SELECT year, COUNT(*), SUM(rows), MIN(start_date), MAX(end_date), SUM(null_values) "
                     "FROM chunks GROUP BY year ORDER BY year").fetchall()
    for r in df:
        print(f"  {r[0]}: cells={r[1]:3d} rows={r[2]:8d} {r[3]}..{r[4]} nulls={r[5]}")
    for name, (sec, cap) in BUDGET.items():
        print(f"  used last {name}: {used(con, sec):.0f} / {cap:.0f}")
    tot = con.execute("SELECT COUNT(*), COALESCE(SUM(weight),0), SUM(http_status=200), SUM(http_status=429) "
                      "FROM request_log").fetchone()
    print(f"  requests total={tot[0]} weight={tot[1]:.0f} ok={tot[2]} http429={tot[3]}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-hours", type=float, default=24.0)
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--max-items", type=int, default=0, help="stop after N requests (0 = no limit)")
    a = ap.parse_args(argv)
    HIST_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler(sys.stdout)])
    logging.getLogger("httpx").setLevel(logging.WARNING)
    con = connect()
    if a.status:
        status(con)
        return 0
    deadline = time.time() + a.max_hours * 3600
    yesterday = date.today() - timedelta(days=1)
    cells = load_cells()
    con.executemany("INSERT OR REPLACE INTO cells VALUES (?,?,?,?,?)",
                    [(c["cell_id"], c["lat"], c["lon"],
                      TSN_ELEVATION if c["cell_id"] == ALIAS_OF_TSN else c["elevation"],
                      "weather.db:tsn" if c["cell_id"] == ALIAS_OF_TSN else "historical-forecast-api")
                     for c in cells])
    con.commit()
    import_tsn(con, yesterday)
    run_check(con, cells, deadline)
    items = plan(con, cells, yesterday)
    total_w = sum(weight(len(cs), s, e) for _, s, e, cs in items)
    log.info("start: %d cells, %d requests pending, estimated weight %.0f (end %s)",
             len(cells), len(items), total_w, yesterday)
    n = 0
    for y, start, end, cs in items:
        data = fetch(con, cs, start, end, deadline)
        if data is None:
            log.info("stopped (deadline/budget); resume by re-running")
            break
        if len(data) != len(cs):
            raise RuntimeError(f"expected {len(cs)} payloads, got {len(data)}")
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        for c, p in zip(cs, data):
            if abs(p["latitude"] - c["lat"]) > 0.02 or abs(p["longitude"] - c["lon"]) > 0.02:
                log.warning("%s: API grid point %.4f,%.4f differs from cell", c["cell_id"], p["latitude"], p["longitude"])
            rows = parse(p)
            store(con, "hourly", (c["cell_id"],), rows)
            nulls = sum(v is None for r in rows for v in r[1:])
            first = con.execute("SELECT MIN(timestamp) FROM hourly WHERE cell_id=? AND timestamp>=?",
                                (c["cell_id"], f"{y}-01-01")).fetchone()[0]
            con.execute("INSERT OR REPLACE INTO chunks VALUES (?,?,?,?,?,?,?,?)",
                        (c["cell_id"], y, (first or start.isoformat())[:10], end.isoformat(),
                         con.execute("SELECT COUNT(*) FROM hourly WHERE cell_id=? AND timestamp BETWEEN ? AND ?",
                                     (c["cell_id"], f"{y}-01-01", f"{y}-12-31 23:59:59")).fetchone()[0],
                         nulls, "historical-forecast-api", now))
        con.commit()
        n += 1
        log.info("year %d %s..%s: %d cells stored (%d/%d requests)", y, start, end, len(cs), n, len(items))
        if a.max_items and n >= a.max_items:
            break
    status(con)
    return 0


if __name__ == "__main__":
    sys.exit(main())
