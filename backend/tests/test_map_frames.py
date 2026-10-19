"""Map frames use own AI only; stored external forecasts are never a fallback."""
import sqlite3
import time
from datetime import datetime, timedelta
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

import main
from conftest import REAL_DB, point_app_at
from database import LOCAL_TZ
from routers import weather

OTHER = "om-10.3691-107.0976"   # Vung Tau cell (series_id == cell_id)
NWP_COLS = ("location_id", "issued_at", "timestamp", "temperature", "weather_code", "precipitation",
            "precipitation_probability", "wind_speed", "wind_direction", "wind_gusts")


@pytest.fixture(autouse=True)
def no_own_model(monkeypatch):
    def unavailable(*args, **kwargs):
        raise ValueError("untrained: synthetic unavailable model")
    monkeypatch.setattr(weather.long_range_model, "predict", unavailable)
    monkeypatch.setattr(weather.long_range_model, "status", lambda: {
        "status": "untrained", "cell_ids": [], "trained_through": None,
    })
    monkeypatch.setattr(weather.long_range_model, "artifact_revision", lambda: ("map-test", 1), raising=False)
    weather.invalidate_climatology()
    yield
    weather.invalidate_climatology()


@pytest.fixture
def own_model(no_own_model, monkeypatch):
    def predict(history, cell_id):
        assert cell_id == OTHER
        issue = datetime.fromisoformat(str(history.timestamp.iloc[-1])).replace(tzinfo=LOCAL_TZ)
        return {
            "issued_at": issue.isoformat(),
            "predictions": {f"{h}h": {
                "temperature": round(25 + h / 10, 1), "rain_probability": min(h / 10, 0.9),
                "humidity": 70.0, "precipitation_mm": float(h),
                "wind_speed": float(5 + h), "cloud_cover": 90.0,
            } for h in range(1, 169)},
        }
    predictor = Mock(side_effect=predict)
    monkeypatch.setattr(weather.long_range_model, "predict", predictor)
    monkeypatch.setattr(weather.long_range_model, "status", lambda: {
        "status": "available", "cell_ids": [OTHER],
        "trained_through": "2024-06-01T00:00:00+07:00",
    })
    return predictor


@pytest.fixture
def real_client(monkeypatch):
    if not REAL_DB.exists():
        pytest.skip("real weather.db not found")
    point_app_at(monkeypatch, REAL_DB)
    # No lifespan: a read-only contract check must not migrate or warm the real DB.
    yield TestClient(main.app)


def _nwp(db, rows):
    with sqlite3.connect(db) as con:
        con.executemany(f"INSERT INTO nwp_forecast ({', '.join(NWP_COLS)}) VALUES ({', '.join('?' * len(NWP_COLS))})",
                        rows)
        con.commit()
    con.close()


def _seed(db):
    # Frozen now = 2024-06-10 14:00. Old issue (06:00) must never be used; new issue (12:00) runs to 20:00.
    with sqlite3.connect(db) as con:
        con.execute("INSERT INTO hourly_weather (location_id, timestamp, temperature, weather_code, precipitation, "
                    "wind_speed, wind_direction, wind_gusts) VALUES (?, '2024-06-10 14:00:00', 31.2, 2, 0.0, "
                    "12.34, 225.4, 30.06)", (OTHER,))
        con.commit()
    con.close()
    old = [(OTHER, "2024-06-10 06:00:00", f"2024-06-10 {h}:00:00", 20.0, 0, 0.0, 0.0, 1.0, 0.0, 2.0)
           for h in range(15, 21)]
    new = [(OTHER, "2024-06-10 12:00:00", f"2024-06-10 {h}:00:00", 25.0 + h / 10, 63 if h == 16 else 3,
            float(h - 14), 10.0 * (h - 14), 5.0 + h, 90.0, 20.0 + h) for h in range(13, 21)]
    _nwp(db, old + new)


def test_offset0_observed_with_wind(client, syn_db):
    _seed(syn_db)
    cells = {c["cell_id"]: c for c in client.get("/weather/map").json()}
    vt = cells[OTHER]
    assert vt["source"] == "observed" and vt["observed_at"].startswith("2024-06-10T14:00")
    assert vt["valid_time"] == "2024-06-10T14:00:00+07:00"
    assert (vt["wind_speed"], vt["wind_direction"], vt["wind_gusts"]) == (12.3, 225.0, 30.1)
    assert vt["temperature"] == 31.2 and vt["precipitation"] == 0.0
    # Even a complete newest NWP issue cannot replace our unavailable model.
    assert vt["precipitation_next_3h"] is None and vt["rain_probability_next_3h"] is None
    assert vt["outlook_source"] is None and vt["alert"] is False
    # Cells without data: numbers and source null (old fields unchanged).
    empty = next(c for c in cells.values() if c["observed_at"] is None)
    assert empty["source"] is None and empty["wind_speed"] is None and empty["temperature"] is None


def test_offset_uses_own_model_not_latest_nwp(client, syn_db, own_model):
    _seed(syn_db)
    r = client.get("/weather/map", params={"offset_hours": 2})
    assert r.status_code == 200
    cells = {c["cell_id"]: c for c in r.json()}
    assert len(cells) == 67
    vt = cells[OTHER]   # t = 16:00, horizon 2 of our 14:00 issue
    assert vt["source"] == "ai" and vt["valid_time"] == "2024-06-10T16:00:00+07:00"
    assert vt["observed_at"] is None
    assert vt["temperature"] == 25.2 and vt["weather_code"] == 3 and vt["precipitation"] == 2.0
    assert (vt["wind_speed"], vt["wind_direction"], vt["wind_gusts"]) == (7.0, None, None)
    # Outlook t+1..t+3 = 17..19 h: 3+4+5 mm, max prob 0.5; >= 10 mm -> alert.
    assert vt["precipitation_next_3h"] == 12.0 and vt["rain_probability_next_3h"] == 0.5
    assert vt["outlook_source"] == "ai" and vt["alert"] is True
    own_model.assert_called_once()
    # Cells with no own model input: no frame.
    other = [c for c in cells.values() if c["cell_id"] != OTHER]
    assert all(c["source"] is None and c["temperature"] is None for c in other)


@pytest.mark.parametrize("offset", [2, 10])
def test_nwp_frame_ignored_without_own_model(client, syn_db, offset):
    _seed(syn_db)
    vt = {c["cell_id"]: c for c in client.get("/weather/map", params={"offset_hours": offset}).json()}[OTHER]
    assert vt["source"] is None and vt["temperature"] is None and vt["precipitation_next_3h"] is None
    assert vt["outlook_source"] is None and vt["wind_direction"] is None and vt["wind_gusts"] is None


def test_meta(client, syn_db):
    assert client.get("/weather/map/meta").json()["max_offset_hours"] == 0
    _seed(syn_db)
    meta = client.get("/weather/map/meta").json()
    assert meta == {"now": "2024-06-10T14:00:00+07:00", "max_offset_hours": 0,
                    "issued_at": None, "forecast_source": "ai"}
    items = client.get("/weather/map").json()
    assert {c["max_offset_hours"] for c in items} == {0}


def test_meta_capped_at_72(client, syn_db, own_model):
    assert client.get("/weather/map/meta").json()["max_offset_hours"] == 0
    _seed(syn_db)
    _nwp(syn_db, [(OTHER, "2024-06-10 12:00:00", "2024-06-20 00:00:00") + (None,) * 7])
    meta = client.get("/weather/map/meta").json()
    assert meta["max_offset_hours"] == 72
    assert meta["issued_at"] == "2024-06-10T14:00:00+07:00"
    assert meta["forecast_source"] == "ai"
    frame = client.get("/weather/map", params={"offset_hours": 72}).json()
    vt = next(c for c in frame if c["cell_id"] == OTHER)
    assert vt["source"] == vt["outlook_source"] == "ai"
    assert vt["valid_time"] == (datetime(2024, 6, 10, 14, tzinfo=LOCAL_TZ) + timedelta(hours=72)).isoformat()


def test_replay_with_offset_rejected(client, syn_db):
    at = "2023-06-20T12:00"
    r = client.get("/weather/map", params={"at": at, "offset_hours": 1})
    assert r.status_code == 400 and "xem lại" in r.json()["detail"]
    ok = client.get("/weather/map", params={"at": at, "offset_hours": 0})
    assert ok.status_code == 200
    assert client.get("/weather/map/meta", params={"at": at}).json()["max_offset_hours"] == 0


def test_offset_bounds(client, syn_db):
    for bad in (-1, 73, "x"):
        assert client.get("/weather/map", params={"offset_hours": bad}).status_code == 422
    for good in (0, 72):
        assert client.get("/weather/map", params={"offset_hours": good}).status_code == 200


def test_real_db_frame_speed(real_client):
    for off in (0, 1, 24, 72):
        real_client.get("/weather/map", params={"offset_hours": off})   # warm
        t = time.perf_counter()
        r = real_client.get("/weather/map", params={"offset_hours": off})
        assert r.status_code == 200 and len(r.json()) == 67
        assert time.perf_counter() - t < 0.3


def test_meta_rejects_fresh_but_invalid_model_input(client, syn_db, own_model):
    _seed(syn_db)
    own_model.side_effect = ValueError('invalid_history: need >=48 distinct hourly rows')
    meta = client.get('/weather/map/meta').json()
    assert meta['max_offset_hours'] == 0
    assert meta['issued_at'] is None
    frame = client.get('/weather/map', params={'offset_hours': 1}).json()
    assert all(cell['source'] is None and cell['max_offset_hours'] == 0 for cell in frame)


def test_replay_cache_rechecks_guard_after_revision(monkeypatch):
    now = datetime(2024, 6, 10, 14)
    series = ((OTHER, OTHER),)
    monkeypatch.setattr(weather.ai_model, 'load_history_from_db', lambda **kwargs: [None] * 48)
    predictor = Mock(return_value={
        'issued_at': now.replace(tzinfo=LOCAL_TZ).isoformat(),
        'predictions': {f'{h}h': {'rain_probability': 0.7} for h in (1, 2, 3)},
    })
    monkeypatch.setattr(weather.long_range_model, 'predict', predictor)
    assert weather._replay_ai_rain(now, series, ('model', 1, 'db', 1)) == {OTHER: 0.7}
    predictor.side_effect = ValueError('replay_leakage: new training cutoff')
    assert weather._replay_ai_rain(now, series, ('model', 2, 'db', 1)) == {}
    assert weather._replay_ai_rain(now, series, ('model', 2, 'db', 2)) == {}
    assert predictor.call_count == 3
