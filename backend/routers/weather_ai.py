"""
Short-range AI endpoints: /weather/ai-forecast and /weather/ai-verify (archived or guarded replay).
"""
from fastapi import APIRouter, Query, HTTPException
from datetime import datetime, timedelta
from contextlib import closing
from functools import lru_cache
import json
import logging
from pathlib import Path
from typing import Optional
import sqlite3

import numpy as np

from database import execute_one, DEFAULT_LOCATION_ID, to_local
import ai_model
import config
from routers import weather_core as core
from routers.weather_core import (AT_DESC, LOCATION_DESC, TS_FMT, Series, _check_bounds, _floor_hour, _naive,
                                  _resolve_at, _resolve_location)

router = APIRouter()
log = logging.getLogger(__name__)

MSG_STALE_INPUT = "Dữ liệu đầu vào AI đã cũ hoặc ở tương lai (giới hạn {hours} giờ)."
MSG_HORIZON_EXPIRED = "Dữ liệu đầu vào AI đã cũ: mốc dự báo ngắn nhất đã trôi qua."
MSG_AI_UNAVAILABLE = "Không thể dự báo AI lúc này, vui lòng thử lại sau."
# Fixed public messages for known model input errors; the raw exception text is only logged.
_AI_ERROR_MESSAGES = (
    ("contiguous", "Dữ liệu lịch sử bị thiếu giờ (không liên tục), chưa thể dự báo AI."),
    ("missing feature values", "Dữ liệu đầu vào AI thiếu giá trị tại thời điểm phát hành."),
    ("hourly rows", "Không đủ dữ liệu lịch sử để dự báo"),
    ("model unavailable", "Mô hình AI chưa hỗ trợ ô lưới này."),
)


def _ai_error_message(error: ValueError) -> str:
    text = str(error)
    return next((msg for key, msg in _AI_ERROR_MESSAGES if key in text), MSG_AI_UNAVAILABLE)


@lru_cache(maxsize=1)
def _v2_tsn_evaluation() -> Optional[dict]:
    """Test-set metrics of the single-point v2 model (trained and tested on the 'tsn' series only)."""
    path = Path(ai_model.__file__).resolve().parent / "models" / "model_metadata.json"
    if not path.exists():
        return None
    meta = json.loads(path.read_text(encoding="utf-8"))
    if "test_metrics_temperature" not in meta:
        return None
    out = {"cell_id": DEFAULT_LOCATION_ID, "test_period": "..".join(t[:10] for t in meta["test"])}
    beats = True
    for h in ("1h", "3h", "6h"):
        t = {m["Model"]: m["MAE"] for m in meta["test_metrics_temperature"] if m["Horizon"] == h}
        r = {m["Model"]: m["F1"] for m in meta["test_metrics_rain"] if m["Horizon"] == h}
        lgbm_f1 = next((v for k, v in r.items() if k.startswith("LightGBM") and "val-tuned" in k), None)
        out[f"temperature_mae_{h}"] = round(t["LightGBM"], 3)
        out[f"rain_f1_{h}"] = None if lgbm_f1 is None else round(lgbm_f1, 3)
        base_mae = [t[k] for k in ("Persistence", "Climatology") if k in t]
        base_f1 = [r[k] for k in ("Persistence", "Climatology") if k in r]
        beats &= bool(base_mae) and t["LightGBM"] < min(base_mae)
        beats &= lgbm_f1 is not None and bool(base_f1) and lgbm_f1 > max(base_f1)
    out["beats_baselines"] = beats
    return out


def _evaluation(loc: Series) -> Optional[dict]:
    """Test-set evaluation of the serving model at the location's cell; None if it was never evaluated there."""
    if hasattr(ai_model, "evaluation_for"):
        ev = ai_model.evaluation_for(loc.cell_id)
        if ev is not None or loc.series_id != DEFAULT_LOCATION_ID:
            return ev
    return _v2_tsn_evaluation() if loc.series_id == DEFAULT_LOCATION_ID else None


def _ai_issue(until: Optional[datetime], loc: Series) -> dict:
    """AI forecast issued at the series' last stored hour <= until (naive local; None = latest)."""
    now = _naive(core.now_local())
    history = ai_model.load_history_from_db(db_path=str(core.DATABASE_PATH),
                                          until=until if until is not None else now,
                                          location_id=loc.series_id)
    if len(history) < ai_model.MIN_HISTORY_HOURS:
        raise HTTPException(status_code=503, detail="Không đủ dữ liệu lịch sử để dự báo")
    if until is None:
        issued = _naive(to_local(history["timestamp"].iloc[-1]))
        if not timedelta(0) <= now - issued <= timedelta(hours=config.CELL_FRESH_HOURS):
            raise HTTPException(status_code=503, detail=MSG_STALE_INPUT.format(hours=config.CELL_FRESH_HOURS))
        if issued + timedelta(hours=min(ai_model.HORIZONS)) <= now:
            raise HTTPException(status_code=503, detail=MSG_HORIZON_EXPIRED)
    try:
        result = ai_model.predict_for_location(history, loc.cell_id)
    except ValueError as e:
        log.warning("short-range AI inference failed for %s", loc.cell_id, exc_info=True)
        raise HTTPException(status_code=503, detail=_ai_error_message(e)) from None
    issued = to_local(result["issued_at"])
    result["issued_at"] = issued.isoformat()
    for key, pred in result["predictions"].items():
        pred["target_time"] = (issued + timedelta(hours=int(key.rstrip("h")))).isoformat()
    result["location_id"], result["cell_id"] = loc.location_id, loc.cell_id
    result["evaluation"] = _evaluation(loc)
    result["forecast_mode"] = "current_inference" if until is None else "retrospective"
    return result


@router.get("/ai-forecast")
def get_ai_forecast(at: Optional[str] = Query(default=None, description=AT_DESC),
                    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC)):
    """LightGBM forecast of temperature and rain probability 1/3/6 h after the latest observation (<= at)."""
    loc = _resolve_location(location_id)
    eff = _resolve_at(at, loc.series_id)
    return _ai_issue(None if eff is None else _naive(eff), loc)


@router.get("/ai-verify")
def get_ai_verify(at: Optional[str] = Query(default=None, description="Issue time (ISO 8601); default now - 6 h"),
                  location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
                  retrospective: bool = Query(default=False, description="Opt in to guarded current-model replay")):
    """Compare stored forecasts with model analysis, never silently regenerate an issue.

    Explicit at selects that exact hour; default selects the latest archive <= now-6h.
    Replay is opt-in, only when no archive exists, and is not an operational backtest.
    """
    loc = _resolve_location(location_id)
    eff = _resolve_at(at, loc.series_id, require_history=False)
    if eff is None:
        eff = _floor_hour(to_local(core.now_local())) - timedelta(hours=6)
    stamp = _naive(eff).strftime(TS_FMT)
    rows = []
    # Older/offline databases may not yet have an archive table.
    with closing(sqlite3.connect(str(core.DATABASE_PATH))) as con:
        con.row_factory = sqlite3.Row
        if con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='ai_forecast_log'").fetchone():
            op = "=" if at is not None else "<="
            rows = con.execute(
                "SELECT * FROM ai_forecast_log WHERE series_id = ? AND source = 'ai' AND issued_at = "
                f"(SELECT MAX(issued_at) FROM ai_forecast_log WHERE series_id = ? AND source = 'ai' "
                f"AND issued_at {op} ?) AND horizon_h IN (1, 3, 6) ORDER BY horizon_h",
                (loc.series_id, loc.series_id, stamp)).fetchall()
    # Stored forecasts survive input-history retention; non-archived requests keep existing bounds.
    if not rows and at is not None:
        _check_bounds(eff, loc.series_id)
    result = {"issued_at": eff.isoformat(), "requested_at": eff.isoformat(), "model_version": "",
              "horizons": [], "location_id": loc.location_id, "cell_id": loc.cell_id, "evaluation": None,
              "verification_mode": "unavailable", "forecast_source": None,
              "actual_source": "open_meteo_analysis", "evaluation_source": "not_archived",
              "interval_source": "not_archived", "unavailable_reason": "no_archived_forecast"}
    if rows:
        versions = {r["model_version"] for r in rows}
        predictions = {}
        try:
            issued = to_local(rows[0]["issued_at"])
            archived_at = to_local(max(r["logged_at"] for r in rows)).isoformat()
            if len(versions) != 1 or not next(iter(versions)):
                raise ValueError("mixed or missing archive model versions")
            for r in rows:
                temp, prob = float(r["temperature"]), float(r["rain_probability"])
                target = to_local(r["target_time"])
                if (not np.isfinite(temp) or not np.isfinite(prob) or not 0 <= prob <= 1 or
                        target != issued + timedelta(hours=r["horizon_h"])):
                    raise ValueError("invalid archived forecast")
                predictions[f"{r['horizon_h']}h"] = {"temperature": temp, "rain_probability": prob,
                                                      "target_time": target.isoformat()}
            issue = {"issued_at": issued.isoformat(), "model_version": rows[0]["model_version"],
                     "predictions": predictions}
        except (ValueError, TypeError):
            result["unavailable_reason"] = "invalid_archived_forecast"
            return result
        result.update(verification_mode="archived", forecast_source="ai_forecast_log", archived_at=archived_at)
    elif retrospective:
        try:
            cutoff = to_local(ai_model.verification_cutoff(loc.cell_id))
        except (ValueError, OSError, RuntimeError):
            result["unavailable_reason"] = "cutoff_unavailable"
            return result
        result["selection_cutoff"] = cutoff.isoformat()
        if eff <= cutoff:
            result["unavailable_reason"] = "issue_not_after_selection_cutoff"
            return result
        latest = execute_one("SELECT MAX(timestamp) AS timestamp FROM hourly_weather "
                             "WHERE location_id = ? AND timestamp <= ?", (loc.series_id, stamp))
        if not latest or not latest["timestamp"] or to_local(latest["timestamp"]) <= cutoff:
            result["unavailable_reason"] = "issue_not_after_selection_cutoff"
            return result
        issue = _ai_issue(_naive(eff), loc)
        # History can end earlier than the requested hour. Guard the actual issue too.
        if to_local(issue["issued_at"]) <= cutoff:
            result["unavailable_reason"] = "issue_not_after_selection_cutoff"
            return result
        result.update(verification_mode="retrospective", forecast_source="current_model_replay",
                      evaluation=issue["evaluation"], evaluation_source="current_model_test",
                      interval_source="not_returned")
    else:
        return result
    horizons = []
    for key, pred in issue["predictions"].items():
        target = datetime.fromisoformat(pred["target_time"])
        row = execute_one("SELECT temperature, precipitation FROM hourly_weather "
                          "WHERE location_id = ? AND timestamp = ?",
                          (loc.series_id, _naive(target).strftime(TS_FMT)))
        known = target <= to_local(core.now_local())
        temp = row["temperature"] if row and known else None
        precip = row["precipitation"] if row and known else None
        horizons.append({
            "horizon": key,
            "target_time": pred["target_time"],
            "predicted_temperature": pred["temperature"],
            "predicted_rain_probability": pred["rain_probability"],
            "actual_temperature": temp,
            "actual_precipitation": precip,
            "actual_rain": None if precip is None else precip > ai_model.RAIN_THRESHOLD_MM,
            "abs_error_temperature": None if temp is None else round(abs(pred["temperature"] - temp), 2),
        })
    result.update(issued_at=issue["issued_at"], model_version=issue["model_version"], horizons=horizons,
                  unavailable_reason=None)
    return result
