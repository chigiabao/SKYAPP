"""AI serving guards; synthetic inputs and stub boosters, never artifact training."""
import json
import pickle
import sqlite3
from datetime import timedelta
from unittest.mock import Mock

import numpy as np
import pandas as pd
import pytest

import ai_model
import config
from conftest import COLUMNS, LAST_TS, freeze_now
from database import LOCAL_TZ
from routers import weather_ai

TSN_CELL = ai_model.canonical_cell_id("tsn")
OTHER_CELL = "om-8.6819-106.5892"


@pytest.fixture
def predictor(monkeypatch):
    def predict(history, cell_id):
        return {"issued_at": pd.Timestamp(history["timestamp"].iloc[-1]).isoformat(),
                "model_version": "stub-v3",
                "predictions": {f"{h}h": {"temperature": 28.0, "rain_probability": 0.2}
                                for h in ai_model.HORIZONS}}

    stub = Mock(side_effect=predict)
    monkeypatch.setattr(ai_model, "predict_for_location", stub)
    monkeypatch.setattr(weather_ai, "_evaluation", lambda loc: None)
    return stub


@pytest.mark.parametrize("age, status", [(timedelta(0), 200), (timedelta(minutes=59, seconds=59), 200),
                                        (timedelta(hours=1), 503), (timedelta(hours=3), 503),
                                        (timedelta(hours=3, seconds=1), 503),
                                        (timedelta(hours=7), 503), (timedelta(days=365), 503)])
def test_live_input_freshness_boundary(client, monkeypatch, predictor, age, status):
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ) + age)
    response = client.get("/weather/ai-forecast")
    assert response.status_code == status
    if status == 503:
        assert "cũ" in response.json()["detail"]
        predictor.assert_not_called()
    else:
        assert response.json()["forecast_mode"] == "current_inference"
        predictor.assert_called_once()


def test_live_reuses_health_freshness_policy(client, monkeypatch, predictor):
    monkeypatch.setattr(config, "CELL_FRESH_HOURS", 0.5)
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ) + timedelta(minutes=45))
    assert client.get("/weather/ai-forecast").status_code == 503
    predictor.assert_not_called()


def test_live_freshness_is_per_series(client, syn_db, monkeypatch, predictor):
    with sqlite3.connect(syn_db) as con:
        cols = ", ".join(COLUMNS)
        con.execute(f"INSERT INTO hourly_weather ({cols}, location_id) SELECT {cols}, ? "
                    "FROM hourly_weather WHERE location_id = 'tsn' AND timestamp <= ?",
                    (OTHER_CELL, (LAST_TS - timedelta(hours=4)).strftime(weather_ai.TS_FMT)))
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ))
    assert client.get("/weather/ai-forecast").status_code == 200
    predictor.reset_mock()
    response = client.get("/weather/ai-forecast", params={"location_id": OTHER_CELL})
    assert response.status_code == 503
    predictor.assert_not_called()


def test_replay_cannot_bypass_live_freshness(client, monkeypatch, predictor):
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ) + timedelta(days=365))
    replay = client.get("/weather/ai-forecast", params={"at": "2023-06-20T05:00:00Z"})
    assert replay.status_code == 200
    assert replay.json()["forecast_mode"] == "retrospective"
    assert replay.json()["issued_at"] == "2023-06-20T12:00:00+07:00"
    predictor.reset_mock()
    assert client.get("/weather/ai-forecast").status_code == 503
    predictor.assert_not_called()


def test_stale_short_range_ai_is_null_in_bundle(client, predictor):
    response = client.get("/weather/bundle")
    assert response.status_code == 200
    assert response.json()["ai_forecast"] is None
    assert "cũ" in response.json()["ai_error"]
    predictor.assert_not_called()


def test_guarded_verification_replay_is_not_subject_to_live_age(client, monkeypatch, predictor):
    monkeypatch.setattr(ai_model, "verification_cutoff", lambda _: "2023-06-19T00:00:00")
    response = client.get("/weather/ai-verify", params={"at": "2023-06-20T12:00", "retrospective": True})
    assert response.status_code == 200
    assert response.json()["verification_mode"] == "retrospective"
    assert response.json()["issued_at"] == "2023-06-20T12:00:00+07:00"
    predictor.assert_called_once()


def test_live_excludes_future_rows_and_replay_remains_capped(client, monkeypatch, predictor):
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ) - timedelta(hours=1))
    live = client.get("/weather/ai-forecast")
    assert live.status_code == 200
    assert live.json()["issued_at"] == "2023-06-24T22:00:00+07:00"
    replay = client.get("/weather/ai-forecast", params={"at": "2023-06-20T12:00"})
    assert replay.status_code == 200
    assert replay.json()["issued_at"] == "2023-06-20T12:00:00+07:00"
    for call, issue in zip(predictor.call_args_list, ("2023-06-24 22:00:00", "2023-06-20 12:00:00")):
        assert call.args[0]["timestamp"].max() == issue


@pytest.fixture
def policy_artifact(tmp_path, monkeypatch):
    meta = {"model_version": "test-v3", "serving_policy_file": ai_model.POLICY_FILE}
    policy = {"model_version": meta["model_version"],
              "rain_calibration": {f"{h}h": {"method": "none"} for h in ai_model.HORIZONS},
              "fallback": {}}
    files = {"metadata_v3.json": meta, "feature_columns.json": ai_model.feature_columns_v3(),
             "cell_static.json": {c: {k: 0.0 for k in ai_model.STATIC_FEATURES}
                                  for c in (TSN_CELL, OTHER_CELL)}, ai_model.POLICY_FILE: policy}
    for name, value in files.items():
        (tmp_path / name).write_text(json.dumps(value), encoding="utf-8")
    monkeypatch.setattr(ai_model, "V3_DIR", str(tmp_path))
    monkeypatch.setattr(ai_model, "_v3", {})
    return tmp_path, meta, policy


@pytest.mark.parametrize("content", [None, "{", "null", "[]", "{}",
                                    '{"model_version": "another-version"}'])
def test_required_policy_failure_disables_v3_before_loading_boosters(policy_artifact, monkeypatch, content):
    directory, meta, _ = policy_artifact
    path = directory / ai_model.POLICY_FILE
    if content is None:
        path.unlink()
    else:
        path.write_text(content, encoding="utf-8")
    boosters = Mock(side_effect=AssertionError("invalid policy must not load boosters"))
    monkeypatch.setattr(ai_model.joblib, "load", boosters)
    with pytest.raises(ValueError, match="policy"):
        ai_model._load_policy(meta)
    assert not ai_model._load_v3()
    assert "policy" in ai_model._v3["error"]
    assert not ai_model._load_v3()  # the failed load stays closed until cache reset
    boosters.assert_not_called()


@pytest.mark.parametrize("field, value", [
    ("rain_calibration", {}), ("rain_calibration", None),
    ("rain_calibration", {"1h": {"method": "none"}}),
    ("rain_calibration", {f"{h}h": {"method": "magic"} for h in ai_model.HORIZONS}),
    ("fallback", None), ("fallback", []), ("fallback", {OTHER_CELL: []}),
    ("fallback", {OTHER_CELL: {"2h": {"rain_weight": 0.5}}}),
    ("fallback", {OTHER_CELL: {"1h": {"temperature_weight": -0.1}}}),
    ("fallback", {OTHER_CELL: {"1h": {"rain_weight": 1.1}}}),
    ("fallback", {OTHER_CELL: {"1h": {"rain_weight": float("nan")}}}),
    ("fallback", {OTHER_CELL: {"1h": {"rain_weight": "invalid"}}}),
    ("selection_rule", []), ("selection_rule", {"booster_source": []}),
    ("booster_source", {"rain_1h": None}),
])
def test_policy_schema_rejects_corrupt_rules(policy_artifact, field, value):
    directory, meta, policy = policy_artifact
    policy[field] = value
    (directory / ai_model.POLICY_FILE).write_text(json.dumps(policy), encoding="utf-8")
    with pytest.raises(ValueError, match="policy"):
        ai_model._load_policy(meta)


@pytest.mark.parametrize("calibration", [
    {}, None, {"method": "platt", "a": float("inf"), "b": 0},
    {"method": "isotonic", "x": [], "y": []},
    {"method": "isotonic", "x": [0, 1], "y": [0]},
    {"method": "isotonic", "x": [0, 0], "y": [0, 1]},
    {"method": "isotonic", "x": [1, 0], "y": [0, 1]},
    {"method": "isotonic", "x": [0, 1], "y": [1, 0]},
    {"method": "isotonic", "x": [0, 1], "y": [0, float("nan")]},
    {"method": "isotonic", "x": [[0, 1]], "y": [[0, 1]]},
    {"method": "isotonic", "x": [0, 1], "y": [0, 2]},
])
def test_policy_rejects_invalid_calibration(policy_artifact, calibration):
    directory, meta, policy = policy_artifact
    policy["rain_calibration"]["1h"] = calibration
    (directory / ai_model.POLICY_FILE).write_text(json.dumps(policy), encoding="utf-8")
    with pytest.raises(ValueError, match="policy"):
        ai_model._load_policy(meta)


@pytest.mark.parametrize("calibration", [{"method": "none"}, {"method": "platt", "a": 1.0, "b": 0.0},
                                       {"method": "isotonic", "x": [0, 1], "y": [0, 0.5]}])
def test_valid_policy_is_loaded_and_applied(policy_artifact, monkeypatch, syn_db, calibration):
    directory, meta, policy = policy_artifact
    policy["rain_calibration"]["1h"] = calibration
    policy["fallback"] = {OTHER_CELL: {"1h": {"temperature_weight": 0.25}}}
    (directory / ai_model.POLICY_FILE).write_text(json.dumps(policy), encoding="utf-8")
    assert ai_model._load_policy(meta) == policy
    booster = Mock()
    booster.predict.return_value = np.array([0.2])
    monkeypatch.setattr(ai_model.joblib, "load", Mock(return_value=booster))
    monkeypatch.setattr(ai_model, "_load_v3_ext", lambda: None)
    assert ai_model._load_v3()
    history = ai_model.load_history_from_db(str(syn_db))
    result = ai_model.predict_for_location(history, OTHER_CELL)
    assert result["model_version"] == meta["model_version"]
    assert result["predictions"]["1h"]["temperature"] == round(
        0.25 * 0.2 + 0.75 * history["temperature"].iloc[-1], 2)
    expected_prob = float(ai_model.calibrate_rain([0.2], calibration)[0])
    assert result["predictions"]["1h"]["rain_probability"] == pytest.approx(expected_prob)


@pytest.mark.parametrize("v3_ready", [False, True])
@pytest.mark.parametrize("cell", [OTHER_CELL, "unknown-cell", None])
def test_non_tsn_never_uses_v2(monkeypatch, cell, v3_ready):
    monkeypatch.setattr(ai_model, "_load_v3", lambda: v3_ready)
    monkeypatch.setattr(ai_model, "_v3", {"static": {TSN_CELL: {}}})
    v2 = Mock(side_effect=AssertionError("TSN model must not serve another cell"))
    monkeypatch.setattr(ai_model, "predict_from_history", v2)
    with pytest.raises(ValueError, match="v2 supports TSN only"):
        ai_model.predict_for_location(pd.DataFrame(), cell)
    v2.assert_not_called()


@pytest.mark.parametrize("cell", ["tsn", TSN_CELL])
def test_required_policy_failure_allows_only_explicit_tsn_v2(policy_artifact, monkeypatch, cell):
    directory, _, _ = policy_artifact
    (directory / ai_model.POLICY_FILE).unlink()
    expected = {"model_version": "stub-v2"}
    v2 = Mock(return_value=expected)
    monkeypatch.setattr(ai_model, "predict_from_history", v2)
    assert ai_model.predict_for_location(pd.DataFrame(), cell) == expected
    assert not ai_model._v3["ok"]
    v2.assert_called_once()


def test_required_policy_failure_is_503_for_other_cell(client, syn_db, monkeypatch, policy_artifact):
    directory, _, _ = policy_artifact
    (directory / ai_model.POLICY_FILE).unlink()
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ))
    with sqlite3.connect(syn_db) as con:
        cols = ", ".join(COLUMNS)
        con.execute(f"INSERT INTO hourly_weather ({cols}, location_id) SELECT {cols}, ? "
                    "FROM hourly_weather WHERE location_id = 'tsn'", (OTHER_CELL,))
    v2 = Mock(side_effect=AssertionError("other cells cannot use v2"))
    monkeypatch.setattr(ai_model, "predict_from_history", v2)
    response = client.get("/weather/ai-forecast", params={"location_id": OTHER_CELL})
    assert response.status_code == 503
    assert response.json()["detail"] == weather_ai._ai_error_message(ValueError("v3 model unavailable"))
    assert "TSN" not in response.json()["detail"]   # raw exception text is logged, never returned
    v2.assert_not_called()


@pytest.mark.parametrize("error", [FileNotFoundError("missing"), OSError("unreadable"),
                                    RuntimeError("bad booster"), EOFError("truncated"),
                                    pickle.UnpicklingError("corrupt")])
def test_missing_or_corrupt_v2_does_not_break_weather_bundle(client, monkeypatch, error):
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ))
    monkeypatch.setattr(ai_model, "_load_v3", lambda: False)
    monkeypatch.setattr(ai_model, "predict_from_history", Mock(side_effect=error))
    response = client.get("/weather/ai-forecast")
    assert response.status_code == 503
    assert response.json()["detail"] == weather_ai.MSG_AI_UNAVAILABLE
    bundle = client.get("/weather/bundle")
    assert bundle.status_code == 200
    assert bundle.json()["current"] is not None
    assert bundle.json()["ai_forecast"] is None
    assert bundle.json()["ai_error"] == weather_ai.MSG_AI_UNAVAILABLE


def test_failed_v2_load_never_caches_a_partial_model(client, monkeypatch, tmp_path):
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ))
    monkeypatch.setattr(ai_model, "_load_v3", lambda: False)
    monkeypatch.setattr(ai_model, "MODEL_DIR", str(tmp_path))
    monkeypatch.setattr(ai_model, "_models", {})
    monkeypatch.setattr(ai_model, "_meta", {})
    (tmp_path / "feature_columns.json").write_text(json.dumps(ai_model.feature_columns()), encoding="utf-8")
    loader = Mock(side_effect=[Mock(), FileNotFoundError("missing booster")])
    monkeypatch.setattr(ai_model.joblib, "load", loader)
    assert client.get("/weather/ai-forecast").status_code == 503
    assert ai_model._models == {}
    loader.side_effect = FileNotFoundError("missing booster")
    assert client.get("/weather/ai-forecast").status_code == 503
    assert ai_model._models == {}
