"""
Core /weather endpoints: current, hourly, daily, bundle, history and forecast-status.
"""
from fastapi import APIRouter, Query, HTTPException, Response
from fastapi.encoders import jsonable_encoder
from datetime import datetime, timedelta
from functools import lru_cache
import json
from pathlib import Path
from typing import List, Optional

import pandas as pd

from database import execute_query, execute_one, to_local
from models import WeatherData, DailySummary, WeatherFieldSource
import long_range_model_v2 as long_range_model
from routers import weather_core as core, weather_climatology as clim
from routers.weather_core import (AT_DESC, LOCATION_DESC, TS_FMT, _aq_fields, _aq_rows, _floor_hour,
                                  _latest_observed, _naive, _resolve_at, _resolve_location, row_to_weather_data)
from routers.weather_climatology import _clim_series
from routers.weather_series import _series, _own_forecast_rows
from routers.weather_daily import _daily_summary, _label_confidence
from routers.weather_ai import get_ai_forecast

router = APIRouter()


def _current_supplements(current: WeatherData, sid: str, now: datetime) -> WeatherData:
    """Attach recent reference metrics without changing or mutating cached AI outputs."""
    lo = now - timedelta(hours=1)
    row = execute_one('SELECT * FROM hourly_weather WHERE location_id = ? '
                      'AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC LIMIT 1',
                      (sid, lo.strftime(TS_FMT), now.strftime(TS_FMT)))
    aq = _aq_rows(lo, now, sid)
    aq_row = aq[max(aq)] if aq else None
    values, sources = {}, dict(current.field_sources)
    for reference, provider, fields in (
        (row, 'open_meteo', ('apparent_temperature', 'visibility', 'surface_pressure',
                             'pressure_msl', 'uv_index')),
        (aq_row, 'open_meteo_cams', ('us_aqi', 'pm2_5', 'pm10')),
    ):
        if reference is None:
            continue
        for field in fields:
            if getattr(current, field) is None and field in reference.keys() and reference[field] is not None:
                values[field] = reference[field]
                sources[field] = WeatherFieldSource(source=provider, timestamp=to_local(reference['timestamp']))
    return current.model_copy(update={**values, 'field_sources': sources})


@router.get("/current", response_model=WeatherData)
def get_current_weather(at: Optional[str] = Query(default=None, description=AT_DESC),
                        location_id: Optional[str] = Query(default=None, description=LOCATION_DESC)):
    """Live: own AI predicts this hour from earlier inputs. Replay: historical reference."""
    loc = _resolve_location(location_id)
    sid = loc.series_id
    eff = _resolve_at(at, sid)
    if eff is None:
        now = _naive(_floor_hour(to_local(core.now_local())))
        current = _own_forecast_rows(sid, now).get(now)
        if current is None:
            raise HTTPException(status_code=503, detail='AI chưa có dự báo cho giờ hiện tại.')
        return _current_supplements(current, sid, now)
    row = execute_one("SELECT * FROM hourly_weather WHERE location_id = ? AND timestamp <= ? "
                      "ORDER BY timestamp DESC LIMIT 1", (sid, _naive(eff).strftime(TS_FMT)))
    if not row:
        raise HTTPException(status_code=404, detail="Chưa có dữ liệu thời tiết.")
    # Air quality at the same hour, else the nearest within +-1 h, never after the effective now.
    ts = datetime.fromisoformat(row["timestamp"])
    now = _naive(eff if eff is not None else _floor_hour(to_local(core.now_local())))
    aq = _aq_rows(ts - timedelta(hours=1), min(ts + timedelta(hours=1), now), sid)
    best = min(aq, key=lambda t: (abs(t - ts), t > ts)) if aq else None
    return row_to_weather_data(row, **_aq_fields(aq.get(best)))


@router.get("/hourly", response_model=List[WeatherData])
def get_hourly_forecast(
    hours: int = Query(default=24, ge=1, le=168, description="Number of hours to forecast (1-168)"),
    at: Optional[str] = Query(default=None, description=AT_DESC),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """N hours from now, including current: only our own AI, without external forecast fallback.
    Replay is historical analysis/climatology, not an AI backtest."""
    sid = _resolve_location(location_id).series_id
    eff = _resolve_at(at, sid)
    start = _naive(eff if eff is not None else _floor_hour(to_local(core.now_local())))
    times = [start + timedelta(hours=i) for i in range(hours)]
    items = [i for i in _series(times, _latest_observed(sid), use_forecast=eff is None, sid=sid) if i is not None]
    if not items:
        raise HTTPException(status_code=404, detail="Chưa có dữ liệu dự báo.")
    return items


@router.get('/forecast-status')
def get_forecast_status():
    """Artifact capabilities and held-out evaluation; availability is not a skill claim."""
    info = long_range_model.status()
    info['experimental'] = True
    if info['status'] == 'available':
        info['evaluation'] = _own_evaluation(long_range_model.artifact_revision())
    return info


@lru_cache(maxsize=2)
def _own_evaluation(revision: tuple) -> Optional[dict]:
    try:
        path = Path(revision[0])
        report = json.loads((path / 'evaluation.json').read_text(encoding='utf-8'))
        meta = json.loads((path / 'metadata.json').read_text(encoding='utf-8'))
        return {'test_period': meta['split']['test'], 'targets': {
            name: {'metric': result['test']['primary_metric'], 'overall': result['test']['overall'],
                   'by_day': result['test']['by_day']} for name, result in report.items()}}
    except (OSError, ValueError, KeyError, TypeError):
        return None


@router.get("/daily", response_model=List[DailySummary])
def get_daily_forecast(
    days: int = Query(default=7, ge=1, le=14, description="Number of days to forecast (1-14)"),
    at: Optional[str] = Query(default=None, description=AT_DESC),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """Daily aggregation of our hourly AI plus already known hours today.
    AI rain_day_probability = max hourly rain probability of the day (observed hours 1/0, >= 0.1 mm):
    a lower bound for "some rainy hour", not a calibrated daily >= 1 mm event; null unless all 24 h have one.
    confidence/skill_note: see _day_confidence (AI, by the day's furthest lead hour); observed -> high,
    climatology -> low. Replay is a separately labelled historical reference."""
    sid = _resolve_location(location_id).series_id
    eff = _resolve_at(at, sid)
    now = _naive(eff if eff is not None else _floor_hour(to_local(core.now_local())))
    first = datetime(now.year, now.month, now.day)
    times = [first + timedelta(hours=i) for i in range(days * 24)]
    items = _series(times, _latest_observed(sid), use_forecast=eff is None, sid=sid)
    clim_daily = clim._climatology(_clim_series(sid))[1] if eff is not None else pd.DataFrame()
    evaluation = _own_evaluation(long_range_model.artifact_revision()) if eff is None else None
    forecasts = []
    for d in range(days):
        summary = _daily_summary((first + timedelta(days=d)).date(), items[d * 24:(d + 1) * 24], clim_daily)
        if summary is not None:
            last_lead = (first + timedelta(days=d, hours=23) - now).total_seconds() / 3600
            forecasts.append(_label_confidence(summary, max(1, -(-int(last_lead) // 24)), evaluation))
    if not forecasts:
        raise HTTPException(status_code=404, detail="Chưa có dữ liệu dự báo.")
    return forecasts


@router.get("/bundle")
def get_weather_bundle(
    response: Response,
    hours: int = Query(default=48, ge=1, le=168, description="Number of hours (1-168)"),
    days: int = Query(default=7, ge=1, le=14, description="Number of days (1-14)"),
    at: Optional[str] = Query(default=None, description=AT_DESC),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """/current + /hourly + /daily + /ai-forecast in one call (same handlers, same output).
    An AI 503 does not fail the bundle: ai_forecast = null and ai_error = its detail."""
    loc = _resolve_location(location_id)
    eff = _resolve_at(at, loc.series_id)   # validate `at` once, before any work
    try:
        ai, ai_error = get_ai_forecast(at=at, location_id=location_id), None
    except HTTPException as e:
        if e.status_code != 503:
            raise
        ai, ai_error = None, e.detail
    if eff is None:
        response.headers["Cache-Control"] = "max-age=60"
    forecast_error = None
    try:
        hourly = get_hourly_forecast(hours=hours, at=at, location_id=location_id)
    except HTTPException as e:
        if e.status_code != 503:
            raise
        hourly, forecast_error = [], e.detail
    try:
        daily = get_daily_forecast(days=days, at=at, location_id=location_id)
    except HTTPException as e:
        if e.status_code != 503:
            raise
        daily, forecast_error = [], forecast_error or e.detail
    return {
        "location_id": loc.location_id,
        "cell_id": loc.cell_id,
        "generated_at": to_local(core.now_local()).isoformat(),
        "current": jsonable_encoder(get_current_weather(at=at, location_id=location_id)),
        "hourly": jsonable_encoder(hourly),
        "daily": jsonable_encoder(daily),
        "forecast_provider": "historical_reference" if eff is not None else "sky_weather_ai",
        "forecast_error": forecast_error,
        "ai_forecast": ai,
        "ai_error": ai_error,
    }


@router.get("/history")
def get_historical_weather(
    start_date: str = Query(..., description="Start date (YYYY-MM-DD)"),
    end_date: str = Query(..., description="End date (YYYY-MM-DD)"),
    location_id: Optional[str] = Query(default=None, description=LOCATION_DESC),
):
    """Observed hourly rows of the location's series for a date range (max 365 days)."""
    try:
        start = datetime.strptime(start_date, "%Y-%m-%d")
        end = datetime.strptime(end_date, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(status_code=400, detail="Ngày không hợp lệ; dùng định dạng YYYY-MM-DD.")
    if end < start:
        raise HTTPException(status_code=400, detail="Ngày kết thúc phải sau ngày bắt đầu.")
    if (end - start).days > 365:
        raise HTTPException(status_code=400, detail="Khoảng thời gian không được vượt quá 365 ngày.")
    sid = _resolve_location(location_id).series_id
    rows = execute_query(
        "SELECT * FROM hourly_weather WHERE location_id = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
        (sid, start.strftime("%Y-%m-%d 00:00:00"), end.strftime("%Y-%m-%d 23:59:59")))
    return [row_to_weather_data(row) for row in rows]
