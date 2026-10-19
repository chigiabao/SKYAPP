"""Multi-location contract: location_id on /weather/*, per-series isolation, /weather/map, AI evaluation."""
import sqlite3
from datetime import datetime
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

import main
from conftest import COLUMNS, REAL_DB, point_app_at, synthetic_rows
from database import LOCAL_TZ
from routers import weather

OTHER = "om-10.3691-107.0976"   # Vung Tau cell (series_id == cell_id)
WARD = "phuong-vung-tau"


@pytest.fixture(autouse=True)
def no_own_model(monkeypatch):
    def unavailable(*args, **kwargs):
        raise ValueError("untrained: synthetic unavailable model")
    monkeypatch.setattr(weather.long_range_model, "predict", unavailable)
    monkeypatch.setattr(weather.long_range_model, "status", lambda: {
        "status": "untrained", "cell_ids": [], "trained_through": None,
    })
    monkeypatch.setattr(weather.long_range_model, "artifact_revision", lambda: ("location-test", 1), raising=False)
    weather.invalidate_climatology()
    yield
    weather.invalidate_climatology()


@pytest.fixture
def short_model(monkeypatch):
    def predict(history, cell_id):
        issue = datetime.fromisoformat(str(history.timestamp.iloc[-1])).replace(tzinfo=LOCAL_TZ)
        return {
            "issued_at": issue.isoformat(), "model_version": "synthetic-short-range",
            "predictions": {h: {"temperature": float(history.temperature.iloc[-1]),
                                "rain_probability": 0.4} for h in ("1h", "3h", "6h")},
        }
    predictor = Mock(side_effect=predict)
    monkeypatch.setattr(weather.ai_model, "predict_for_location", predictor)
    return predictor


@pytest.fixture
def real_client(monkeypatch):
    if not REAL_DB.exists():
        pytest.skip("real weather.db not found")
    point_app_at(monkeypatch, REAL_DB)
    # Skip lifespan so read-only checks never migrate or warm the real database.
    yield TestClient(main.app)


def _add_series(db, sid, offset=5.0):
    rows = synthetic_rows()
    for r in rows:
        r["temperature"] = round(r["temperature"] + offset, 1)
    cols = COLUMNS + ["location_id"]
    with sqlite3.connect(db) as con:
        con.executemany(f"INSERT INTO hourly_weather ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
                        [tuple(r[c] for c in COLUMNS) + (sid,) for r in rows])
        con.commit()


def test_unknown_location_404(client):
    for path in ("/weather/current", "/weather/hourly", "/weather/daily", "/weather/ai-forecast"):
        r = client.get(path, params={"location_id": "khong-ton-tai"})
        assert r.status_code == 404, path
        assert "khong-ton-tai" in r.json()["detail"]


def test_default_is_tsn(client):
    a = client.get("/weather/current").json()
    b = client.get("/weather/current", params={"location_id": "tsn"}).json()
    assert a == b


def test_series_are_isolated(client, syn_db):
    _add_series(syn_db, OTHER, offset=5.0)
    tsn = client.get("/weather/current").json()
    ward = client.get("/weather/current", params={"location_id": WARD}).json()
    cell = client.get("/weather/current", params={"location_id": OTHER}).json()
    assert ward == cell
    assert ward["timestamp"] == tsn["timestamp"]
    assert abs(ward["temperature"] - tsn["temperature"] - 5.0) < 0.05


@pytest.mark.parametrize("route", ["hourly", "daily"])
@pytest.mark.parametrize("stale", [False, True])
def test_ward_without_fresh_data_rejects_tsn_climatology_fallback(client, syn_db, monkeypatch, route, stale):
    if stale:
        _add_series(syn_db, OTHER)
    def forbidden(*args, **kwargs):
        raise AssertionError("A missing/stale ward must not borrow tsn climatology")
    monkeypatch.setattr(weather, "_climatology", forbidden)
    r = client.get(f"/weather/{route}", params={"location_id": WARD})
    assert r.status_code == 503
    assert r.json()["detail"]


def test_history_filters_by_location(client, syn_db):
    _add_series(syn_db, OTHER)
    q = {"start_date": "2023-06-10", "end_date": "2023-06-10"}
    assert len(client.get("/weather/history", params=q).json()) == 24
    assert len(client.get("/weather/history", params={**q, "location_id": OTHER}).json()) == 24


def test_map_shape(client, syn_db, short_model):
    _add_series(syn_db, OTHER)
    r = client.get("/weather/map", params={"at": "2023-06-20T12:00"})
    assert r.status_code == 200
    cells = r.json()
    assert len(cells) == 67
    keys = {"cell_id", "lat", "lon", "location_ids", "temperature", "weather_code",
            "rain_probability_next_3h", "precipitation_next_3h", "alert"}
    assert all(keys <= set(c) for c in cells)
    vt = next(c for c in cells if c["cell_id"] == OTHER)
    assert WARD in vt["location_ids"] and vt["temperature"] is not None
    assert isinstance(vt["alert"], bool)


def test_map_replay_never_uses_future_beyond_3h(client, syn_db, short_model):
    at = "2023-06-20T12:00"
    cells = {c["cell_id"]: c for c in client.get("/weather/map", params={"at": at}).json()}
    tsn_cell = next(c for c in cells.values() if "tsn" in c["location_ids"] or c["cell_id"] == "tsn")
    assert tsn_cell["observed_at"].startswith("2023-06-20T12:00")
    # Unavailable guarded own model must not fall back to a legacy model with future-label leakage.
    assert tsn_cell['outlook_source'] is None and tsn_cell['precipitation_next_3h'] is None
    assert tsn_cell['rain_probability_next_3h'] is None
    assert "tsn" in tsn_cell["location_ids"] and "phuong-tan-son-nhat" in tsn_cell["location_ids"]
    assert tsn_cell["cell_id"] == "om-10.7909-106.6313"
    short_model.assert_not_called()


def test_ai_forecast_has_location_and_evaluation(real_client, short_model):
    r = real_client.get("/weather/ai-forecast")
    assert r.status_code == 200
    body = r.json()
    assert body["location_id"] == "tsn" and body["cell_id"] == "tsn"
    ev = body["evaluation"]
    assert ev is None or {"temperature_mae_1h", "beats_baselines", "test_period"} <= set(ev)


def test_ai_forecast_other_cell(real_client, short_model):
    r = real_client.get("/weather/ai-forecast", params={"location_id": WARD})
    assert r.status_code in (200, 503)
    if r.status_code == 200:
        assert r.json()["cell_id"] == OTHER


def _insert_hour(db, sid, ts, temperature=30.0, weather_code=1.0):
    with sqlite3.connect(db) as con:
        con.execute("INSERT INTO hourly_weather (location_id, timestamp, temperature, weather_code) "
                    "VALUES (?, ?, ?, ?)", (sid, ts, temperature, weather_code))
        con.commit()
    con.close()


def test_health_cells(client, syn_db):
    # Frozen now 2024-06-10 14:23: only OTHER has an hour within 3 h; tsn data ends 2023-06-24.
    _insert_hour(syn_db, OTHER, "2024-06-10 13:00:00")
    with sqlite3.connect(syn_db) as con:
        con.execute("INSERT INTO series_status (series_id, status, error) VALUES ('tsn', 'failed', 'API down')")
        n_cells = con.execute("SELECT COUNT(*) FROM cells").fetchone()[0]
        n_tsn = con.execute("SELECT COUNT(*) FROM cells WHERE series_id = 'tsn'").fetchone()[0]
        con.commit()
    con.close()
    body = client.get("/health").json()
    # Old fields still describe the 'tsn' series, not the newest hour of any cell.
    assert body["latest_timestamp"].startswith("2023-06-24T23:00")
    cells = body["cells"]
    assert cells["total"] == n_cells == 68 and cells["fresh"] == 1 and cells["fresh_hours"] == 3
    stale = {c["cell_id"]: c for c in cells["stale"]}
    assert len(stale) == 67 and OTHER not in stale
    tsn_cells = [c for c in stale.values() if c["series_id"] == "tsn"]
    assert len(tsn_cells) == n_tsn >= 1
    assert tsn_cells[0]["status"] == "failed" and tsn_cells[0]["error"] == "API down"
    assert tsn_cells[0]["latest_timestamp"].startswith("2023-06-24T23:00")
    empty = next(c for c in stale.values() if c["series_id"] not in ("tsn", OTHER))
    assert empty["latest_timestamp"] is None and empty["status"] is None


def test_map_live_ignores_latest_nwp_issue_when_own_unavailable(client, syn_db):
    # Live current stays observed; neither NWP issue may become the outlook.
    _insert_hour(syn_db, OTHER, "2024-06-10 14:00:00", temperature=31.2, weather_code=2.0)
    old = [(OTHER, "2024-06-10 06:00:00", f"2024-06-10 {h}:00:00", 0.0, 0.0, 1.0) for h in (15, 16, 17)]
    new = [(OTHER, "2024-06-10 12:00:00", f"2024-06-10 {h}:00:00", p, pp, c)
           for h, p, pp, c in ((14, 50.0, 100.0, 65.0),      # not in the next 3 h
                               (15, 4.0, 60.0, 63.0), (16, 7.0, 80.0, 95.0), (17, 0.5, 30.0, 61.0),
                               (18, 50.0, 100.0, 65.0))]     # after the next 3 h
    with sqlite3.connect(syn_db) as con:
        con.executemany("INSERT INTO nwp_forecast (location_id, issued_at, timestamp, precipitation, "
                        "precipitation_probability, weather_code) VALUES (?, ?, ?, ?, ?, ?)", old + new)
        con.commit()
    con.close()
    r = client.get("/weather/map")
    assert r.status_code == 200
    cells = {c["cell_id"]: c for c in r.json()}
    assert len(cells) == 67
    vt = cells[OTHER]
    assert vt["observed_at"].startswith("2024-06-10T14:00") and vt["temperature"] == 31.2
    assert vt["weather_code"] == 2
    assert vt["source"] == "observed"
    assert vt["precipitation_next_3h"] is None and vt["rain_probability_next_3h"] is None
    assert vt["outlook_source"] is None and vt["alert"] is False
    # Cells without fresh own-model input have no outlook either.
    tsn_cell = next(c for c in cells.values() if "tsn" in c["location_ids"] or c["cell_id"] == "tsn")
    assert tsn_cell["precipitation_next_3h"] is None and tsn_cell["rain_probability_next_3h"] is None
    assert tsn_cell["observed_at"].startswith("2023-06-24T23:00") and tsn_cell["alert"] is False
    future = client.get("/weather/map", params={"offset_hours": 1})
    assert future.status_code == 200
    vt_future = next(c for c in future.json() if c["cell_id"] == OTHER)
    assert vt_future["source"] is None and vt_future["temperature"] is None
    assert vt_future["outlook_source"] is None and vt_future["precipitation_next_3h"] is None
