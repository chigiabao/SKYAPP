"""
Data ingestion from Open-Meteo into the team's own SQLite DB.

Covers every weather series: one per Open-Meteo grid cell of new HCMC (cells table, loaded from
data/locations/cells.json) plus 'tsn' (the ward cell on the same grid point is an alias of 'tsn', not a second
series). Coordinates are batched (comma-separated lists, <= CHUNK_SIZE per request; Open-Meteo answers with a
list in the same order), throttled for the free tier (CHUNK_SLEEP between requests, at most MINUTE_BUDGET
weighted calls per rolling minute) and retried with backoff.

- Observed/analysis hours -> hourly_weather (Historical Forecast API, same source as the original export).
                              A series without data is backfilled BACKFILL_DAYS days.
- 7-day forecast (opt-in)  -> nwp_forecast, one issue per run (Forecast API); only the latest KEEP_ISSUES kept.
                              Disabled unless EXTERNAL_FORECAST_ENABLED=1; forecasts come from our trained model.
- Air quality (optional)   -> air_quality, past AQ_PAST_DAYS + AQ_FORECAST_DAYS upserted (Air Quality API);
                              if only this call fails the weather data is still written and a WARNING is logged.
Every valid run writes one ingest_log row. Observed data is written even if an optional forecast fetch fails.
Failed historical (or forecast-only) series are listed in ingest_log.failed_cells and series_status, and caught
up by the next run (each series' observed window starts from its own last stored hour). All writes happen in one
transaction after the network work.

CLI:  python ingest.py [--location <location/cell/series id; default: all>] [--since YYYY-MM-DD] [--forecast-only]
      python ingest.py --check [--check-start 2026-10-01 --check-end 2026-10-10]
"""
import argparse
import json
import logging
import os
import sqlite3
import sys
import threading
import time
from collections import deque
from datetime import date, datetime, timedelta
from typing import Callable, Optional

import httpx

import database
from database import LOCAL_TZ, WEATHER_COLUMNS, AIR_QUALITY_COLUMNS, DEFAULT_LOCATION_ID, migrate, now_local

HISTORICAL_URL = "https://historical-forecast-api.open-meteo.com/v1/forecast"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
AIR_QUALITY_URL = "https://air-quality-api.open-meteo.com/v1/air-quality"
AQ_PAST_DAYS = 7
AQ_FORECAST_DAYS = 7
TIMEZONE = "Asia/Ho_Chi_Minh"
OVERLAP_HOURS = 48          # re-fetch this many hours before the last stored hour (revisions / small gaps)
BACKFILL_DAYS = 90          # series without data: start this many days back
FORECAST_HOURS = 168
KEEP_ISSUES = 5
HTTP_TIMEOUT = 60.0
RETRIES = 3
BACKOFF_SECONDS = 2.0       # 2 s, 4 s, 8 s
CHUNK_SIZE = 20             # coordinates per request
CHUNK_SLEEP = 1.0           # seconds between two requests of a run
MINUTE_BUDGET = 400.0       # weighted calls per rolling minute (free tier: 600/min, 5000/h, 10000/day)
MAX_GAPS_IN_MESSAGE = 5
TS_FMT = "%Y-%m-%d %H:%M:%S"
COLS = list(WEATHER_COLUMNS)

_lock = threading.Lock()
log = logging.getLogger("ingest")


class IngestBusy(RuntimeError):
    """Another ingest run is in progress in this process."""


# --- HTTP ---------------------------------------------------------------------------------------

def _get_json(url: str, params: dict):
    """GET with timeout and RETRIES retries (exponential backoff). Raises the last error."""
    last: Exception = RuntimeError("no attempt")
    for attempt in range(RETRIES + 1):
        try:
            r = httpx.get(url, params=params, timeout=HTTP_TIMEOUT)
            r.raise_for_status()
            return r.json()
        except (httpx.HTTPError, ValueError) as e:
            last = e
            if attempt < RETRIES:
                time.sleep(BACKOFF_SECONDS * 2 ** attempt)
    raise RuntimeError(f"GET {url} failed after {RETRIES + 1} attempts: {last}")


def _join(values: list):
    """One coordinate -> scalar (a plain single-location request); several -> comma-separated list."""
    return values[0] if len(values) == 1 else ",".join(str(v) for v in values)


def _coords(locs: list[dict], elevation: bool = True) -> dict:
    p = {"latitude": _join([x["lat"] for x in locs]), "longitude": _join([x["lon"] for x in locs])}
    elev = [x.get("elevation") for x in locs]
    if elevation and all(e is not None for e in elev):
        p["elevation"] = _join(elev)   # matches the original export (6 m); affects surface_pressure
    return p


def _params(locs: list[dict], **extra) -> dict:
    p = {**_coords(locs), "hourly": ",".join(WEATHER_COLUMNS.values()),
         "timezone": TIMEZONE, "temperature_unit": "celsius", "wind_speed_unit": "kmh",
         "precipitation_unit": "mm"}
    p.update(extra)
    return p


_recent: deque = deque()   # (monotonic time, weight) of the requests of the last minute


def _throttle(weight: float, stats: dict) -> None:
    """Sleep CHUNK_SLEEP between requests and keep the weighted calls of any rolling minute <= MINUTE_BUDGET."""
    if stats.get("requests") and CHUNK_SLEEP > 0:
        time.sleep(CHUNK_SLEEP)
    if not MINUTE_BUDGET:
        return
    while True:
        now = time.monotonic()
        while _recent and now - _recent[0][0] > 60:
            _recent.popleft()
        if not _recent or sum(w for _, w in _recent) + weight <= MINUTE_BUDGET:
            break
        wait = 60.5 - (now - _recent[0][0])
        log.info("throttle: waiting %.0f s (minute budget %.0f)", wait, MINUTE_BUDGET)
        time.sleep(wait)
    _recent.append((time.monotonic(), weight))


def _weight(n_vars: int, days: float) -> float:
    """Open-Meteo counts a location with > 10 variables or > 14 days as several (fractional) calls."""
    return max(1.0, n_vars / 10) * max(1.0, days / 14)


def _batch(url: str, params: dict, n: int, weight_per_loc: float, stats: Optional[dict]) -> list:
    """One throttled, retried multi-coordinate request -> one payload per coordinate, in request order."""
    stats = stats if stats is not None else {}
    weight = n * weight_per_loc
    _throttle(weight, stats)
    stats["requests"] = stats.get("requests", 0) + 1
    stats["weighted"] = stats.get("weighted", 0.0) + weight
    payload = _get_json(url, params)
    out = payload if isinstance(payload, list) else [payload]
    if len(out) != n:
        raise ValueError(f"expected {n} locations in the response, got {len(out)}")
    return out


def parse_hourly(payload: dict, columns: Optional[dict] = None) -> list[dict]:
    """Open-Meteo hourly block -> rows keyed by DB column; timestamp 'YYYY-MM-DD HH:MM:SS' local.
    `columns` maps DB column -> API variable (default WEATHER_COLUMNS).
    Hours where every variable is null (not yet available) are dropped."""
    columns = columns or WEATHER_COLUMNS
    h = payload.get("hourly") or {}
    times = h.get("time") or []
    rows = []
    for i, t in enumerate(times):
        row = {"timestamp": datetime.fromisoformat(t).strftime(TS_FMT)}
        for col, var in columns.items():
            v = (h.get(var) or [None] * len(times))[i]
            row[col] = None if v is None else float(v)
        if any(row[c] is not None for c in columns):
            rows.append(row)
    return rows


def fetch_historical_batch(locs: list[dict], start: date, end: date,
                           stats: Optional[dict] = None) -> list[list[dict]]:
    days = (end - start).days + 1
    payloads = _batch(HISTORICAL_URL, _params(locs, start_date=start.isoformat(), end_date=end.isoformat()),
                      len(locs), _weight(len(WEATHER_COLUMNS), days), stats)
    return [parse_hourly(p) for p in payloads]


def fetch_forecast_batch(locs: list[dict], stats: Optional[dict] = None) -> list[list[dict]]:
    payloads = _batch(FORECAST_URL, _params(locs, forecast_days=8), len(locs),
                      _weight(len(WEATHER_COLUMNS), 8), stats)
    return [parse_hourly(p) for p in payloads]


def fetch_air_quality_batch(locs: list[dict], stats: Optional[dict] = None) -> list[list[dict]]:
    params = {**_coords(locs, elevation=False), "hourly": ",".join(AIR_QUALITY_COLUMNS),
              "timezone": TIMEZONE, "past_days": AQ_PAST_DAYS, "forecast_days": AQ_FORECAST_DAYS}
    payloads = _batch(AIR_QUALITY_URL, params, len(locs),
                      _weight(len(AIR_QUALITY_COLUMNS), AQ_PAST_DAYS + AQ_FORECAST_DAYS), stats)
    return [parse_hourly(p, {c: c for c in AIR_QUALITY_COLUMNS}) for p in payloads]


def fetch_historical(loc: dict, start: date, end: date) -> list[dict]:
    return fetch_historical_batch([loc], start, end)[0]


# --- DB helpers ---------------------------------------------------------------------------------

def connect(db_path=None) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path or database.DATABASE_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    migrate(conn)
    return conn


def get_location(conn, location_id: str) -> dict:
    row = conn.execute("SELECT * FROM locations WHERE id = ?", (location_id,)).fetchone()
    if row is None:
        raise ValueError(f"unknown location_id {location_id!r}")
    return dict(row)


def list_series(conn, location_id: Optional[str] = None) -> list[dict]:
    """Weather series to ingest: {series_id, lat, lon, elevation}. 'tsn' keeps its fixed training point (6 m),
    the others use their grid cell. `location_id` (a location, cell or series id) narrows it to one series."""
    def tsn():
        loc = get_location(conn, DEFAULT_LOCATION_ID)
        return {"series_id": DEFAULT_LOCATION_ID, "lat": loc["lat"], "lon": loc["lon"],
                "elevation": loc["elevation"]}

    def from_cell(sid):
        if sid == DEFAULT_LOCATION_ID:
            return tsn()
        c = conn.execute("SELECT * FROM cells WHERE cell_id = ?", (sid,)).fetchone()
        return {"series_id": sid, "lat": c["lat"], "lon": c["lon"], "elevation": c["elevation"]}

    if location_id is not None:
        if location_id == DEFAULT_LOCATION_ID:
            return [tsn()]
        row = conn.execute(
            "SELECT series_id FROM cells WHERE cell_id = ? OR series_id = ? "
            "UNION SELECT c.series_id FROM locations l JOIN cells c ON c.cell_id = l.cell_id WHERE l.id = ?",
            (location_id, location_id, location_id)).fetchone()
        if row is None:
            raise ValueError(f"unknown location_id {location_id!r}")
        return [from_cell(row[0])]
    sids = [r[0] for r in conn.execute("SELECT DISTINCT series_id FROM cells ORDER BY series_id")]
    return [tsn()] + [from_cell(s) for s in sids if s != DEFAULT_LOCATION_ID]


def _chunks(items: list, size: Optional[int] = None) -> list[list]:
    size = size or CHUNK_SIZE
    return [items[i:i + size] for i in range(0, len(items), size)]


def current_hour(now: Optional[datetime] = None) -> datetime:
    """Current HCMC hour as a naive local datetime (DB convention)."""
    now = now or now_local()
    if now.tzinfo is not None:
        now = now.astimezone(LOCAL_TZ)
    return now.replace(minute=0, second=0, microsecond=0, tzinfo=None)


def _same(a, b) -> bool:
    if a is None or b is None:
        return a is None and b is None
    return abs(float(a) - float(b)) < 1e-9


def upsert_hourly(conn, location_id: str, rows: list[dict]) -> tuple[int, int]:
    """Insert new hours, update changed ones, leave identical ones alone. Returns (inserted, updated).
    Does not commit."""
    if not rows:
        return 0, 0
    lo, hi = min(r["timestamp"] for r in rows), max(r["timestamp"] for r in rows)
    existing = {r["timestamp"]: r for r in conn.execute(
        f"SELECT timestamp, {', '.join(COLS)} FROM hourly_weather "
        "WHERE location_id = ? AND timestamp BETWEEN ? AND ?", (location_id, lo, hi))}
    new, changed = [], []
    for r in rows:
        old = existing.get(r["timestamp"])
        if old is None:
            new.append(r)
        elif not all(_same(old[c], r[c]) for c in COLS):
            changed.append(r)
    sql = (f"INSERT INTO hourly_weather (location_id, timestamp, {', '.join(COLS)}) "
           f"VALUES (?, ?, {', '.join('?' * len(COLS))}) "
           f"ON CONFLICT(location_id, timestamp) DO UPDATE SET "
           + ", ".join(f"{c} = excluded.{c}" for c in COLS))
    conn.executemany(sql, [(location_id, r["timestamp"], *(r[c] for c in COLS)) for r in new + changed])
    return len(new), len(changed)


def store_forecast(conn, location_id: str, issued_at: str, rows: list[dict], keep: int = KEEP_ISSUES) -> int:
    """Replace the issue `issued_at` with `rows` and prune to the latest `keep` issues. Does not commit."""
    conn.execute("DELETE FROM nwp_forecast WHERE location_id = ? AND issued_at = ?", (location_id, issued_at))
    conn.executemany(
        f"INSERT INTO nwp_forecast (location_id, issued_at, timestamp, {', '.join(COLS)}) "
        f"VALUES (?, ?, ?, {', '.join('?' * len(COLS))})",
        [(location_id, issued_at, r["timestamp"], *(r[c] for c in COLS)) for r in rows])
    conn.execute(
        "DELETE FROM nwp_forecast WHERE location_id = ? AND issued_at NOT IN ("
        " SELECT DISTINCT issued_at FROM nwp_forecast WHERE location_id = ? ORDER BY issued_at DESC LIMIT ?)",
        (location_id, location_id, keep))
    return len(rows)


def upsert_air_quality(conn, location_id: str, rows: list[dict]) -> int:
    """Insert or overwrite air-quality hours. Does not commit."""
    aq = AIR_QUALITY_COLUMNS
    conn.executemany(
        f"INSERT INTO air_quality (location_id, timestamp, {', '.join(aq)}) VALUES (?, ?, {', '.join('?' * len(aq))}) "
        "ON CONFLICT(location_id, timestamp) DO UPDATE SET " + ", ".join(f"{c} = excluded.{c}" for c in aq),
        [(location_id, r["timestamp"], *(r[c] for c in aq)) for r in rows])
    return len(rows)


def find_gaps(conn, location_id: str) -> list[tuple[str, str, int]]:
    """Missing-hour runs in hourly_weather: (last present hour, next present hour, hours missing)."""
    rows = conn.execute(
        "SELECT prev, timestamp, CAST(ROUND((julianday(timestamp) - julianday(prev)) * 24) AS INTEGER) - 1 "
        "FROM (SELECT timestamp, LAG(timestamp) OVER (ORDER BY timestamp) AS prev "
        "      FROM hourly_weather WHERE location_id = ?) "
        "WHERE prev IS NOT NULL AND (julianday(timestamp) - julianday(prev)) * 24 > 1.5 ORDER BY timestamp",
        (location_id,)).fetchall()
    return [(r[0], r[1], r[2]) for r in rows]


def _gap_text(gaps) -> str:
    if not gaps:
        return "gaps: none"
    shown = "; ".join(f"{a} -> {b} ({n} h missing)" for a, b, n in gaps[-MAX_GAPS_IN_MESSAGE:])
    return f"gaps: {len(gaps)} ({sum(g[2] for g in gaps)} h missing), latest: {shown}"


def _log_row(conn, log_id: int) -> dict:
    return dict(conn.execute("SELECT * FROM ingest_log WHERE id = ?", (log_id,)).fetchone())


def get_log(limit: int = 20, db_path=None) -> list[dict]:
    conn = connect(db_path)
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM ingest_log ORDER BY id DESC LIMIT ?", (limit,))]
    finally:
        conn.close()


# --- Main entry point ---------------------------------------------------------------------------

def run_ingest(location_id: Optional[str] = None, since: Optional[date] = None,
               forecast_only: bool = False, now: Optional[datetime] = None, db_path=None,
               on_success: Optional[Callable[[], None]] = None) -> dict:
    """One ingest run over all series (or only the series of `location_id`); returns the ingest_log row.
    status: ok | partial (some series failed, the others were written) | error. Raises IngestBusy if a run
    is already in progress. External forecasts require EXTERNAL_FORECAST_ENABLED=1;
    forecast_only raises ValueError before network access when disabled."""
    if not _lock.acquire(blocking=False):
        raise IngestBusy("ingest already running")
    try:
        return _run(location_id, since, forecast_only, now, db_path, on_success)
    finally:
        _lock.release()


def _err(e: Exception) -> str:
    return f"{type(e).__name__}: {e}"


def _fetch_observed(conn, series, since, hour, stats, failed) -> dict:
    """Observed rows per series id (only hours in [series' window start, hour]); failed chunks -> `failed`."""
    hi = hour.strftime(TS_FMT)
    groups: dict[date, list[dict]] = {}   # one request covers one date range: group the series by start date
    for s in series:
        if since is not None:
            start = datetime.combine(since, datetime.min.time())
        else:
            last = conn.execute("SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ?",
                                (s["series_id"],)).fetchone()[0]
            start = (datetime.fromisoformat(last) - timedelta(hours=OVERLAP_HOURS) if last
                     else hour - timedelta(days=BACKFILL_DAYS))
        s["lo"] = start.strftime(TS_FMT)
        groups.setdefault(start.date(), []).append(s)
    obs = {}
    for day, members in sorted(groups.items()):
        for i, chunk in enumerate(_chunks(members), 1):
            try:
                fetched = fetch_historical_batch(chunk, day, hour.date(), stats)
            except Exception as e:  # noqa: BLE001 - keep the other chunks
                log.warning("historical from %s chunk %d: FAILED %d series: %s", day, i, len(chunk), e)
                failed.update({s["series_id"]: f"historical: {_err(e)}" for s in chunk})
                continue
            for s, rows in zip(chunk, fetched):   # never store future hours
                obs[s["series_id"]] = [r for r in rows if s["lo"] <= r["timestamp"] <= hi]
            log.info("historical from %s chunk %d: ok %d series", day, i, len(chunk))
    return obs


def _run(location_id, since, forecast_only, now, db_path, on_success) -> dict:
    external_forecast = os.getenv("EXTERNAL_FORECAST_ENABLED", "0") == "1"
    if forecast_only and not external_forecast:
        raise ValueError("forecast_only requires EXTERNAL_FORECAST_ENABLED=1; external forecasts are disabled")
    t0 = time.monotonic()
    hour = current_hour(now)
    source = "open-meteo:forecast" if forecast_only else "open-meteo:historical-forecast"
    if external_forecast and not forecast_only:
        source += "+forecast"
    conn = connect(db_path)
    try:
        cur = conn.execute(
            "INSERT INTO ingest_log (started_at, source, location_id, status) VALUES (?, ?, ?, 'running')",
            (now_local().strftime(TS_FMT), source, location_id or "*"))
        log_id = cur.lastrowid
        conn.commit()
        stats: dict = {"requests": 0, "weighted": 0.0}
        try:
            series = list_series(conn, location_id)
            notes = []
            failed: dict[str, str] = {}
            obs: dict[str, list[dict]] = {}
            if not forecast_only:
                obs = _fetch_observed(conn, series, since, hour, stats, failed)
                lo, hi = min(s["lo"] for s in series), hour.strftime(TS_FMT)
                n_obs = sum(len(v) for v in obs.values())
                if len(series) == 1:
                    notes.append(f"observed window {lo} .. {hi}: {n_obs} hours fetched")
                else:
                    notes.append(f"observed {lo} .. {hi}: {n_obs} hours fetched for {len(obs)} series")
            issued_at = hour.strftime(TS_FMT)
            horizon = (hour + timedelta(hours=FORECAST_HOURS)).strftime(TS_FMT)
            fc: dict[str, list[dict]] = {}
            forecast_series = [s for s in series if s["series_id"] not in failed] if external_forecast else []
            for i, chunk in enumerate(_chunks(forecast_series), 1):
                try:
                    fetched = fetch_forecast_batch(chunk, stats)
                except Exception as e:  # noqa: BLE001
                    log.warning("forecast chunk %d: FAILED %d series: %s", i, len(chunk), e)
                    if forecast_only:
                        failed.update({s["series_id"]: f"forecast: {_err(e)}" for s in chunk})
                    else:
                        notes.append(f"WARNING external forecast skipped for {len(chunk)} series: {_err(e)}")
                    continue
                for s, rows in zip(chunk, fetched):
                    fc[s["series_id"]] = [r for r in rows if issued_at < r["timestamp"] <= horizon]
                log.info("forecast chunk %d: ok %d series", i, len(chunk))
            ok = [s for s in series if s["series_id"] not in failed]
            aq: dict[str, list[dict]] = {}
            for i, chunk in enumerate(_chunks(ok), 1):
                try:   # optional: an air-quality outage must not block the weather data
                    for s, rows in zip(chunk, fetch_air_quality_batch(chunk, stats)):
                        aq[s["series_id"]] = rows
                    log.info("air quality chunk %d: ok %d series", i, len(chunk))
                except Exception as e:  # noqa: BLE001
                    log.warning("air quality chunk %d failed: %s", i, e)
                    notes.append(f"WARNING air quality skipped for {len(chunk)} series: {_err(e)}")

            # All network work is done; write every successful series in one transaction.
            ins = upd = n_fc = n_aq = 0
            with conn:
                for s in ok:
                    sid = s["series_id"]
                    a, b = upsert_hourly(conn, sid, obs.get(sid, []))
                    ins, upd = ins + a, upd + b
                    if sid in fc:
                        n_fc += store_forecast(conn, sid, issued_at, fc[sid])
                    if sid in aq:
                        n_aq += upsert_air_quality(conn, sid, aq[sid])
            if fc:
                notes.append(f"forecast issue {issued_at}: {n_fc} hours")
            elif not external_forecast:
                notes.append("external forecasts disabled; forecasts supplied by our trained model")
            if aq:
                notes.append(f"air quality: {n_aq} hours")
            if forecast_only:
                ins, upd = n_fc, 0
            notes.append(_update_series_status(conn, series, failed))
            if failed:
                shown = "; ".join(f"{k} ({v})" for k, v in list(failed.items())[:MAX_GAPS_IN_MESSAGE])
                notes.append(f"FAILED {len(failed)}/{len(series)} series (retried next run): {shown}")
            duration = round(time.monotonic() - t0, 1)
            notes.append(f"api: {stats['requests']} requests (~{stats['weighted']:.0f} weighted calls), "
                         f"{len(ok)}/{len(series)} series ok, {duration} s")
            status = "ok" if not failed else ("partial" if ok else "error")
            conn.execute(
                "UPDATE ingest_log SET finished_at = ?, rows_inserted = ?, rows_updated = ?, status = ?, "
                "message = ?, cells_ok = ?, cells_failed = ?, failed_cells = ?, api_calls = ?, duration_s = ? "
                "WHERE id = ?",
                (now_local().strftime(TS_FMT), ins, upd, status, " | ".join(notes), len(ok), len(failed),
                 json.dumps(sorted(failed)), stats["requests"], duration, log_id))
            conn.commit()
        except Exception as e:  # noqa: BLE001 - every failure is logged, data left untouched
            conn.rollback()
            conn.execute("UPDATE ingest_log SET finished_at = ?, status = 'error', message = ?, api_calls = ?, "
                         "duration_s = ? WHERE id = ?",
                         (now_local().strftime(TS_FMT), _err(e), stats["requests"],
                          round(time.monotonic() - t0, 1), log_id))
            conn.commit()
            return _log_row(conn, log_id)
        result = _log_row(conn, log_id)
    finally:
        conn.close()
    if result["status"] != "error":
        _post_ingest(db_path, now)
        _after_success(on_success)
    return result


def _update_series_status(conn, series: list[dict], failed: dict) -> str:
    """Per-series gap report + last outcome into series_status; returns the gap summary for the log message."""
    stamp = now_local().strftime(TS_FMT)
    parts, with_gaps = [], 0
    with conn:
        for s in series:
            sid = s["series_id"]
            gaps = find_gaps(conn, sid)
            latest = conn.execute("SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ?",
                                  (sid,)).fetchone()[0]
            err = failed.get(sid)
            conn.execute(
                "INSERT INTO series_status (series_id, last_attempt_at, last_ok_at, status, error, "
                "latest_timestamp, gaps, missing_hours) VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(series_id) DO UPDATE SET last_attempt_at = excluded.last_attempt_at, "
                "last_ok_at = COALESCE(excluded.last_ok_at, series_status.last_ok_at), status = excluded.status, "
                "error = excluded.error, latest_timestamp = excluded.latest_timestamp, gaps = excluded.gaps, "
                "missing_hours = excluded.missing_hours",
                (sid, stamp, None if err else stamp, "error" if err else "ok", err, latest, len(gaps),
                 sum(g[2] for g in gaps)))
            if gaps:
                with_gaps += 1
                if len(parts) < MAX_GAPS_IN_MESSAGE:
                    parts.append(f"[{sid}] {_gap_text(gaps)}")
    if not with_gaps:
        return "gaps: none"
    more = f"; +{with_gaps - len(parts)} more series with gaps" if with_gaps > len(parts) else ""
    return "; ".join(parts) + more


def _post_ingest(db_path, now) -> None:
    """Monitoring: log the published AI forecasts / map alerts, and the daily retention cleanup."""
    try:
        from routers import monitor  # lazy, like _after_success
        monitor.post_ingest(db_path, now)
    except Exception:  # noqa: BLE001 - monitoring must never fail an ingest
        log.exception("post-ingest monitoring step failed")


def _after_success(on_success) -> None:
    try:
        from routers import weather  # lazy: avoids an import cycle with the API package
        weather.invalidate_climatology()
    except Exception:  # noqa: BLE001 - cache invalidation must never fail an ingest
        pass
    if on_success:
        on_success()


# --- Consistency check --------------------------------------------------------------------------

def consistency_check(start: date = date(2026, 10, 1), end: date = date(2026, 10, 10),
                      location_id: str = DEFAULT_LOCATION_ID, db_path=None) -> dict:
    """Re-download [start, end] and compare with hourly_weather: {column: {n, max_abs, mean_abs}}."""
    conn = connect(db_path)
    try:
        loc = get_location(conn, location_id)
        stored = {r["timestamp"]: r for r in conn.execute(
            f"SELECT timestamp, {', '.join(COLS)} FROM hourly_weather WHERE location_id = ? "
            "AND timestamp BETWEEN ? AND ?",
            (location_id, f"{start} 00:00:00", f"{end} 23:59:59"))}
    finally:
        conn.close()
    api = {r["timestamp"]: r for r in fetch_historical(loc, start, end)}
    out = {}
    for c in COLS:
        diffs = []
        for ts, old in stored.items():
            new = api.get(ts)
            if new is None or old[c] is None or new[c] is None:
                continue
            d = abs(float(new[c]) - float(old[c]))
            diffs.append(min(d, 360 - d) if c == "wind_direction" else d)
        out[c] = {"n": len(diffs), "max_abs": round(max(diffs), 3) if diffs else None,
                  "mean_abs": round(sum(diffs) / len(diffs), 3) if diffs else None}
    out["_hours"] = {"db": len(stored), "api": len(api), "matched": len(set(stored) & set(api))}
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Ingest Open-Meteo data into weather.db")
    ap.add_argument("--location", default=None, help="location, cell or series id (default: all series)")
    ap.add_argument("--since", type=date.fromisoformat, help="re-fetch observed hours from this date (YYYY-MM-DD)")
    ap.add_argument("--forecast-only", action="store_true",
                    help="fetch only external reference forecasts (requires EXTERNAL_FORECAST_ENABLED=1; default: 0)")
    ap.add_argument("--check", action="store_true", help="only run the consistency check")
    ap.add_argument("--check-start", type=date.fromisoformat, default=date(2026, 10, 1))
    ap.add_argument("--check-end", type=date.fromisoformat, default=date(2026, 10, 10))
    a = ap.parse_args(argv)
    if a.check:
        res = consistency_check(a.check_start, a.check_end, a.location or DEFAULT_LOCATION_ID)
        print(f"{'variable':<27}{'n':>5}{'max_abs':>10}{'mean_abs':>10}")
        for c in COLS:
            r = res[c]
            print(f"{c:<27}{r['n']:>5}{r['max_abs']!s:>10}{r['mean_abs']!s:>10}")
        print("hours:", res["_hours"])
        mean_t = res["temperature"]["mean_abs"]
        if mean_t is None or mean_t > 0.3:
            print("STOP: temperature differs systematically (mean abs > 0.3 C) - different source/model?")
            return 2
        return 0
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    conn = connect()
    try:
        database.load_locations(conn)
    finally:
        conn.close()
    row = run_ingest(a.location, since=a.since, forecast_only=a.forecast_only)
    print(json.dumps(row, indent=2, ensure_ascii=False))
    return {"ok": 0, "partial": 3}.get(row["status"], 1)


if __name__ == "__main__":
    sys.exit(main())
