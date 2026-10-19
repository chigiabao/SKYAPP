"""Smoke/contract tests against the real backend/data/weather.db (marked realdb)."""
import sqlite3
from datetime import datetime, timedelta

import pandas as pd
import pytest

import ai_model
from conftest import REAL_DB, WMO_CODES
from database import now_local

pytestmark = pytest.mark.realdb


def test_health_real(real_client):
    body = real_client.get("/health").json()
    assert body["status"] == "healthy"
    assert body["latest_timestamp"].endswith("+07:00")
    assert isinstance(body["data_age_hours"], float)


def test_current_real(real_client):
    body = real_client.get("/weather/current").json()
    assert body["timestamp"].endswith("+07:00")
    assert body["weather_code"] in WMO_CODES


def test_hourly_real_starts_at_current_hcmc_hour(real_client):
    before = now_local().replace(minute=0, second=0, microsecond=0)
    response = real_client.get('/weather/hourly', params={'hours': 168})
    if response.status_code == 503:
        assert isinstance(response.json()['detail'], str)
        return  # Missing/stale model input must not silently become external/climatology.
    assert response.status_code == 200
    items = response.json()
    after = now_local().replace(minute=0, second=0, microsecond=0)
    first = datetime.fromisoformat(items[0]["timestamp"])
    assert first in (before, after)
    assert len(items) == 168
    for prev, cur in zip(items, items[1:]):
        assert datetime.fromisoformat(cur["timestamp"]) - datetime.fromisoformat(prev["timestamp"]) == timedelta(hours=1)
    for it in items:
        assert it["timestamp"].endswith("+07:00")
        assert 0 <= it["rain_probability"] <= 1
        if it['source'] == 'ai':
            assert it['precipitation_median'] is None
            assert it['wind_gusts'] is None and it['uv_index'] is None
        else:
            assert it['source'] == 'observed'
        assert it["weather_code"] in WMO_CODES


def test_daily_real(real_client):
    response = real_client.get('/weather/daily', params={'days': 7})
    if response.status_code == 503:
        assert isinstance(response.json()['detail'], str)
        return
    assert response.status_code == 200
    items = response.json()
    assert len(items) == 7
    for it in items:
        assert it['source'] in ('observed', 'ai')
        if it['source'] == 'ai':
            assert it['rain_day_probability'] is None
            assert it['precipitation_median'] is None
        else:
            assert 0 <= it['rain_day_probability'] <= 1
        assert it["weather_code"] in WMO_CODES


def test_ai_forecast_real(real_client):
    r = real_client.get("/weather/ai-forecast")
    assert r.status_code == 200
    body = r.json()
    with sqlite3.connect(REAL_DB) as con:
        latest = con.execute("SELECT MAX(timestamp) FROM hourly_weather").fetchone()[0]
    con.close()
    assert body["issued_at"] == pd.Timestamp(latest).isoformat() + "+07:00"
    assert set(body["predictions"]) == {"1h", "3h", "6h"}
    for p in body["predictions"].values():
        assert isinstance(p["temperature"], float) and 15 < p["temperature"] < 45
        assert 0 <= p["rain_probability"] <= 1


def test_no_future_leak_real(real_db_copy):
    t = datetime(2026, 10, 1, 12)
    a = ai_model.predict_from_history(ai_model.load_history_from_db(str(REAL_DB), until=t))
    with sqlite3.connect(real_db_copy) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp > ?", (t.strftime("%Y-%m-%d %H:%M:%S"),))
    con.close()
    b = ai_model.predict_from_history(ai_model.load_history_from_db(str(real_db_copy), until=t))
    assert a == b and a["issued_at"] == t.isoformat()
