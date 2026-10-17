"""
User feedback (group 10): bug reports, suggestions and "wrong forecast" reports.

- No login. No IP address is stored; the IP is only used in memory for the rate limit (10 per hour per IP).
- Feedback is an unverified user report (verified = false), kept in its own table and never written into
  hourly_weather (observations). Retention: 365 days (routers/monitor.py, daily from the ingest loop).
"""
import json
import threading
import time
from collections import deque
from datetime import timedelta
from typing import Any, Deque, Dict, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field, field_validator

import database
from database import now_local
from routers.admin import require_admin
from routers.weather import _resolve_location

TS_FMT = "%Y-%m-%d %H:%M:%S"
RATE_LIMIT = 10                # submissions ...
RATE_WINDOW_S = 3600           # ... per hour per client IP (memory only)
SNAPSHOT_MAX_BYTES = 2048      # forecast_snapshot must stay small
RAIN_PROB_RAINY = 0.5          # a snapshot "forecasts rain" at rain_probability >= 0.5 ...
RAIN_MM = 0.1                  # ... or precipitation >= 0.1 mm

router = APIRouter(prefix="/feedback", tags=["feedback"])

_hits: Dict[str, Deque[float]] = {}
_hits_lock = threading.Lock()


def rate_limit(request: Request) -> None:
    ip = request.client.host if request.client else "?"
    now = time.monotonic()
    with _hits_lock:
        for k in [k for k, q in _hits.items() if not q or now - q[-1] > RATE_WINDOW_S]:
            del _hits[k]   # forget idle clients
        q = _hits.setdefault(ip, deque())
        while q and now - q[0] > RATE_WINDOW_S:
            q.popleft()
        if len(q) >= RATE_LIMIT:
            raise HTTPException(status_code=429, detail="Bạn đã gửi quá nhiều phản hồi, vui lòng thử lại sau 1 giờ")
        q.append(now)


class Observed(BaseModel):
    raining: Optional[bool] = None
    temperature_feel: Optional[Literal["hot", "ok", "cool"]] = None


class FeedbackIn(BaseModel):
    kind: Literal["bug", "suggestion", "wrong_forecast"]
    message: str = Field(default="", max_length=1000)
    location_id: Optional[str] = Field(default=None, max_length=100)
    observed: Optional[Observed] = None
    forecast_snapshot: Optional[Dict[str, Any]] = None
    app_version: Optional[str] = Field(default=None, max_length=32)
    platform: Optional[str] = Field(default=None, max_length=32)

    @field_validator("forecast_snapshot")
    @classmethod
    def _small(cls, v):
        if v is not None and len(json.dumps(v, ensure_ascii=False).encode("utf-8")) > SNAPSHOT_MAX_BYTES:
            raise ValueError(f"forecast_snapshot quá lớn (tối đa {SNAPSHOT_MAX_BYTES} byte)")
        return v


@router.post("", status_code=201)
def post_feedback(body: FeedbackIn, _: None = Depends(rate_limit)):
    """Store one feedback item. Returns {id, created_at, kind, cell_id, verified: false}."""
    cell_id = None
    if body.location_id:
        cell_id = _resolve_location(body.location_id).cell_id   # 404 for an unknown location
    obs = body.observed or Observed()
    created = now_local().strftime(TS_FMT)
    with database.get_db() as conn:
        cur = conn.execute(
            "INSERT INTO feedback (created_at, kind, message, location_id, cell_id, observed_raining, "
            "temperature_feel, forecast_snapshot, app_version, platform, verified) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
            (created, body.kind, body.message.strip(), body.location_id, cell_id,
             None if obs.raining is None else int(obs.raining), obs.temperature_feel,
             None if body.forecast_snapshot is None else json.dumps(body.forecast_snapshot, ensure_ascii=False),
             body.app_version, body.platform))
        conn.commit()
        fid = cur.lastrowid
    return {"id": fid, "created_at": database.to_local(created).isoformat(), "kind": body.kind,
            "cell_id": cell_id, "verified": False}


def _forecast_rain(snapshot: Optional[str]) -> Optional[bool]:
    """Did the forecast shown to the user say rain? None if the snapshot has no rain field."""
    try:
        s = json.loads(snapshot) if snapshot else {}
    except ValueError:
        return None
    if not isinstance(s, dict):
        return None
    p, mm = s.get("rain_probability"), s.get("precipitation")
    if isinstance(p, (int, float)):
        return p >= RAIN_PROB_RAINY
    if isinstance(mm, (int, float)):
        return mm >= RAIN_MM
    return None


@router.get("/summary", dependencies=[Depends(require_admin)])
def feedback_summary(days: Optional[int] = Query(default=None, ge=1, le=365, description="last N days; default all")):
    """Counts by kind and by cell, and the "wrong rain forecast" rate.
    A report with observed.raining counts as a wrong rain forecast if its forecast_snapshot said the opposite
    (rain_probability >= 0.5, else precipitation >= 0.1 mm), or - without a usable snapshot - if its kind is
    wrong_forecast. rain_wrong_rate = wrong / reports with observed.raining."""
    where, params = "", ()
    if days:
        where = "WHERE created_at >= ?"
        params = ((now_local().replace(tzinfo=None) - timedelta(days=days)).strftime(TS_FMT),)
    rows = database.execute_query(f"SELECT kind, cell_id, observed_raining, temperature_feel, forecast_snapshot "
                                  f"FROM feedback {where}", params)
    by_kind: Dict[str, int] = {}
    by_cell: Dict[str, Dict[str, int]] = {}
    feel: Dict[str, int] = {}
    reports = wrong = 0
    for r in rows:
        by_kind[r["kind"]] = by_kind.get(r["kind"], 0) + 1
        c = by_cell.setdefault(r["cell_id"] or "unknown", {"total": 0})
        c["total"] += 1
        c[r["kind"]] = c.get(r["kind"], 0) + 1
        if r["temperature_feel"]:
            feel[r["temperature_feel"]] = feel.get(r["temperature_feel"], 0) + 1
        if r["observed_raining"] is None:
            continue
        reports += 1
        said = _forecast_rain(r["forecast_snapshot"])
        if (said is not None and said != bool(r["observed_raining"])) or (said is None and r["kind"] == "wrong_forecast"):
            wrong += 1
    return {"total": len(rows), "by_kind": by_kind,
            "by_cell": [{"cell_id": k, **v} for k, v in sorted(by_cell.items(), key=lambda kv: -kv[1]["total"])],
            "temperature_feel": feel, "rain_reports": reports, "rain_wrong": wrong,
            "rain_wrong_rate": round(wrong / reports, 3) if reports else None,
            "verified": False, "note": "Phản hồi người dùng chưa được kiểm chứng, không phải số liệu quan trắc"}
