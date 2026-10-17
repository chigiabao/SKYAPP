"""AI forecast endpoint: graceful 503s and no look-ahead leakage (synthetic DB)."""
import sqlite3
from datetime import datetime

import pytest

import ai_model
from conftest import LAST_TS, write_db

T = datetime(2023, 6, 20, 12, 0)


def _check_predictions(body):
    assert set(body["predictions"]) == {"1h", "3h", "6h"}
    for p in body["predictions"].values():
        assert isinstance(p["temperature"], float)
        assert 0 <= p["rain_probability"] <= 1


def test_ai_forecast_ok_on_synthetic(client):
    r = client.get("/weather/ai-forecast")
    assert r.status_code == 200
    body = r.json()
    assert body["issued_at"] == LAST_TS.isoformat() + "+07:00"
    _check_predictions(body)


def test_ai_forecast_gap_is_503(client, syn_db):
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp = '2023-06-24 10:00:00'")
    con.close()
    r = client.get("/weather/ai-forecast")
    assert r.status_code == 503
    assert "contiguous" in r.json()["detail"]


def test_ai_forecast_too_little_history_is_503(client, syn_db):
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp < '2023-06-24 00:00:00'")
    con.close()
    assert client.get("/weather/ai-forecast").status_code == 503


def test_ai_forecast_null_feature_is_503(client, syn_db):
    with sqlite3.connect(syn_db) as con:
        con.execute("UPDATE hourly_weather SET wind_gusts = NULL WHERE timestamp = '2023-06-24 23:00:00'")
    con.close()
    assert client.get("/weather/ai-forecast").status_code == 503


def test_no_future_leak(tmp_path, syn_rows):
    full = write_db(tmp_path / "full.db", syn_rows)
    cut = write_db(tmp_path / "cut.db", [r for r in syn_rows if r["timestamp"] <= T.strftime("%Y-%m-%d %H:%M:%S")])

    hist_full = ai_model.load_history_from_db(str(full), until=T)
    hist_cut = ai_model.load_history_from_db(str(cut), until=T)
    assert hist_full.equals(hist_cut)
    assert hist_full["timestamp"].iloc[-1] == "2023-06-20 12:00:00"

    a = ai_model.predict_from_history(hist_full)
    b = ai_model.predict_from_history(hist_cut)
    assert a == b
    assert a["issued_at"] == T.isoformat()
    # sanity: the future rows exist and do change the forecast when they are allowed in
    assert ai_model.predict_from_history(ai_model.load_history_from_db(str(full)))["issued_at"] != a["issued_at"]
