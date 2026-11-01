"""
Admin endpoints: trigger an ingest run and read the ingest log.

Auth: if env ADMIN_TOKEN is set, requests must send it in the X-Admin-Token header. Placeholder or short
tokens (e.g. `change-me` copied from .env.example, < MIN_TOKEN_LENGTH characters) disable /admin/*
with a 503 instead of protecting it with a guessable secret.
Without ADMIN_TOKEN only direct, non-browser requests from localhost (127.0.0.1 / ::1) are allowed:
- any proxy header (X-Forwarded-For / X-Real-IP / Forwarded) is refused, because behind a reverse
  proxy every request arrives from localhost;
- any browser request (Origin header, or Sec-Fetch-Site other than `none`) is refused, so a web page
  open in the developer's browser cannot drive /admin/* through localhost (CSRF / DNS rebinding).
Use curl/scripts locally, or set ADMIN_TOKEN.
"""
import logging
import os
import secrets
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from starlette.concurrency import run_in_threadpool

import ingest

LOCAL_HOSTS = {"127.0.0.1", "::1"}
PROXY_HEADERS = ("x-forwarded-for", "x-real-ip", "forwarded")
MIN_TOKEN_LENGTH = 24
PLACEHOLDER_TOKENS = frozenset({"change-me", "changeme", "change_me", "admin", "secret", "password", "token"})

MSG_TOKEN = "Thiếu hoặc sai X-Admin-Token."
MSG_WEAK_TOKEN = (f"ADMIN_TOKEN quá yếu (giá trị mẫu hoặc ngắn hơn {MIN_TOKEN_LENGTH} ký tự); "
                  "trang quản trị bị tắt cho đến khi đặt token ngẫu nhiên.")
MSG_PROXIED = "Yêu cầu quản trị qua proxy cần ADMIN_TOKEN."
MSG_BROWSER = "Không có ADMIN_TOKEN: trang quản trị không nhận yêu cầu từ trình duyệt; dùng curl hoặc đặt ADMIN_TOKEN."
MSG_LOCAL_ONLY = "Trang quản trị chỉ mở cho localhost."
MSG_INGEST_BUSY = "Đang có một lần nạp dữ liệu chạy."
MSG_FORECAST_ONLY = "forecast_only cần EXTERNAL_FORECAST_ENABLED=1; dự báo bên ngoài đang tắt."

log = logging.getLogger(__name__)


def weak_admin_token(token: str) -> bool:
    """True for values that must never protect /admin/* (placeholders from .env.example, short strings)."""
    return token.strip().lower() in PLACEHOLDER_TOKENS or len(token.strip()) < MIN_TOKEN_LENGTH


def require_admin(request: Request, x_admin_token: Optional[str] = Header(default=None)) -> None:
    token = os.environ.get("ADMIN_TOKEN")
    if token:
        if weak_admin_token(token):
            raise HTTPException(status_code=503, detail=MSG_WEAK_TOKEN)
        if not x_admin_token or not secrets.compare_digest(x_admin_token.encode(), token.encode()):
            raise HTTPException(status_code=401, detail=MSG_TOKEN)
        return
    if any(h in request.headers for h in PROXY_HEADERS):
        raise HTTPException(status_code=403, detail=MSG_PROXIED)
    if "origin" in request.headers or request.headers.get("sec-fetch-site", "none").lower() != "none":
        raise HTTPException(status_code=403, detail=MSG_BROWSER)
    host = request.client.host if request.client else None
    if host not in LOCAL_HOSTS:
        raise HTTPException(status_code=403, detail=MSG_LOCAL_ONLY)


def warn_if_weak_admin_token() -> None:
    """Startup check (called from main): a weak ADMIN_TOKEN is logged loudly; requests then get 503."""
    token = os.environ.get("ADMIN_TOKEN")
    if token and weak_admin_token(token):
        log.error("ADMIN_TOKEN is a placeholder or shorter than %d characters: /admin/* is disabled",
                  MIN_TOKEN_LENGTH)


router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


@router.post("/ingest")
async def trigger_ingest(
    location: str = Query(default=ingest.DEFAULT_LOCATION_ID),
    forecast_only: bool = Query(default=False),
):
    """Run one ingest now (blocks until finished) and return its ingest_log row."""
    if forecast_only and os.getenv("EXTERNAL_FORECAST_ENABLED", "0") != "1":
        raise HTTPException(status_code=409, detail=MSG_FORECAST_ONLY)
    try:
        return await run_in_threadpool(ingest.run_ingest, location, forecast_only=forecast_only)
    except ingest.IngestBusy:
        raise HTTPException(status_code=409, detail=MSG_INGEST_BUSY) from None


@router.get("/ingest/log")
def ingest_log(limit: int = Query(default=20, ge=1, le=500)):
    """Latest ingest runs, newest first."""
    return ingest.get_log(limit)
