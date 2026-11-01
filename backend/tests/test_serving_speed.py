"""Serving speed paths must not change served numbers: V3 point-only path, reuse of V3 in monitor, single-flight."""
import threading
import time
from datetime import datetime
from functools import lru_cache
from unittest.mock import Mock

import pandas as pd
import pytest

import ai_model
import long_range_model_v2 as M
from conftest import write_db
from routers import monitor, weather_series
from test_ai_global import needs_v3
from test_long_range_model_v2 import CELL, artifact, history  # noqa: F401 - pytest fixture

T = "2023-06-20 12:00:00"
CELLS = ["tsn", "om-10.7909-106.6313", "om-8.6819-106.5892", "om-11.0018-106.6755"]
POINT_KEYS = {"temperature", "rain_probability", *ai_model.EXT_TARGETS}


@pytest.fixture
def syn_hist(tmp_path, syn_rows):
    ai_model.reset_v3_cache()
    db = write_db(tmp_path / "h.db", syn_rows)
    yield ai_model.load_history_from_db(str(db), until=pd.Timestamp(T).to_pydatetime())
    ai_model.reset_v3_cache()


def test_feature_columns_cached_copy():
    cols = ai_model.feature_columns()
    cols.append("mutated")
    assert "mutated" not in ai_model.feature_columns()
    assert ai_model.feature_columns_v3()[-len(ai_model.STATIC_FEATURES):] == ai_model.STATIC_FEATURES


@needs_v3
@pytest.mark.parametrize("cell", CELLS)
def test_v3_points_equal_full_prediction(syn_hist, cell):
    full = ai_model.predict_for_location(syn_hist, cell)
    points = ai_model.predict_points_v3(syn_hist, cell)
    assert points["model_version"] == full["model_version"] and points["issued_at"] == full["issued_at"]
    assert points["predictions"] == {k: {f: v for f, v in p.items() if f in POINT_KEYS}
                                     for k, p in full["predictions"].items()}
    some = ai_model.predict_points_v3(syn_hist, cell, {"temperature", "humidity"})
    for k, p in some["predictions"].items():
        assert set(p) <= {"temperature", "rain_probability", "humidity"}
        assert p == {f: v for f, v in points["predictions"][k].items() if f in p}


@needs_v3
def test_v3_points_fail_without_v2_fallback(syn_hist):
    with pytest.raises(ValueError):
        ai_model.predict_points_v3(syn_hist, "om-unknown")
    with pytest.raises(ValueError):
        ai_model.predict_points_v3(syn_hist.iloc[-20:], CELLS[1])


@needs_v3
def test_monitor_batch_points_equal_v3_component(syn_hist):
    out = monitor._predict_all([("a", CELLS[1], syn_hist), ("b", CELLS[2], syn_hist)])
    points = {sid: res.pop("v3_points") for sid, res in out.items()}
    assert set(points) == {"a", "b"}
    for sid, cell in (("a", CELLS[1]), ("b", CELLS[2])):
        assert points[sid] == ai_model.predict_points_v3(syn_hist, cell)
        ref = M.v3_component(syn_hist, cell)
        assert {h: {f: v for f, v in p.items() if f in M.TARGETS} for h, p in M.v3_values(points[sid]).items()} == ref


def test_v2_predict_reuses_given_v3_result(artifact, monkeypatch):  # noqa: F811 - fixture
    lookup = Mock(side_effect=ValueError("V3 must not run again"))
    monkeypatch.setattr(ai_model, "predict_points_v3", lookup)
    v3 = {"model_version": "lgbm-hcmc-global-v3-test",
          "predictions": {f"{h}h": {"temperature": 99.0, "rain_probability": 0.5} for h in (1, 3, 6)}}
    reused = M.predict(history(), CELL, v3_result=v3)
    lookup.assert_not_called()
    assert reused["policy_fallbacks"] == []
    computed = M.predict(history(), CELL)
    lookup.assert_called_once()
    assert computed["policy_fallbacks"] == ["v3_unavailable: ValueError"]
    v2_1h = computed["predictions"]["1h"]["temperature"]
    assert reused["predictions"]["1h"]["temperature"] == pytest.approx(0.5 * 99 + 0.5 * v2_1h, abs=1e-4)
    assert reused["predictions"]["2h"] == computed["predictions"]["2h"]
    bad = M.predict(history(), CELL, v3_result={**v3, "model_version": "other"})
    assert bad["policy_fallbacks"] == ["v3_unavailable: ValueError"]


def test_own_issue_single_flight(monkeypatch):
    calls = []

    @lru_cache(maxsize=8)
    def slow_issue(*args):
        calls.append(args)
        time.sleep(0.2)
        return {}

    monkeypatch.setattr(weather_series, "_own_issue", slow_issue)
    monkeypatch.setattr(weather_series, "execute_one",
                        lambda sql, params: ("2023-06-20 12:00:00",) if "MAX" in sql else ("om-x",))
    monkeypatch.setattr(weather_series.long_range_model, "artifact_revision", lambda: ("dir", 1))
    monkeypatch.setattr(weather_series, "weather_data_revision", lambda path: (1, 2))
    now = datetime(2023, 6, 20, 13)
    threads = [threading.Thread(target=weather_series._own_forecast_rows, args=(sid, now))
               for sid in ["s1"] * 6 + ["s2"] * 2]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(c[1] for c in calls) == ["s1", "s2"]
