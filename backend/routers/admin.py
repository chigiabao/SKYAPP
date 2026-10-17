"""
Admin endpoints: trigger an ingest run and read the ingest log.

Auth: if env ADMIN_TOKEN is set, requests must send it in the X-Admin-Token header;
otherwise only requests from localhost (127.0.0.1 / ::1) are allowed.
"""
import os
import secrets
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from starlette.concurrency import run_in_threadpool

import ingest

LOCAL_HOSTS = {"127.0.0.1", "::1"}


def require_admin(request: Request, x_admin_token: Optional[str] = Header(default=None)) -> None:
    token = os.environ.get("ADMIN_TOKEN")
    if token:
        if not x_admin_token or not secrets.compare_digest(x_admin_token, token):
            raise HTTPException(status_code=401, detail="Invalid or missing X-Admin-Token")
        return
    host = request.client.host if request.client else None
    if host not in LOCAL_HOSTS:
        raise HTTPException(status_code=403, detail="Admin endpoints are restricted to localhost")


router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


@router.post("/ingest")
async def trigger_ingest(
    location: str = Query(default=ingest.DEFAULT_LOCATION_ID),
    forecast_only: bool = Query(default=False),
):
    """Run one ingest now (blocks until finished) and return its ingest_log row."""
    try:
        return await run_in_threadpool(ingest.run_ingest, location, forecast_only=forecast_only)
    except ingest.IngestBusy:
        raise HTTPException(status_code=409, detail="An ingest run is already in progress")


@router.get("/ingest/log")
def ingest_log(limit: int = Query(default=20, ge=1, le=500)):
    """Latest ingest runs, newest first."""
    return ingest.get_log(limit)
