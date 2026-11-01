"""
Weather API - FastAPI Backend
Student weather app for Ho Chi Minh City.
"""
from contextlib import asynccontextmanager
import json
import logging
import math
import sqlite3
import threading
from datetime import timedelta
from typing import Optional

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path
import os
import sys

# Add backend directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config
from routers import weather, weather_climatology, locations, admin
from models import CellsHealth, HealthCheck, StaleCell
from database import (DATABASE_PATH, DEFAULT_LOCATION_ID, execute_one, execute_query, init_db, now_local,
                      to_local)
import ai_model
import errors
import long_range_model_v2 as long_range_model
from rate_limit import EXEMPT_PATHS, RateLimitMiddleware
from maintenance import retention_worker

# Minimal structured logs (time, level, logger) for app loggers; level from LOG_LEVEL.
_log_level = getattr(logging, os.environ.get("LOG_LEVEL", "INFO").strip().upper(), None)
logging.basicConfig(level=_log_level if isinstance(_log_level, int) else logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")
# HTTPX request INFO logs include full webhook URLs, which can contain secrets.
logging.getLogger("httpx").setLevel(logging.WARNING)


class _AccessQueryFilter(logging.Filter):
    def filter(self, record):
        # Uvicorn's default access record includes the query, even for rejected requests.
        if isinstance(record.args, tuple) and len(record.args) == 5:
            client, method, target, version, status = record.args
            if isinstance(target, str):
                record.args = (client, method, target.split("?", 1)[0], version, status)
        return True


logging.getLogger("uvicorn.access").addFilter(_AccessQueryFilter())
log = logging.getLogger("ingest.scheduler")
WEB_DIRECTORY = Path(os.environ["WEB_DIST"]).resolve() if os.environ.get("WEB_DIST") else None
if WEB_DIRECTORY is not None and not (WEB_DIRECTORY / "index.html").is_file():
    raise RuntimeError("WEB_DIST must contain a compiled Flutter web index.html")
alert_log = logging.getLogger("ingest.alert")
INGEST_MINUTE = 5   # hourly run at HH:05 local
INGEST_RETRY_SECONDS = 300   # one early retry per hourly cycle
INGEST_SHUTDOWN_SECONDS = 5
_scheduler_lock = threading.Lock()
_scheduler_state = {
    'state': 'not_started', 'last_attempt_at': None, 'last_finished_at': None,
    'last_outcome': None, 'next_run_at': None, 'consecutive_failures': 0,
}


def _set_scheduler(**changes) -> None:
    with _scheduler_lock:
        _scheduler_state.update(changes)


def _scheduler_snapshot() -> dict:
    with _scheduler_lock:
        return dict(_scheduler_state)


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


# Ingest alerts: ERROR log (one JSON line) + optional webhook POST, once per incident, re-armed on recovery.
ALERT_TIMEOUT_SECONDS = 5
_alerts_active: set[str] = set()


def _data_age_hours(now) -> Optional[float]:
    """Age of the default series' latest hour (same source as /health data_age_hours); None if unknown."""
    try:
        if not DATABASE_PATH.is_file():
            return None
        row = execute_one("SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ?", (DEFAULT_LOCATION_ID,))
        return (now - to_local(row[0])).total_seconds() / 3600 if row and row[0] else None
    except Exception:  # noqa: BLE001 - alerting must never break the scheduler
        return None


def _post_webhook(url: str, payload: dict) -> None:
    try:
        import httpx
        httpx.post(url, json=payload, timeout=ALERT_TIMEOUT_SECONDS).raise_for_status()
    except Exception as exc:  # noqa: BLE001 - a dead webhook must not crash anything
        status = getattr(getattr(exc, "response", None), "status_code", None)
        alert_log.warning("alert webhook failed: %s (status=%s)", type(exc).__name__,
                          status if isinstance(status, int) else None)


def _emit_alert(kind: str, payload: dict) -> None:
    payload = {"event": "ingest_alert", "kind": kind, **payload}
    alert_log.error(json.dumps(payload, ensure_ascii=False, default=str))
    url = os.environ.get("ALERT_WEBHOOK_URL", "").strip()
    if url:   # fire-and-forget: the scheduler never waits for the webhook
        threading.Thread(target=_post_webhook, args=(url, payload), name="ingest-alert", daemon=True).start()


def _check_ingest_alerts(outcome: str, failures: int, now) -> None:
    """Alert when ingest failed ALERT_FAILURE_THRESHOLD times in a row or data is older than ALERT_STALE_HOURS."""
    try:
        threshold = _env_int("ALERT_FAILURE_THRESHOLD", 3)
        stale_hours = _env_int("ALERT_STALE_HOURS", 6)
        age = _data_age_hours(now)
        checks = {
            "consecutive_failures": threshold > 0 and failures >= threshold,
            "stale_data": stale_hours > 0 and (age is None or age > stale_hours),
        }
        for kind, firing in checks.items():
            if firing and kind not in _alerts_active:
                _alerts_active.add(kind)
                _emit_alert(kind, {"at": now.isoformat(), "last_outcome": outcome, "consecutive_failures": failures,
                                   "failure_threshold": threshold, "data_age_hours":
                                   round(age, 1) if age is not None else None, "stale_hours": stale_hours})
            elif not firing and kind in _alerts_active:
                _alerts_active.discard(kind)
                alert_log.info(json.dumps({"event": "ingest_alert_resolved", "kind": kind, "at": now.isoformat()}))
    except Exception:  # noqa: BLE001
        alert_log.exception("ingest alert check failed")


def _seconds_until_next_run(now) -> float:
    nxt = now.replace(minute=INGEST_MINUTE, second=0, microsecond=0)
    if nxt <= now:
        nxt += timedelta(hours=1)
    return (nxt - now).total_seconds()


def _ingest_loop(stop: threading.Event) -> None:
    """Hourly ingestion, with one bounded early retry after a failed/partial run."""
    import ingest
    early_retry_used = False
    retry_cycle = None
    failures = 0
    try:
        while not stop.is_set():
            _set_scheduler(state='running', last_attempt_at=now_local().isoformat(), next_run_at=None)
            try:
                row = ingest.run_ingest(on_success=weather_climatology._climatology)
                outcome = row['status']
                log.info('ingest %s: +%s ~%s %s', outcome, row['rows_inserted'], row['rows_updated'],
                         row['message'])
            except ingest.IngestBusy:
                outcome = 'busy'
                log.info('ingest skipped: another run in progress')
            except Exception:  # noqa: BLE001 - the scheduler must survive any failure
                outcome = 'error'
                log.exception('ingest crashed')
            finished = now_local()
            cycle = finished.replace(minute=INGEST_MINUTE, second=0, microsecond=0)
            if cycle > finished:
                cycle -= timedelta(hours=1)
            if cycle != retry_cycle:
                retry_cycle = cycle
                early_retry_used = False
            if outcome == 'ok':
                failures = 0
            elif outcome != 'busy':
                failures += 1
            _set_scheduler(last_finished_at=finished.isoformat(), last_outcome=outcome,
                           consecutive_failures=failures)
            if outcome != 'busy':
                _check_ingest_alerts(outcome, failures, finished)
            if stop.is_set():
                break
            regular_wait = _seconds_until_next_run(finished)
            delay = regular_wait
            if outcome == 'busy':
                delay = min(60, regular_wait)
            elif outcome != 'ok' and not early_retry_used and regular_wait > INGEST_RETRY_SECONDS:
                delay = INGEST_RETRY_SECONDS
                early_retry_used = True
            else:
                early_retry_used = False
            _set_scheduler(state='waiting', next_run_at=(finished + timedelta(seconds=delay)).isoformat())
            if stop.wait(delay):
                break
    finally:
        _set_scheduler(state='stopped', next_run_at=None)


@asynccontextmanager
async def lifespan(app: FastAPI):
    admin.warn_if_weak_admin_token()
    init_db()
    if execute_one("SELECT 1 FROM hourly_weather LIMIT 1") is not None:
        weather_climatology._climatology()
    stop = threading.Event()
    thread = None
    _set_scheduler(state='disabled', last_attempt_at=None, last_finished_at=None,
                   last_outcome=None, next_run_at=None, consecutive_failures=0)
    if os.environ.get("INGEST_ENABLED", "1") != "0":
        _set_scheduler(state='starting')
        thread = threading.Thread(target=_ingest_loop, args=(stop,), name="ingest-scheduler", daemon=True)
        thread.start()   # non-blocking: the API serves while the first ingest runs
    try:
        with retention_worker(DATABASE_PATH):
            yield
    finally:
        stop.set()
        if thread:
            if thread.is_alive():
                _set_scheduler(state='stopping', next_run_at=None)
            thread.join(timeout=INGEST_SHUTDOWN_SECONDS)
            if not thread.is_alive():
                _set_scheduler(state='stopped', next_run_at=None)


def _env_flag(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    return default if value is None else value.strip().lower() in ("1", "true", "yes", "on")


# Interactive docs + schema are on for dev; set ENABLE_DOCS=0 in production to hide them.
ENABLE_DOCS = _env_flag("ENABLE_DOCS", True)

app = FastAPI(
    lifespan=lifespan,
    title="HCMC Weather API",
    description="Weather data and forecasts for Ho Chi Minh City",
    version="1.0.0",
    docs_url="/docs" if ENABLE_DOCS else None,
    redoc_url="/redoc" if ENABLE_DOCS else None,
    openapi_url="/openapi.json" if ENABLE_DOCS else None,
)
app.add_exception_handler(RequestValidationError, errors.validation_exception_handler)

def _cors_origins() -> list[str]:
    """CORS_ORIGINS: comma-separated origins, or `*` (default; safe because auth is a Bearer header, no cookies)."""
    origins = [o.strip().rstrip("/") for o in os.environ.get("CORS_ORIGINS", "*").split(",") if o.strip()]
    return ["*"] if not origins or "*" in origins else origins


# Per-IP rate limit (RATE_LIMIT_PER_MINUTE, default 120, 0 = off). Added before CORS so CORS stays outermost
# and 429 responses still carry CORS headers for browsers.
RATE_LIMIT_PER_MINUTE = _env_int("RATE_LIMIT_PER_MINUTE", 120)
if RATE_LIMIT_PER_MINUTE > 0:
    rate_limit_exempt = EXEMPT_PATHS
    if WEB_DIRECTORY is not None:
        # Asset downloads must not consume the API budget on first load or refresh.
        rate_limit_exempt = EXEMPT_PATHS | {"/"} | {
            "/" + path.relative_to(WEB_DIRECTORY).as_posix()
            for path in WEB_DIRECTORY.rglob("*") if path.is_file()
        }
    app.add_middleware(RateLimitMiddleware, per_minute=RATE_LIMIT_PER_MINUTE,
                       trust_proxy=_env_flag("TRUST_PROXY", False), exempt_paths=rate_limit_exempt)

# The Flutter app authenticates with `Authorization: Bearer`, never cookies, so credentials stay off by
# default; CORS_ALLOW_CREDENTIALS=1 only applies to an explicit origin list (never together with `*`).
CORS_ORIGINS = _cors_origins()
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials=CORS_ORIGINS != ["*"] and _env_flag("CORS_ALLOW_CREDENTIALS", False),
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(weather.router)
app.include_router(locations.router)
app.include_router(admin.router)
from routers import route as route_router, feedback as feedback_router, monitor as monitor_router   # groups 6/7, 10, 11
app.include_router(route_router.router)
app.include_router(feedback_router.router)
app.include_router(monitor_router.router)
from routers import auth as auth_router, sync as sync_router   # optional accounts + cross-device sync
app.include_router(auth_router.router)
app.include_router(sync_router.router)
from password_reset import router as password_reset_router
app.include_router(password_reset_router)


class HealthWithIngest(HealthCheck):
    last_ingest: Optional[dict] = None   # {finished_at, status, rows_inserted} of the latest finished run
    cells: Optional[CellsHealth] = None  # None on a DB without the cells table
    ready: bool = False
    reasons: list[str] = []
    model_status: Optional[str] = None
    scheduler: Optional[dict] = None


def _cells_health(now) -> Optional[CellsHealth]:
    """Per-cell freshness: latest hour of every series (one index lookup each) + the last ingest outcome."""
    try:
        cells = execute_query(
            "SELECT cell_id, series_id, (SELECT timestamp FROM hourly_weather "
            "WHERE location_id = cells.series_id ORDER BY timestamp DESC LIMIT 1) AS latest_timestamp "
            "FROM cells ORDER BY cell_id")
    except sqlite3.OperationalError as exc:
        if 'no such table:' in str(exc) or 'no such column:' in str(exc):
            return None   # DB not migrated yet
        raise
    try:
        status = {r["series_id"]: r for r in execute_query("SELECT series_id, status, error FROM series_status")}
    except sqlite3.OperationalError as exc:
        if 'no such table: series_status' not in str(exc):
            raise
        status = {}
    cutoff = now - timedelta(hours=config.CELL_FRESH_HOURS)
    stale = []
    for c in cells:
        ts = to_local(c["latest_timestamp"]) if c["latest_timestamp"] else None
        if ts is None or ts < cutoff or ts > now:
            st = status.get(c["series_id"])
            stale.append(StaleCell(cell_id=c["cell_id"], series_id=c["series_id"], latest_timestamp=ts,
                                   status=st["status"] if st else None, error=st["error"] if st else None))
    return CellsHealth(total=len(cells), fresh=len(cells) - len(stale), fresh_hours=config.CELL_FRESH_HOURS, stale=stale)


@app.get("/", tags=["root"])
async def root():
    """API root endpoint."""
    if WEB_DIRECTORY is not None:
        return FileResponse(WEB_DIRECTORY / "index.html", headers={"Cache-Control": "no-cache"})
    return {
        "name": "HCMC Weather API",
        "version": "1.0.0",
        "docs": "/docs" if ENABLE_DOCS else None,
        "health": "/health"
    }


@app.get("/health", response_model=HealthWithIngest, tags=["health"])
def health_check():
    """Bounded availability checks; never run inference, ingestion or training."""
    db_status = "ok" if DATABASE_PATH.is_file() else "missing"
    now = now_local()
    latest = None
    last_ingest = None
    cells = None
    reasons = []
    if db_status == "ok":
        try:
            try:   # Keep legacy health fields tied to the default series.
                row = execute_one("SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ?",
                                  (DEFAULT_LOCATION_ID,))
            except sqlite3.OperationalError as exc:
                if "no such column: location_id" not in str(exc):
                    raise
                row = execute_one("SELECT MAX(timestamp) FROM hourly_weather")
            latest = to_local(row[0]) if row and row[0] else None
            try:
                r = execute_one("SELECT finished_at, status, rows_inserted FROM ingest_log "
                                "WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1")
                if r:
                    last_ingest = {"finished_at": to_local(r["finished_at"]).isoformat(), "status": r["status"],
                                   "rows_inserted": r["rows_inserted"]}
            except sqlite3.OperationalError as exc:
                if "no such table: ingest_log" not in str(exc):
                    raise
            cells = _cells_health(now)
        except (sqlite3.Error, OSError):
            db_status = "unavailable"
        except (ValueError, TypeError, AttributeError):
            reasons.append("weather_invalid")
    if db_status != "ok":
        reasons.append("database_missing" if db_status == "missing" else "database_unavailable")
    if latest is None:
        reasons.append("weather_missing")
    elif not 0 <= (now - latest).total_seconds() / 3600 <= config.CELL_FRESH_HOURS:
        reasons.append("weather_stale_or_future")
    if cells is None:
        reasons.append("fresh_coverage_unavailable")
    elif cells.total == 0 or cells.fresh != cells.total:
        reasons.append("incomplete_fresh_coverage")
    model_status = "not_checked"
    if not reasons:
        try:
            recent = execute_query("SELECT timestamp, temperature FROM hourly_weather WHERE location_id = ? "
                                   "ORDER BY timestamp DESC LIMIT ?",
                                   (DEFAULT_LOCATION_ID, long_range_model.MIN_HISTORY_HOURS))
            times = [to_local(r[0]) for r in recent]
            if (len(times) != long_range_model.MIN_HISTORY_HOURS or times[0] != latest
                    or any(t.minute or t.second or t.microsecond for t in times)
                    or any(a - b != timedelta(hours=1) for a, b in zip(times, times[1:]))):
                reasons.append("forecast_history_incomplete")
            if any(not math.isfinite(float(r[1])) for r in recent):
                reasons.append("forecast_history_invalid")
        except (sqlite3.Error, OSError):
            db_status = "unavailable"
            reasons.append("database_unavailable")
        except (ValueError, TypeError, AttributeError):
            reasons.append("forecast_history_invalid")
    if not reasons:
        # status() validates local artifacts once per revision; stale/empty DBs never load boosters.
        model = long_range_model.status()
        model_status = model["status"]
        if model_status != "available":
            reasons.append("forecast_model_unavailable")
        else:
            if ai_model.canonical_cell_id(DEFAULT_LOCATION_ID) not in model.get("cell_ids", []):
                reasons.append("forecast_cell_unsupported")
            if model.get("capabilities", {}).get("temperature", {}).get("status") != "available":
                reasons.append("forecast_temperature_unsupported")
            try:
                cutoff = model.get("trained_through")
                if cutoff is None:
                    reasons.append("forecast_training_cutoff_unknown")
                elif latest <= to_local(cutoff):
                    reasons.append("forecast_input_before_training_cutoff")
            except (ValueError, TypeError, AttributeError):
                reasons.append("forecast_training_cutoff_unknown")
    return HealthWithIngest(
        status="healthy" if not reasons else "degraded",
        database=db_status,
        timestamp=now,
        latest_timestamp=latest,
        data_age_hours=round((now - latest).total_seconds() / 3600, 1) if latest else None,
        last_ingest=last_ingest,
        cells=cells,
        ready=not reasons,
        reasons=reasons,
        model_status=model_status,
        scheduler=_scheduler_snapshot(),
    )


@app.get("/live", tags=["health"])
async def liveness():
    return {"status": "alive"}


@app.get("/ready", tags=["health"])
def readiness():
    health = health_check()
    return JSONResponse(health.model_dump(mode="json"), status_code=200 if health.ready else 503)


# Register static files last so API routes and their security middleware keep priority.
if WEB_DIRECTORY is not None:
    app.mount("/", StaticFiles(directory=WEB_DIRECTORY, html=True), name="web")


if __name__ == "__main__":
    import uvicorn
    # reload needs an import string, not the app object; bind to localhost unless HOST says otherwise.
    reload = _env_flag("RELOAD", False)
    uvicorn.run("main:app" if reload else app, host=os.environ.get("HOST", "127.0.0.1"),
                port=int(os.environ.get("PORT", "8000")), reload=reload)
