"""Verification provenance and training-script invariants; never train a fixture model."""
import ast
import inspect
import sqlite3
from datetime import datetime, timedelta
from unittest.mock import Mock

import numpy as np
import pandas as pd
import pytest

import ai_model
from database import LOCAL_TZ
from routers import weather_ai, weather_core
from scripts import train_global_v3_ext as ext
from scripts import train_global_v3_interval as interval

ISSUE = datetime(2023, 6, 20, 12)
AT = ISSUE.isoformat()


def archive(db, issue=ISSUE, source="ai", series="tsn", version="stored-v1", horizons=(1, 3, 6)):
    with sqlite3.connect(db) as con:
        con.executemany("INSERT INTO ai_forecast_log (series_id, source, issued_at, horizon_h, target_time, "
                        "temperature, rain_probability, precipitation, alert, model_version, logged_at) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
            (series, source, issue.strftime(weather_core.TS_FMT), h,
             (issue + timedelta(hours=h)).strftime(weather_core.TS_FMT), 30.0 + h, 0.2,
             None, None, version, (issue + timedelta(minutes=5)).strftime(weather_core.TS_FMT)) for h in horizons])


@pytest.fixture
def no_inference(monkeypatch):
    fail = Mock(side_effect=AssertionError("verification must not recompute"))
    monkeypatch.setattr(weather_ai, "_ai_issue", fail)
    monkeypatch.setattr(weather_ai, "_evaluation", fail)
    monkeypatch.setattr(ai_model, "verification_cutoff", fail)
    return fail


def test_archived_issue_survives_model_replacement(client, syn_db, monkeypatch, no_inference):
    archive(syn_db)
    a = client.get("/weather/ai-verify", params={"at": AT}).json()
    monkeypatch.setattr(ai_model, "_v3", {"meta": {"model_version": "replacement-v99"}})
    monkeypatch.setattr(ai_model, "predict_for_location", no_inference)
    b = client.get("/weather/ai-verify", params={"at": AT, "retrospective": True}).json()
    assert a == b
    assert a["verification_mode"] == "archived" and a["forecast_source"] == "ai_forecast_log"
    assert a["actual_source"] == "open_meteo_analysis"
    assert a["evaluation"] is None and a["evaluation_source"] == "not_archived"
    assert a["interval_source"] == "not_archived" and a["archived_at"].endswith("12:05:00+07:00")
    assert a["model_version"] == "stored-v1"
    assert [h["predicted_temperature"] for h in a["horizons"]] == [31.0, 33.0, 36.0]
    for h in a["horizons"]:
        assert h["abs_error_temperature"] == round(abs(h["predicted_temperature"] - h["actual_temperature"]), 2)
    no_inference.assert_not_called()


@pytest.mark.parametrize("missing_table", [False, True])
def test_missing_archive_is_a_compatible_empty_response(client, syn_db, no_inference, missing_table):
    if missing_table:
        with sqlite3.connect(syn_db) as con:
            con.execute("DROP TABLE ai_forecast_log")
    response = client.get("/weather/ai-verify", params={"at": AT})
    assert response.status_code == 200
    body = response.json()
    assert body["issued_at"] == AT + "+07:00"
    assert body["verification_mode"] == "unavailable" and body["horizons"] == []
    assert body["unavailable_reason"] == "no_archived_forecast" and body["forecast_source"] is None
    no_inference.assert_not_called()


def test_default_uses_latest_eligible_archive_but_explicit_time_is_exact(client, syn_db, monkeypatch, no_inference):
    monkeypatch.setattr(weather_core, "now_local", lambda: datetime(2023, 6, 20, 20, tzinfo=LOCAL_TZ))
    archive(syn_db)
    archive(syn_db, ISSUE + timedelta(hours=3))  # newer than default now-6h
    archive(syn_db, ISSUE + timedelta(hours=1), source="ai_long_range")
    archive(syn_db, ISSUE + timedelta(hours=1), series="different-series")
    body = client.get("/weather/ai-verify").json()
    assert body["issued_at"] == AT + "+07:00"
    assert body["requested_at"].endswith("14:00:00+07:00")
    exact = client.get("/weather/ai-verify", params={"at": "2023-06-20T13:00"}).json()
    assert exact["verification_mode"] == "unavailable"  # no nearest-issue/source substitution


def test_partial_archive_never_fills_missing_horizons(client, syn_db, no_inference):
    archive(syn_db, horizons=(3,))
    body = client.get("/weather/ai-verify", params={"at": AT}).json()
    assert [h["horizon"] for h in body["horizons"]] == ["3h"]


def test_missing_default_archive_does_not_require_inference_history(client, syn_db, no_inference):
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather")
    response = client.get("/weather/ai-verify")
    assert response.status_code == 200
    assert response.json()["verification_mode"] == "unavailable"
    no_inference.assert_not_called()


@pytest.mark.parametrize("history", ["removed", "trimmed"])
def test_exact_archive_does_not_require_retained_inference_history(client, syn_db, no_inference, history):
    archive(syn_db)
    with sqlite3.connect(syn_db) as con:
        if history == "removed":
            con.execute("DELETE FROM hourly_weather")
        else:
            con.execute("DELETE FROM hourly_weather WHERE timestamp < ?", (ISSUE.strftime(weather_core.TS_FMT),))
    response = client.get("/weather/ai-verify", params={"at": AT})
    assert response.status_code == 200
    body = response.json()
    assert body["verification_mode"] == "archived" and body["model_version"] == "stored-v1"
    assert [h["predicted_temperature"] for h in body["horizons"]] == [31.0, 33.0, 36.0]
    assert all((h["actual_temperature"] is None) == (history == "removed") for h in body["horizons"])
    no_inference.assert_not_called()


@pytest.mark.parametrize("assignment", ["model_version = NULL", "temperature = NULL", "rain_probability = 2",
                                        "target_time = '2023-06-20 22:00:00'", "model_version = 'mixed'"])
def test_corrupt_archive_fails_closed(client, syn_db, no_inference, assignment):
    archive(syn_db)
    with sqlite3.connect(syn_db) as con:
        con.execute(f"UPDATE ai_forecast_log SET {assignment} WHERE horizon_h = 3")
    body = client.get("/weather/ai-verify", params={"at": AT, "retrospective": True}).json()
    assert body["verification_mode"] == "unavailable" and body["horizons"] == []
    assert body["unavailable_reason"] == "invalid_archived_forecast"


@pytest.mark.parametrize("cutoff", ["2024-06-30T23:00", AT, "2023-06-20T13:00"])
def test_retrospective_dates_not_after_cutoff_never_predict(client, monkeypatch, cutoff):
    predictor = Mock(side_effect=AssertionError("in-selection replay must not run"))
    monkeypatch.setattr(weather_ai, "_ai_issue", predictor)
    monkeypatch.setattr(ai_model, "verification_cutoff", lambda _: cutoff)
    body = client.get("/weather/ai-verify", params={"at": AT, "retrospective": True}).json()
    assert body["verification_mode"] == "unavailable"
    assert body["unavailable_reason"] == "issue_not_after_selection_cutoff" and body["selection_cutoff"]
    predictor.assert_not_called()


def test_retrospective_unknown_cutoff_fails_closed(client, monkeypatch):
    monkeypatch.setattr(ai_model, "verification_cutoff", Mock(side_effect=ValueError("unknown")))
    body = client.get("/weather/ai-verify", params={"at": AT, "retrospective": True}).json()
    assert body["unavailable_reason"] == "cutoff_unavailable" and body["horizons"] == []


def test_retrospective_is_explicit_and_honestly_labelled(client, monkeypatch):
    monkeypatch.setattr(ai_model, "verification_cutoff", lambda _: "2023-01-01T00:00")
    monkeypatch.setattr(weather_ai, "_ai_issue", lambda until, loc: {
        "issued_at": AT + "+07:00", "model_version": "current-v2", "evaluation": {"cell_id": "tsn"},
        "predictions": {"1h": {"target_time": "2023-06-20T13:00:00+07:00", "temperature": 30.0,
                                "rain_probability": 0.3}}})
    assert client.get("/weather/ai-verify", params={"at": AT}).json()["horizons"] == []
    body = client.get("/weather/ai-verify", params={"at": AT, "retrospective": True}).json()
    assert body["verification_mode"] == "retrospective" and body["forecast_source"] == "current_model_replay"
    assert body["evaluation_source"] == "current_model_test" and body["horizons"]
    assert "archived_at" not in body


def test_stale_history_cannot_bypass_cutoff(client, monkeypatch):
    monkeypatch.setattr(ai_model, "verification_cutoff", lambda _: "2023-12-31T00:00")
    predictor = Mock(side_effect=AssertionError("stale history must not run"))
    monkeypatch.setattr(weather_ai, "_ai_issue", predictor)
    body = client.get("/weather/ai-verify", params={"at": "2024-06-01T00:00", "retrospective": True}).json()
    assert body["unavailable_reason"] == "issue_not_after_selection_cutoff"
    predictor.assert_not_called()


def test_historical_forecast_demonstration_is_labelled_not_issued_verification(client):
    body = client.get("/weather/ai-forecast", params={"at": AT}).json()
    assert body["forecast_mode"] == "retrospective" and body["predictions"]
    live = client.get("/weather/ai-forecast")
    assert live.status_code == 503
    assert "cũ" in live.json()["detail"]


def test_actuals_do_not_leak_future_rows_and_rain_matches_training(client, syn_db, monkeypatch):
    archive(syn_db)
    monkeypatch.setattr(weather_core, "now_local", lambda: datetime(2023, 6, 20, 13, tzinfo=LOCAL_TZ))
    with sqlite3.connect(syn_db) as con:
        con.execute("UPDATE hourly_weather SET precipitation = 0.1 WHERE timestamp = '2023-06-20 13:00:00'")
    body = client.get("/weather/ai-verify", params={"at": AT}).json()
    h1, h3, h6 = body["horizons"]
    assert h1["actual_rain"] is False
    for h in (h3, h6):
        assert h["actual_temperature"] is None and h["actual_rain"] is None and h["abs_error_temperature"] is None


def test_validation_gate_requires_all_horizons_and_no_test_data():
    val = pd.DataFrame({"cell_id": ["a", "b"], "timestamp": pd.to_datetime([AT, AT])})
    cols = ["humidity", "wind_speed", "wind_gusts", "precipitation_mm"]
    clim = pd.DataFrame(10.0, index=pd.MultiIndex.from_product([["a", "b"], [6], [13, 15, 18]]), columns=cols)
    preds = {}
    for n, (src, _, _) in ext.NEW_TARGETS.items():
        val[src] = 10.0
        for h in ai_model.HORIZONS:
            val[f"{n}_target_{h}h"] = 0.0
            preds[f"{n}_{h}h"] = np.zeros(2)
    good = ext.select_new_targets(val, preds, clim)
    assert all(g["enabled"] and g["selection_split"] == "validation" for g in good.values())
    preds["humidity_6h"][1] = 20.0
    assert ext.select_new_targets(val, preds, clim)["humidity"]["enabled"] is False
    preds["wind_speed_3h"][:] = np.nan  # missing comparison is not a win
    assert ext.select_new_targets(val, preds, clim)["wind_speed"]["enabled"] is False


def test_script_selection_and_spatial_reporting_invariants():
    tree = ast.parse(inspect.getsource(ext.main))
    calls = [(n.lineno, ast.unparse(n)) for n in ast.walk(tree) if isinstance(n, ast.Call)]
    gate_line = next(line for line, text in calls if text == "select_new_targets(val, pv, clim)")
    test_line = next(line for line, text in calls if text == "predict(test)")
    assert gate_line < test_line
    gate_names = {n.id for n in ast.walk(ast.parse(inspect.getsource(ext.select_new_targets))) if isinstance(n, ast.Name)}
    assert "test" not in gate_names
    assert interval.SPATIAL_HOLDOUT["status"] == "disabled"
    source = inspect.getsource(interval.main)
    assert '"holdout": dict(SPATIAL_HOLDOUT)' in source
    assert "holdout_cell" not in source and "best_h" not in source and "pth" not in source
    assert source.count("search(") == 1  # no tuning/reporting on a nominal spatial holdout
