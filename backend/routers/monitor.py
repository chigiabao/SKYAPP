"""
Monitoring (group 11) and data retention (group 9). Same auth as routers/admin.py.

Forecast log: after every successful ingest, post_ingest() writes into ai_forecast_log
  - source 'ai': the AI forecast (1/3/6 h) each series would publish now (issued at its last observed hour);
  - source 'map_alert': the /weather/map alert rule (thunderstorm code or >= 10 mm in the next 3 h) on the
    series' latest NWP issue.
  Rows are INSERT OR IGNORE: the first publication of an issue is what gets scored. Prediction is batched
  (one LightGBM call per model for all series, ~1-2 s for 67 series) so the ingest stays fast.
Retention (once per day, from the ingest loop): feedback > 365 days, ai_forecast_log > 90 days.

Endpoints: GET /admin/monitor, POST /admin/retrain, GET /admin/retrain/{job_id}, POST /admin/rollback.
Model versions: retraining writes models/v3_candidate/; it replaces models/v3 only if its mean test metrics
are better (lower mean temperature MAE and a mean rain F1 that is not lower); the replaced model is kept in
models/v3_prev/ and POST /admin/rollback swaps the two back.
"""
import json
import logging
import shutil
import sqlite3
import subprocess
import sys
import threading
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np
import pandas as pd
from fastapi import APIRouter, Depends, HTTPException, Query

import ai_model
import database
from database import DEFAULT_LOCATION_ID, now_local
from routers.admin import require_admin

log = logging.getLogger("monitor")
TS_FMT = "%Y-%m-%d %H:%M:%S"
BACKEND = Path(__file__).resolve().parents[1]
MODELS_DIR = BACKEND / "models"
TRAIN_SCRIPT = BACKEND / "scripts" / "train_global_v3.py"
FEEDBACK_RETENTION_DAYS = 365
FORECAST_LOG_RETENTION_DAYS = 90
RAIN_MM = 0.1               # observed rainy hour (same as ai_model.RAIN_THRESHOLD_MM)
ALERT_RAIN_MM = 10.0        # same rule as /weather/map (MAP_ALERT_RAIN_MM)
DEFAULT_RAIN_THRESHOLD = 0.5
V3_REQUIRED = ["feature_columns.json", "metadata_v3.json", "cell_static.json", "evaluation_v3.json"] + [
    f"{k}_model_{h}h.pkl" for k in ("temperature", "rain") for h in ai_model.HORIZONS]

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


def _connect(db_path=None) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path or database.DATABASE_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def _naive_now(now: Optional[datetime] = None) -> datetime:
    now = now or now_local()
    return now.astimezone(database.LOCAL_TZ).replace(tzinfo=None) if now.tzinfo else now


# --- Outbound API call counter (OSRM; Open-Meteo calls are in ingest_log.api_calls) --------------------

def record_api_call(service: str, ok: bool = True) -> None:
    """+1 call (and +1 error if not ok) for today's row of `service`. Never raises."""
    if not Path(database.DATABASE_PATH).exists():
        return
    try:
        with _connect() as conn:
            conn.execute("INSERT INTO api_call_log (day, service, calls, errors) VALUES (?, ?, 1, ?) "
                         "ON CONFLICT(day, service) DO UPDATE SET calls = calls + 1, errors = errors + excluded.errors",
                         (_naive_now().strftime("%Y-%m-%d"), service, 0 if ok else 1))
        conn.close()
    except sqlite3.Error:
        pass


# --- Forecast log (hooked into ingest) ------------------------------------------------------------------

def _series_cells(conn) -> List[tuple]:
    try:
        rows = conn.execute("SELECT series_id, MIN(cell_id) FROM cells GROUP BY series_id ORDER BY series_id").fetchall()
    except sqlite3.OperationalError:
        rows = []
    return [(r[0], r[1]) for r in rows] or [(DEFAULT_LOCATION_ID, DEFAULT_LOCATION_ID)]


def _predict_all(items: List[tuple]) -> Dict[str, dict]:
    """{series_id: predict_for_location()-like result} for [(series_id, cell_id, history)]. v3 cells are
    predicted in one batch (same features and post-processing as ai_model.predict_for_location); the others
    fall back to predict_for_location. Series without enough contiguous history are skipped."""
    out, batch = {}, []
    v3 = ai_model._load_v3()
    cols = ai_model.feature_columns_v3()
    for sid, cid, hist in items:
        try:
            canon = ai_model.canonical_cell_id(cid)
            if v3 and canon in ai_model._v3["static"]:
                h = ai_model._prepare_history(hist)
                x = ai_model.build_features_v3(h, ai_model._v3["static"][canon])[cols].iloc[[-1]]
                if x.isna().any(axis=None):
                    continue
                batch.append((sid, pd.Timestamp(h["timestamp"].iloc[-1]), x.values))
            else:
                out[sid] = ai_model.predict_for_location(hist, cid)
        except (ValueError, KeyError):
            continue
    if batch:
        X = np.vstack([b[2] for b in batch]).astype(np.float32)
        preds = {k: m.predict(X) for k, m in ai_model._v3["models"].items()}
        version = ai_model._v3["meta"].get("model_version", "unknown-v3")
        for i, (sid, issued, _) in enumerate(batch):
            out[sid] = {"issued_at": issued.isoformat(), "model_version": version, "predictions": {
                f"{h}h": {"temperature": round(float(preds[f"temp_{h}h"][i]), 2),
                          "rain_probability": round(min(max(float(preds[f"rain_{h}h"][i]), 0.0), 1.0), 4)}
                for h in ai_model.HORIZONS}}
    return out


def log_published_forecasts(db_path=None, now: Optional[datetime] = None) -> int:
    """Write the AI forecasts and map alerts published now into ai_forecast_log. Returns rows inserted."""
    path = str(db_path or database.DATABASE_PATH)
    stamp = _naive_now(now).strftime(TS_FMT)
    conn = _connect(path)
    try:
        series = _series_cells(conn)
        items = [(sid, cid, ai_model.load_history_from_db(db_path=path, location_id=sid)) for sid, cid in series]
        rows = []
        for sid, res in _predict_all(items).items():
            issued = datetime.fromisoformat(str(res["issued_at"])[:19])
            for key, p in res["predictions"].items():
                h = int(key.rstrip("h"))
                rows.append((sid, "ai", issued.strftime(TS_FMT), h, (issued + timedelta(hours=h)).strftime(TS_FMT),
                             p["temperature"], p["rain_probability"], None, None, res.get("model_version"), stamp))
        try:
            nwp = conn.execute(
                "SELECT f.location_id, f.issued_at, f.timestamp, f.precipitation, f.precipitation_probability, "
                "f.weather_code FROM nwp_forecast f JOIN (SELECT location_id, MAX(issued_at) iss FROM nwp_forecast "
                "GROUP BY location_id) m ON f.location_id = m.location_id AND f.issued_at = m.iss "
                "WHERE f.timestamp > f.issued_at AND f.timestamp <= datetime(f.issued_at, '+3 hours')").fetchall()
        except sqlite3.OperationalError:
            nwp = []
        groups: Dict[tuple, list] = {}
        for r in nwp:
            groups.setdefault((r["location_id"], r["issued_at"]), []).append(r)
        for (sid, iss), hrs in groups.items():
            precip = [r["precipitation"] for r in hrs if r["precipitation"] is not None]
            probs = [r["precipitation_probability"] / 100 for r in hrs if r["precipitation_probability"] is not None]
            total = round(sum(precip), 2) if precip else None
            alert = any(r["weather_code"] is not None and 95 <= r["weather_code"] <= 99 for r in hrs) or (
                total is not None and total >= ALERT_RAIN_MM)
            target = (datetime.fromisoformat(iss) + timedelta(hours=3)).strftime(TS_FMT)
            rows.append((sid, "map_alert", iss, 3, target, None, round(max(probs), 2) if probs else None, total,
                         int(alert), "nwp", stamp))
        with conn:
            before = conn.total_changes
            conn.executemany("INSERT OR IGNORE INTO ai_forecast_log (series_id, source, issued_at, horizon_h, "
                             "target_time, temperature, rain_probability, precipitation, alert, model_version, "
                             "logged_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
            return conn.total_changes - before
    finally:
        conn.close()


def run_retention(db_path=None, now: Optional[datetime] = None) -> dict:
    """Delete feedback older than 365 days and ai_forecast_log rows issued more than 90 days ago."""
    now = _naive_now(now)
    conn = _connect(db_path)
    try:
        with conn:
            fb = conn.execute("DELETE FROM feedback WHERE created_at < ?",
                              ((now - timedelta(days=FEEDBACK_RETENTION_DAYS)).strftime(TS_FMT),)).rowcount
            fl = conn.execute("DELETE FROM ai_forecast_log WHERE issued_at < ?",
                              ((now - timedelta(days=FORECAST_LOG_RETENTION_DAYS)).strftime(TS_FMT),)).rowcount
    finally:
        conn.close()
    return {"feedback_deleted": fb, "forecast_log_deleted": fl}


_retention_day: Dict[str, str] = {}   # db path -> last day the cleanup ran (in-process; a restart runs it again)


def post_ingest(db_path=None, now: Optional[datetime] = None) -> dict:
    """Ingest hook: log the published forecasts, then run the retention cleanup once per day."""
    out = {"logged": log_published_forecasts(db_path, now)}
    key, day = str(db_path or database.DATABASE_PATH), _naive_now(now).strftime("%Y-%m-%d")
    if _retention_day.get(key) != day:
        out["retention"] = run_retention(db_path, now)
        _retention_day[key] = day
    return out


# --- GET /admin/monitor -----------------------------------------------------------------------------------

def _rain_thresholds() -> Dict[int, float]:
    try:
        meta = json.loads((MODELS_DIR / "v3" / "metadata_v3.json").read_text(encoding="utf-8"))
        return {int(k.rstrip("h")): float(v) for k, v in meta["rain_decision_threshold"].items()}
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def _f1(tp: int, fp: int, fn: int) -> Optional[float]:
    return None if tp + fp + fn == 0 else round(2 * tp / (2 * tp + fp + fn), 3)


def _scores(rows: list, thr: Dict[int, float]) -> dict:
    errs = [abs(r["temperature"] - r["obs_t"]) for r in rows if r["temperature"] is not None and r["obs_t"] is not None]
    tp = fp = fn = 0
    for r in rows:
        if r["rain_probability"] is None or r["obs_p"] is None:
            continue
        pred = r["rain_probability"] >= thr.get(r["horizon_h"], DEFAULT_RAIN_THRESHOLD)
        act = r["obs_p"] >= RAIN_MM
        tp, fp, fn = tp + (pred and act), fp + (pred and not act), fn + (act and not pred)
    return {"n": len(rows), "temperature_mae": round(sum(errs) / len(errs), 3) if errs else None,
            "rain_f1": _f1(tp, fp, fn)}


def _ai_quality(conn, since: str) -> dict:
    rows = conn.execute(
        "SELECT l.horizon_h, substr(l.target_time, 1, 10) day, l.temperature, l.rain_probability, "
        "h.temperature obs_t, h.precipitation obs_p FROM ai_forecast_log l JOIN hourly_weather h "
        "ON h.location_id = l.series_id AND h.timestamp = l.target_time "
        "WHERE l.source = 'ai' AND l.issued_at >= ?", (since,)).fetchall()
    thr = _rain_thresholds()
    days: Dict[str, list] = {}
    for r in rows:
        days.setdefault(r["day"], []).append(r)
    return {"rain_thresholds": {f"{h}h": v for h, v in thr.items()} or None,
            "overall": _scores(rows, thr),
            "by_horizon": {f"{h}h": _scores([r for r in rows if r["horizon_h"] == h], thr) for h in ai_model.HORIZONS},
            "by_day": [{"day": d, **_scores(v, thr)} for d, v in sorted(days.items())]}


def _alert_quality(conn, since: str) -> dict:
    """Map alert (NWP rule) vs. the same rule on the observed hours issued+1..+3 (all 3 must be stored)."""
    rows = conn.execute(
        "SELECT substr(a.issued_at, 1, 10) day, a.alert, COUNT(h.timestamp) n, SUM(h.precipitation) p, "
        "MAX(CASE WHEN h.weather_code BETWEEN 95 AND 99 THEN 1 ELSE 0 END) storm FROM ai_forecast_log a "
        "LEFT JOIN hourly_weather h ON h.location_id = a.series_id AND h.timestamp > a.issued_at "
        "AND h.timestamp <= a.target_time WHERE a.source = 'map_alert' AND a.issued_at >= ? "
        "GROUP BY a.series_id, a.issued_at", (since,)).fetchall()
    days: Dict[str, dict] = {}
    for r in rows:
        if r["n"] < 3:
            continue
        observed = bool(r["storm"]) or (r["p"] or 0) >= ALERT_RAIN_MM
        d = days.setdefault(r["day"], {"day": r["day"], "evaluated": 0, "predicted": 0, "observed": 0,
                                       "false_alarms": 0, "missed": 0})
        d["evaluated"] += 1
        d["predicted"] += bool(r["alert"])
        d["observed"] += observed
        d["false_alarms"] += bool(r["alert"]) and not observed
        d["missed"] += observed and not r["alert"]
    by_day = [days[k] for k in sorted(days)]
    total = {k: sum(d[k] for d in by_day) for k in ("evaluated", "predicted", "observed", "false_alarms", "missed")}
    return {"rule": "thunderstorm code 95-99 or >= 10 mm in the next 3 h", "total": total, "by_day": by_day}


def _ingest_stats(conn, since: str) -> dict:
    rows = conn.execute(
        "SELECT substr(started_at, 1, 10) day, COUNT(*) runs, SUM(status = 'error') errors, "
        "SUM(status = 'partial') partial, SUM(COALESCE(api_calls, 0)) api_calls, "
        "SUM(COALESCE(cells_failed, 0)) cells_failed FROM ingest_log WHERE started_at >= ? GROUP BY day "
        "ORDER BY day", (since,)).fetchall()
    errs = conn.execute("SELECT id, started_at, status, message FROM ingest_log WHERE started_at >= ? "
                        "AND status IN ('error', 'partial') ORDER BY id DESC LIMIT 10", (since,)).fetchall()
    return {"by_day": [dict(r) for r in rows],
            "recent_errors": [{**dict(r), "message": (r["message"] or "")[:300]} for r in errs]}


def _api_calls(conn, since: str, ingest_days: list) -> List[dict]:
    days: Dict[str, dict] = {}
    for d in ingest_days:
        days.setdefault(d["day"], {"day": d["day"], "open_meteo": 0, "osrm": 0, "osrm_errors": 0})["open_meteo"] = \
            d["api_calls"]
    for r in conn.execute("SELECT day, calls, errors FROM api_call_log WHERE service = 'osrm' AND day >= ?",
                          (since[:10],)):
        d = days.setdefault(r["day"], {"day": r["day"], "open_meteo": 0, "osrm": 0, "osrm_errors": 0})
        d["osrm"], d["osrm_errors"] = r["calls"], r["errors"]
    return [days[k] for k in sorted(days)]


def _feedback_new(conn, since: str) -> dict:
    by_kind = {r[0]: r[1] for r in conn.execute(
        "SELECT kind, COUNT(*) FROM feedback WHERE created_at >= ? GROUP BY kind", (since,))}
    latest = conn.execute("SELECT id, created_at, kind, message, cell_id FROM feedback WHERE created_at >= ? "
                          "ORDER BY id DESC LIMIT 10", (since,)).fetchall()
    return {"total": sum(by_kind.values()), "by_kind": by_kind,
            "latest": [{**dict(r), "message": (r["message"] or "")[:200], "verified": False} for r in latest]}


@router.get("/monitor")
def get_monitor(days: int = Query(default=7, ge=1, le=90)):
    """AI quality (published forecasts vs. observations), map alert false alarms / misses, ingest errors,
    outbound API calls and new feedback over the last `days` days (default 7)."""
    now = _naive_now()
    since = (now - timedelta(days=days)).strftime(TS_FMT)
    conn = _connect()
    try:
        ingest_stats = _ingest_stats(conn, since)
        return {"generated_at": now.replace(tzinfo=database.LOCAL_TZ).isoformat(), "window_days": days,
                "model": _model_info(MODELS_DIR / "v3"),
                "ai_quality": _ai_quality(conn, since), "alerts": _alert_quality(conn, since),
                "ingest": ingest_stats, "api_calls": _api_calls(conn, since, ingest_stats["by_day"]),
                "feedback": _feedback_new(conn, since)}
    except sqlite3.OperationalError as e:
        raise HTTPException(status_code=503, detail=f"Cơ sở dữ liệu chưa được nâng cấp: {e}")
    finally:
        conn.close()


# --- Retrain / promote / rollback -------------------------------------------------------------------------

def _model_info(d: Path) -> Optional[dict]:
    try:
        meta = json.loads((d / "metadata_v3.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return {"model_version": meta.get("model_version"), "trained_at": meta.get("trained_at"),
            "test_score": _test_score(d)}


def _test_score(d: Path) -> Optional[dict]:
    """Mean held-out test metrics over every cell (kind 'test', alias 'tsn' excluded) and horizon."""
    try:
        ev = json.loads((d / "evaluation_v3.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    mae, f1 = [], []
    for cid, e in ev.items():
        if cid == DEFAULT_LOCATION_ID or not isinstance(e, dict) or e.get("test_kind", "test") != "test":
            continue
        for h in ai_model.HORIZONS:
            if e.get(f"temperature_mae_{h}h") is not None:
                mae.append(e[f"temperature_mae_{h}h"])
            if e.get(f"rain_f1_{h}h") is not None:
                f1.append(e[f"rain_f1_{h}h"])
    if not mae or not f1:
        return None
    return {"temperature_mae": round(sum(mae) / len(mae), 4), "rain_f1": round(sum(f1) / len(f1), 4),
            "cells": sum(1 for c in ev if c != DEFAULT_LOCATION_ID)}


def _is_better(cand: Optional[dict], cur: Optional[dict]) -> bool:
    if cand is None:
        return False
    if cur is None:
        return True
    return cand["temperature_mae"] < cur["temperature_mae"] and cand["rain_f1"] >= cur["rain_f1"]


_jobs: Dict[str, dict] = {}
_jobs_lock = threading.Lock()
_models_lock = threading.Lock()   # promote / rollback


def _reload_models() -> None:
    ai_model.reset_v3_cache()
    try:
        from routers import weather
        weather._replay_ai_rain.cache_clear()
    except Exception:  # noqa: BLE001
        pass


def _promote(cand: Path) -> None:
    cur, prev = MODELS_DIR / "v3", MODELS_DIR / "v3_prev"
    with _models_lock:
        if prev.exists():
            shutil.rmtree(prev)
        if cur.exists():
            cur.rename(prev)
        cand.rename(cur)
        _reload_models()


def _finish(job: dict, proc) -> None:
    rc = proc.wait()
    job["returncode"] = rc
    job["finished_at"] = _naive_now().isoformat(timespec="seconds")
    cand = Path(job["out"])
    if rc != 0:
        job["status"] = "failed"
        return
    missing = [f for f in V3_REQUIRED if not (cand / f).exists()]
    if missing:
        job.update(status="rejected", reason=f"candidate is missing {missing}")
        return
    job["candidate_score"] = _test_score(cand)
    job["current_score"] = _test_score(MODELS_DIR / "v3")
    if not _is_better(job["candidate_score"], job["current_score"]):
        job.update(status="rejected", reason="candidate is not better than models/v3 (kept in models/v3_candidate)")
        return
    try:
        _promote(cand)
    except OSError as e:
        job.update(status="failed", reason=f"promotion failed: {e}")
        return
    job.update(status="promoted", reason="candidate replaced models/v3; previous model kept in models/v3_prev")


def _watch(job: dict, proc, log_file) -> None:
    try:
        _finish(job, proc)
    except Exception as e:  # noqa: BLE001 - a job must always end in a final state
        job.update(status="failed", reason=f"{type(e).__name__}: {e}")
    finally:
        log_file.close()


def _job_view(job: dict) -> dict:
    out = {k: v for k, v in job.items() if not k.startswith("_")}
    try:
        lines = Path(job["log"]).read_text(encoding="utf-8", errors="replace").splitlines()
        out["log_tail"] = lines[-20:]
    except OSError:
        out["log_tail"] = []
    return out


@router.post("/retrain", status_code=202)
def post_retrain(quick: bool = Query(default=False, description="pass --quick to the training script")):
    """Start scripts/train_global_v3.py --out models/v3_candidate in a background subprocess."""
    with _jobs_lock:
        if any(j["status"] == "running" for j in _jobs.values()):
            raise HTTPException(status_code=409, detail="Đang có một lần huấn luyện chạy")
        cand = MODELS_DIR / "v3_candidate"
        if cand.exists():
            shutil.rmtree(cand)
        cand.mkdir(parents=True)
        job_id = uuid.uuid4().hex[:12]
        log_path = MODELS_DIR / f"retrain_{job_id}.log"
        log_file = open(log_path, "w", encoding="utf-8")
        cmd = [sys.executable, str(TRAIN_SCRIPT), "--out", str(cand)] + (["--quick"] if quick else [])
        try:
            proc = subprocess.Popen(cmd, cwd=str(BACKEND), stdout=log_file, stderr=subprocess.STDOUT)
        except OSError as e:
            log_file.close()
            raise HTTPException(status_code=500, detail=f"Không khởi chạy được script huấn luyện: {e}")
        job = {"job_id": job_id, "status": "running", "quick": quick, "out": str(cand), "log": str(log_path),
               "started_at": _naive_now().isoformat(timespec="seconds"), "finished_at": None, "returncode": None}
        _jobs[job_id] = job
        job["_thread"] = threading.Thread(target=_watch, args=(job, proc, log_file), daemon=True,
                                          name=f"retrain-{job_id}")
        job["_thread"].start()
    return _job_view(job)


@router.get("/retrain/{job_id}")
def get_retrain(job_id: str):
    job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Không tìm thấy job huấn luyện")
    return _job_view(job)


@router.post("/rollback")
def post_rollback():
    """Swap models/v3 and models/v3_prev (a second rollback restores the newer model)."""
    cur, prev, tmp = MODELS_DIR / "v3", MODELS_DIR / "v3_prev", MODELS_DIR / "v3_swap"
    with _models_lock:
        if not prev.exists():
            raise HTTPException(status_code=409, detail="Không có bản mô hình trước (models/v3_prev) để quay lại")
        if tmp.exists():
            shutil.rmtree(tmp)
        if cur.exists():
            cur.rename(tmp)
        prev.rename(cur)
        if tmp.exists():
            tmp.rename(prev)
        _reload_models()
    return {"status": "rolled_back", "current": _model_info(cur), "previous": _model_info(prev)}
