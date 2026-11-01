"""Serve the built web app + API on a throwaway COPY of the databases (for UI screenshots).

Source databases are opened read-only and backed up with SQLite's WAL-aware backup API to
--db-dir (default %TEMP%/sky_shots_db) once. Every module-level path is repointed there before
the app starts. Hourly ingest is disabled. --ingest-once fetches real inputs into the copy only.
Usage:
    python tool/serve_ui_snapshot.py --web build/web --port 8123
Delete --db-dir afterwards (tool/capture_ui.mjs does not touch it).
"""
import argparse
import json
import os
import sqlite3
import sys
import tempfile
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"


def snapshot_paths(db_dir: Path) -> list[tuple[Path, Path]]:
    root = db_dir.resolve()
    backend = BACKEND.resolve()
    if root == backend or backend in root.parents:
        raise ValueError("--db-dir must be outside the backend folder")
    paths = [(backend / "data" / name, root / name)
             for name in ("weather.db", "history/cells_history.db")]
    for _, target in paths:
        resolved = target.resolve()
        if root not in resolved.parents or resolved == backend or backend in resolved.parents:
            raise ValueError("Snapshot DB targets must stay inside --db-dir and outside backend")
        for source, _ in paths:
            if target.exists() and source.exists() and target.samefile(source):
                raise ValueError("Snapshot DB must not alias a source database")
    if all(target.exists() for _, target in paths) and paths[0][1].samefile(paths[1][1]):
        raise ValueError("Snapshot weather and history databases must be separate files")
    return paths


def backup_once(src: Path, dst: Path) -> None:
    if dst.exists() or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    print(f"backing up {src} -> {dst}", flush=True)
    with (closing(sqlite3.connect(src.resolve().as_uri() + "?mode=ro", uri=True)) as source,
          closing(sqlite3.connect(dst)) as target):
        source.backup(target)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8123)
    ap.add_argument("--web", default=str(ROOT / "build/web"))
    ap.add_argument("--db-dir", default=str(Path(tempfile.gettempdir()) / "sky_shots_db"))
    ap.add_argument("--ingest-once", action="store_true",
                    help="Refresh all grid inputs on the snapshot only; external forecasts stay off")
    args = ap.parse_args()

    db_dir = Path(args.db_dir).resolve()
    try:
        paths = snapshot_paths(db_dir)
    except ValueError as exc:
        ap.error(str(exc))
    weather_db = db_dir / "weather.db"
    history_db = db_dir / "history" / "cells_history.db"
    for src, dst in paths:
        backup_once(src, dst)

    os.environ["INGEST_ENABLED"] = "0"
    os.environ["MAINTENANCE_ENABLED"] = "0"
    os.environ["EXTERNAL_FORECAST_ENABLED"] = "0"
    os.environ["WEB_DIST"] = str(Path(args.web).resolve())
    os.environ.setdefault("CORS_ORIGINS", f"http://127.0.0.1:{args.port}")
    sys.path.insert(0, str(BACKEND))

    import database
    database.DATABASE_PATH = weather_db
    database.HISTORY_DB_PATH = history_db
    from routers import weather_core
    weather_core.DATABASE_PATH = weather_db
    weather_core.HISTORY_DB_PATH = history_db
    import main as app_main
    app_main.DATABASE_PATH = weather_db
    for name, mod in list(sys.modules.items()):   # any other `from database import DATABASE_PATH` copy
        if (mod is not None and getattr(mod, "DATABASE_PATH", None) not in (None, weather_db)
                and Path(str(mod.DATABASE_PATH)).resolve() == (BACKEND / "data/weather.db").resolve()):
            mod.DATABASE_PATH = weather_db
            print(f"repointed {name}.DATABASE_PATH", flush=True)

    if args.ingest_once:
        import ingest
        row = ingest.run_ingest(db_path=weather_db)
        (db_dir / "ingest-result.json").write_text(
            json.dumps(row, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Snapshot ingest: {row['status']} ({row['cells_ok']} series ok)", flush=True)
        if row["status"] != "ok":
            raise SystemExit("Snapshot refresh incomplete; inspect ingest-result.json")

    import uvicorn
    print(f"UI snapshot server: http://127.0.0.1:{args.port} (db: {db_dir}, ingest off)", flush=True)
    uvicorn.run(app_main.app, host="127.0.0.1", port=args.port)


if __name__ == "__main__":
    main()
