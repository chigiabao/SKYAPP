"""Network-free retention worker, started after database initialization in the app lifespan."""
import logging
import os
import threading
from contextlib import contextmanager

from routers import monitor

log = logging.getLogger("maintenance")
MAINTENANCE_INTERVAL_SECONDS = 300
MAINTENANCE_SHUTDOWN_SECONDS = 5


def _maintenance_loop(stop: threading.Event, db_path=None) -> None:
    while not stop.is_set():
        try:
            monitor.maybe_run_retention(db_path)
        except Exception:  # noqa: BLE001 - a failed cleanup must not stop future retries
            log.exception("retention failed; will retry on the next maintenance tick")
        if stop.wait(MAINTENANCE_INTERVAL_SECONDS):
            break


@contextmanager
def retention_worker(db_path=None):
    """MAINTENANCE_ENABLED overrides INGEST_ENABLED; disabled-ingest tests stay inert by default."""
    if os.environ.get("MAINTENANCE_ENABLED", os.environ.get("INGEST_ENABLED", "1")) == "0":
        yield
        return
    stop = threading.Event()
    thread = threading.Thread(target=_maintenance_loop, args=(stop, db_path), name="retention-maintenance",
                              daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=MAINTENANCE_SHUTDOWN_SECONDS)
        if thread.is_alive():
            log.warning("retention still running after shutdown timeout")
