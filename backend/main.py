"""
Weather API - FastAPI Backend
Student weather app for Ho Chi Minh City.
"""
from contextlib import asynccontextmanager
import logging
import sqlite3
import threading
from datetime import timedelta
from typing import Optional

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import os
import sys

# Add backend directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from routers import weather, locations, admin
from models import CellsHealth, HealthCheck, StaleCell
from database import (DATABASE_PATH, DEFAULT_LOCATION_ID, execute_one, execute_query, init_db, now_local,
                      to_local)

log = logging.getLogger("ingest.scheduler")
INGEST_MINUTE = 5   # hourly run at HH:05 local
CELL_FRESH_HOURS = 3   # /health: a cell is fresh if its series has an hour within this many hours of now


def _seconds_until_next_run(now) -> float:
    nxt = now.replace(minute=INGEST_MINUTE, second=0, microsecond=0)
    if nxt <= now:
        nxt += timedelta(hours=1)
    return (nxt - now).total_seconds()


def _ingest_loop(stop: threading.Event) -> None:
    """Background thread: ingest once at startup, then every hour at minute INGEST_MINUTE."""
    import ingest
    while not stop.is_set():
        try:
            row = ingest.run_ingest(on_success=weather._climatology)   # re-warm the cache off the request path
            log.info("ingest %s: +%s ~%s %s", row["status"], row["rows_inserted"], row["rows_updated"],
                     row["message"])
        except ingest.IngestBusy:
            log.info("ingest skipped: another run in progress")
        except Exception:  # noqa: BLE001 - the scheduler must survive any failure
            log.exception("ingest crashed")
        stop.wait(_seconds_until_next_run(now_local()))


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    weather._climatology()
    stop = threading.Event()
    thread = None
    if os.environ.get("INGEST_ENABLED", "1") != "0":
        thread = threading.Thread(target=_ingest_loop, args=(stop,), name="ingest-scheduler", daemon=True)
        thread.start()   # non-blocking: the API serves while the first ingest runs
    yield
    stop.set()
    if thread:
        thread.join(timeout=5)


app = FastAPI(
    lifespan=lifespan,
    title="HCMC Weather API",
    description="Weather data and forecasts for Ho Chi Minh City",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

# CORS middleware - allow frontend to access API
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify actual frontend origin
    allow_credentials=False,
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


class HealthWithIngest(HealthCheck):
    last_ingest: Optional[dict] = None   # {finished_at, status, rows_inserted} of the latest finished run
    cells: Optional[CellsHealth] = None  # None on a DB without the cells table


def _cells_health(now) -> Optional[CellsHealth]:
    """Per-cell freshness: latest hour of every series (one index lookup each) + the last ingest outcome."""
    try:
        cells = execute_query("SELECT cell_id, series_id FROM cells ORDER BY cell_id")
        latest = {r[0]: r[1] for r in execute_query(
            "SELECT location_id, MAX(timestamp) FROM hourly_weather GROUP BY location_id")}
    except sqlite3.OperationalError:   # DB not migrated yet
        return None
    try:
        status = {r["series_id"]: r for r in execute_query("SELECT series_id, status, error FROM series_status")}
    except sqlite3.OperationalError:
        status = {}
    cutoff = now - timedelta(hours=CELL_FRESH_HOURS)
    stale = []
    for c in cells:
        ts = to_local(latest[c["series_id"]]) if latest.get(c["series_id"]) else None
        if ts is None or ts < cutoff:
            st = status.get(c["series_id"])
            stale.append(StaleCell(cell_id=c["cell_id"], series_id=c["series_id"], latest_timestamp=ts,
                                   status=st["status"] if st else None, error=st["error"] if st else None))
    return CellsHealth(total=len(cells), fresh=len(cells) - len(stale), fresh_hours=CELL_FRESH_HOURS, stale=stale)


@app.get("/", tags=["root"])
async def root():
    """API root endpoint."""
    return {
        "name": "HCMC Weather API",
        "version": "1.0.0",
        "docs": "/docs",
        "health": "/health"
    }


@app.get("/health", response_model=HealthWithIngest, tags=["health"])
async def health_check():
    """
    API health check.
    Returns status of the API and database connection.
    """
    db_status = "ok" if DATABASE_PATH.exists() else "missing"
    now = now_local()
    latest = None
    last_ingest = None
    if db_status == "ok":
        try:   # latest_timestamp / data_age_hours describe the 'tsn' series (the one the AI model serves)
            row = execute_one("SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = ?",
                              (DEFAULT_LOCATION_ID,))
        except sqlite3.OperationalError:   # old single-series DB without location_id
            row = execute_one("SELECT MAX(timestamp) FROM hourly_weather")
        latest = to_local(row[0]) if row and row[0] else None
        try:
            r = execute_one("SELECT finished_at, status, rows_inserted FROM ingest_log "
                            "WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1")
            if r:
                last_ingest = {"finished_at": to_local(r["finished_at"]).isoformat(), "status": r["status"],
                               "rows_inserted": r["rows_inserted"]}
        except sqlite3.OperationalError:   # DB not migrated yet (no ingest_log table)
            pass
    return HealthWithIngest(
        status="healthy" if db_status == "ok" else "degraded",
        database=db_status,
        timestamp=now,
        latest_timestamp=latest,
        data_age_hours=round((now - latest).total_seconds() / 3600, 1) if latest else None,
        last_ingest=last_ingest,
        cells=_cells_health(now) if db_status == "ok" else None,
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, reload=True)
