"""API contract on the synthetic DB with a frozen clock (2024-06-10 14:23 +07:00)."""
from datetime import datetime, timedelta

import pytest

from conftest import FROZEN_NOW, LAST_TS, WMO_CODES, ZERO_TS, freeze_now
from database import LOCAL_TZ

WEATHER_FIELDS = {"timestamp", "temperature", "humidity", "dew_point", "apparent_temperature",
                  "precipitation_probability", "precipitation", "rain", "weather_code", "visibility",
                  "cloud_cover", "surface_pressure", "pressure_msl", "wind_speed", "wind_direction",
                  "wind_gusts", "rain_probability", "precipitation_median", "source",
                  "uv_index", "us_aqi", "pm2_5", "pm10"}
DAILY_FIELDS = {"date", "temperature_min", "temperature_max", "temperature_avg", "humidity_avg",
                "precipitation_total", "weather_code", "wind_speed_max", "cloud_cover_avg",
                "rain_day_probability", "precipitation_median", "wind_gusts_max", "source",
                "uv_index_max", "us_aqi_max"}
ZERO_FIELDS = ("precipitation", "rain", "weather_code", "cloud_cover", "wind_direction", "wind_speed",
               "temperature", "precipitation_probability", "wind_gusts")


def _ts(s: str) -> datetime:
    assert s.endswith("+07:00"), s
    return datetime.fromisoformat(s)


def test_root_and_locations(client):
    assert client.get("/").status_code == 200
    r = client.get("/locations/current")
    assert r.status_code == 200 and r.json()["timezone"] == "Asia/Ho_Chi_Minh"
    r = client.get("/locations/")
    assert r.status_code == 200 and len(r.json()) == 169
    assert any(x["id"] == "tsn" for x in r.json())


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "healthy" and body["database"] == "ok"
    assert _ts(body["timestamp"]) == FROZEN_NOW
    assert _ts(body["latest_timestamp"]) == LAST_TS.replace(tzinfo=LOCAL_TZ)
    expected_age = round((FROZEN_NOW - LAST_TS.replace(tzinfo=LOCAL_TZ)).total_seconds() / 3600, 1)
    assert body["data_age_hours"] == expected_age


def test_current_contract_and_zeros(client):
    r = client.get("/weather/current")
    assert r.status_code == 200
    body = r.json()
    assert set(body) == WEATHER_FIELDS
    assert _ts(body["timestamp"]) == LAST_TS.replace(tzinfo=LOCAL_TZ)
    for f in ZERO_FIELDS:
        assert body[f] == 0, f"{f} lost its zero: {body[f]!r}"
    assert body["weather_code"] in WMO_CODES
    assert body["rain_probability"] is None and body["precipitation_median"] is None


def test_history_zeros_survive(client):
    r = client.get("/weather/history", params={"start_date": "2023-06-15", "end_date": "2023-06-15"})
    assert r.status_code == 200
    rows = {_ts(x["timestamp"]): x for x in r.json()}
    row = rows[ZERO_TS.replace(tzinfo=LOCAL_TZ)]
    for f in ZERO_FIELDS:
        assert row[f] == 0, f"{f} lost its zero: {row[f]!r}"


@pytest.mark.parametrize("hours", [1, 24, 168])
def test_hourly_contract(client, hours):
    r = client.get("/weather/hourly", params={"hours": hours})
    assert r.status_code == 200
    items = r.json()
    assert len(items) == hours
    start = FROZEN_NOW.replace(minute=0, second=0, microsecond=0)
    for i, item in enumerate(items):
        assert set(item) == WEATHER_FIELDS
        ts = _ts(item["timestamp"])
        assert ts == start + timedelta(hours=i)
        assert (ts.minute, ts.second, ts.microsecond) == (0, 0, 0)
        assert isinstance(item["temperature"], float)
        assert 0 <= item["rain_probability"] <= 1
        assert isinstance(item["precipitation_median"], (int, float)) and item["precipitation_median"] >= 0
        assert item["weather_code"] in WMO_CODES


def test_hourly_default_is_24(client):
    assert len(client.get("/weather/hourly").json()) == 24


def test_hourly_starts_at_current_hour_across_midnight(client, monkeypatch):
    now = datetime(2024, 6, 12, 23, 59, 59, tzinfo=LOCAL_TZ)
    freeze_now(monkeypatch, now)
    items = client.get("/weather/hourly", params={"hours": 3}).json()
    assert [_ts(x["timestamp"]) for x in items] == [
        datetime(2024, 6, 12, 23, tzinfo=LOCAL_TZ),
        datetime(2024, 6, 13, 0, tzinfo=LOCAL_TZ),
        datetime(2024, 6, 13, 1, tzinfo=LOCAL_TZ),
    ]


@pytest.mark.parametrize("days", [1, 7, 14])
def test_daily_contract(client, days):
    r = client.get("/weather/daily", params={"days": days})
    assert r.status_code == 200
    items = r.json()
    assert len(items) == days
    for i, item in enumerate(items):
        assert set(item) == DAILY_FIELDS
        assert item["date"] == (FROZEN_NOW.date() + timedelta(days=i)).isoformat()
        assert 0 <= item["rain_day_probability"] <= 1
        assert item["precipitation_median"] >= 0
        assert item["temperature_min"] <= item["temperature_avg"] <= item["temperature_max"]
        assert item["weather_code"] in WMO_CODES


def test_history_contract(client):
    r = client.get("/weather/history", params={"start_date": "2023-06-11", "end_date": "2023-06-13"})
    assert r.status_code == 200
    items = r.json()
    assert len(items) == 72
    prev = None
    for item in items:
        assert set(item) == WEATHER_FIELDS
        ts = _ts(item["timestamp"])
        if prev is not None:
            assert ts - prev == timedelta(hours=1)
        prev = ts
        assert item["weather_code"] in WMO_CODES


def test_hourly_outside_climatology_is_404(client, monkeypatch):
    freeze_now(monkeypatch, datetime(2024, 1, 15, 12, tzinfo=LOCAL_TZ))  # January: no synthetic data
    assert client.get("/weather/hourly").status_code == 404
    assert client.get("/weather/daily").status_code == 404
