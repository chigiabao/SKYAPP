"""
Cross-device sync of one JSON document per account (saved places, settings, activities, consented habits),
plus the full data export. Requires `Authorization: Bearer <token>` (routers/auth.py).

Concurrency: the document has a `version`; PUT must send the `base_version` it was edited from. If another
device saved first, PUT returns 409 with the current document so the app can merge and retry.
Deleting data retains a JSON-null tombstone and advances the version so old revisions are never reused.
"""
import json
import math
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

import database
from routers import auth
from routers.auth import CurrentUser, current_user

router = APIRouter(prefix="/me", tags=["account"])

MAX_BODY_BYTES = 256 * 1024
MAX_JSON_DEPTH = 64
MAX_PLACES = 50
MAX_ACTIVITIES = 500
# Raw coordinates must never be synced: places are referenced by location_id only.
_GPS_KEYS = {"lat", "lon", "lng", "latitude", "longitude", "gps", "coords", "coordinates"}


class SavedPlace(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(..., min_length=1, max_length=64)            # location_id from /locations
    label: Optional[str] = Field(None, max_length=50)           # e.g. "home", "work"
    custom_name: Optional[str] = Field(None, max_length=100)
    order: int = Field(0, ge=0, le=10_000)


class QuietHours(BaseModel):
    model_config = ConfigDict(extra="forbid")
    start: str = Field(..., pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    end: str = Field(..., pattern=r"^([01]\d|2[0-3]):[0-5]\d$")


class Settings(BaseModel):
    model_config = ConfigDict(extra="allow")    # newer app versions may add settings
    units: Optional[Dict[str, str]] = None      # e.g. {"temperature": "c", "wind": "kmh"}
    theme: Optional[str] = Field(None, max_length=20)
    priority_metrics: List[str] = Field(default_factory=list, max_length=30)
    alert_thresholds: Dict[str, float] = Field(default_factory=dict)
    quiet_hours: Optional[QuietHours] = None


class SyncDocument(BaseModel):
    model_config = ConfigDict(extra="forbid")
    saved_places: List[SavedPlace] = Field(default_factory=list, max_length=MAX_PLACES)
    settings: Settings = Field(default_factory=Settings)
    activities: List[Dict[str, Any]] = Field(default_factory=list, max_length=MAX_ACTIVITIES)
    habits_consent: bool = False
    habits: Optional[Dict[str, Any]] = None

    @field_validator("saved_places")
    @classmethod
    def _unique_places(cls, v):
        if len({p.id for p in v}) != len(v):
            raise ValueError("Địa điểm bị trùng.")
        return v

    @model_validator(mode="after")
    def _habits_need_consent(self):
        if self.habits is not None and not self.habits_consent:
            raise ValueError("Chỉ đồng bộ thói quen khi người dùng đã đồng ý (habits_consent=true).")
        return self


class SyncPut(BaseModel):
    model_config = ConfigDict(extra="forbid")
    base_version: int = Field(..., ge=0, le=2**63 - 1)
    data: SyncDocument


def _has_gps_key(obj) -> bool:
    if isinstance(obj, dict):
        return any(str(k).lower() in _GPS_KEYS or _has_gps_key(v) for k, v in obj.items())
    if isinstance(obj, list):
        return any(_has_gps_key(v) for v in obj)
    return False


def _reject_constant(value):
    raise ValueError("Nonfinite JSON number")


def _finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("Nonfinite JSON number")
    return number


def _validate_json(value):
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        if depth > MAX_JSON_DEPTH:
            raise ValueError("JSON nesting is too deep")
        if isinstance(item, float) and not math.isfinite(item):
            raise ValueError("Nonfinite JSON number")
        if isinstance(item, dict):
            pending.extend((v, depth + 1) for v in item.values())
        elif isinstance(item, list):
            pending.extend((v, depth + 1) for v in item)


def _load_json(body):
    value = json.loads(body, parse_constant=_reject_constant, parse_float=_finite_float)
    _validate_json(value)
    return value


def _current(conn, user_id: int) -> dict:
    row = conn.execute("SELECT version, data, updated_at FROM user_data WHERE user_id = ?", (user_id,)).fetchone()
    if row is None:
        return {"version": 0, "data": None, "updated_at": None}
    try:
        data = _load_json(row["data"])
    except (ValueError, RecursionError):
        # Keep the revision and stored bytes intact; clients can replace this revision or delete it.
        raise HTTPException(status_code=409, detail={"message": "Dữ liệu đồng bộ đã lưu bị lỗi; hãy ghi đè hoặc xoá dữ liệu này.",
                                                     "version": row["version"]})
    return {"version": row["version"], "data": data, "updated_at": row["updated_at"]}


@router.get("/data")
def get_data(user: CurrentUser = Depends(current_user)):
    """The synced document; version 0 if untouched, data null if untouched or deleted."""
    with database.get_db() as conn:
        conn.execute("BEGIN")
        auth.require_session(conn, user)
        return _current(conn, user.id)


@router.put("/data")
async def put_data(request: Request, user: CurrentUser = Depends(current_user)):
    """Replace the document. Body: {"base_version": n, "data": {...}} (max 256 KB). 409 + current on conflict."""
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_BODY_BYTES:
            raise HTTPException(status_code=413, detail="Dữ liệu quá lớn (tối đa 256 KB).")
        body.extend(chunk)
    try:
        raw = _load_json(body)
        req = SyncPut.model_validate(raw)
    except ValidationError as e:
        raise RequestValidationError(e.errors(include_url=False, include_context=False))
    except (ValueError, RecursionError):
        raise HTTPException(status_code=422, detail="JSON không hợp lệ.")
    if _has_gps_key(raw.get("data")):
        raise HTTPException(status_code=422, detail="Không đồng bộ toạ độ GPS; hãy dùng location_id.")
    doc = req.data.model_dump()
    try:
        _validate_json(doc)
        text = json.dumps(doc, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        text.encode("utf-8")
    except (ValueError, RecursionError):
        raise HTTPException(status_code=422, detail="JSON không hợp lệ.")
    ids = [p["id"] for p in doc["saved_places"]]
    now = auth._now()
    with database.get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        auth.require_session(conn, user)
        if ids:
            known = {r[0] for r in conn.execute(
                f"SELECT id FROM locations WHERE id IN ({', '.join('?' * len(ids))})", ids)}
            unknown = sorted(set(ids) - known)
            if unknown:
                raise HTTPException(status_code=422, detail={"message": "Địa điểm không tồn tại.",
                                                             "unknown_location_ids": unknown})
        if req.base_version == 0:
            cur = conn.execute("INSERT OR IGNORE INTO user_data (user_id, version, data, updated_at) "
                               "VALUES (?, 1, ?, ?)", (user.id, text, now))
        else:   # compare-and-swap: only succeeds if nobody saved since base_version
            cur = conn.execute("UPDATE user_data SET version = version + 1, data = ?, updated_at = ? "
                               "WHERE user_id = ? AND version = ?", (text, now, user.id, req.base_version))
        if cur.rowcount != 1:
            current = _current(conn, user.id)
            return JSONResponse(status_code=409, content={
                "detail": "Dữ liệu đã được thay đổi trên thiết bị khác. Hãy gộp với bản hiện tại rồi gửi lại.",
                "current": current})
        current = _current(conn, user.id)
        conn.commit()
        return current


@router.delete("/data", status_code=204)
def delete_data(user: CurrentUser = Depends(current_user)):
    """Erase the synced document, retaining its revision (the account stays)."""
    with database.get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        auth.require_session(conn, user)
        # Keep a tombstone even when empty so a stale PUT cannot reuse a deleted revision.
        conn.execute("INSERT INTO user_data (user_id, version, data, updated_at) "
                     "VALUES (?, 1, 'null', ?) "
                     "ON CONFLICT(user_id) DO UPDATE SET version = user_data.version + 1, "
                     "data = excluded.data, updated_at = excluded.updated_at", (user.id, auth._now()))
        conn.commit()
    return Response(status_code=204)


@router.get("/export")
def export(user: CurrentUser = Depends(current_user)):
    """Everything stored about the user, as a downloadable JSON file."""
    with database.get_db() as conn:
        conn.execute("BEGIN")
        row = auth.require_session(conn, user)
        account = {key: row[key] for key in ("email", "created_at", "last_active_at")}
        sessions = [dict(r) for r in conn.execute(
            "SELECT created_at, expires_at FROM sessions WHERE user_id = ? ORDER BY created_at", (user.id,))]
        payload = {"exported_at": auth._now(), "account": account, "sessions": sessions,
                   "sync": _current(conn, user.id), "privacy": auth.PRIVACY_POLICY}
    return JSONResponse(content=payload,
                        headers={"Content-Disposition": 'attachment; filename="sky-weather-export.json"'})
