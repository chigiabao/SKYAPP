"""Small synthetic checks; no ingestion, uploads or production training."""
import json
import sys
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
import pytest

import long_range_model as M

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import train_long_range as T

STATIC = {"lat": 10.79, "lon": 106.63, "elevation": 6.0}
CELL = "om-test"


def history(n=96, start="2025-01-02"):
    ts = pd.date_range(start, periods=n, freq="h")
    h = np.arange(n)
    return pd.DataFrame({"timestamp": ts, "temperature": 27 + np.sin(h / 24),
                         "humidity": 60 + h % 30, "precipitation": (h % 5 == 0).astype(float),
                         "wind_speed": 5 + h % 8, "cloud_cover": h % 100, "pressure_msl": 1008.0})


@pytest.fixture
def artifact(tmp_path, monkeypatch):
    root = tmp_path / "model"
    root.mkdir()
    monkeypatch.setenv("LONG_RANGE_MODEL_DIR", str(root))
    hist = history()
    base = M.issue_features(hist, STATIC).iloc[-48:]
    x = M.horizon_features(base, hist.timestamp.iloc[-48:], np.arange(1, 49))
    model = lgb.train({"objective": "regression", "num_threads": 2, "verbosity": -1,
                       "min_data_in_leaf": 2, "num_leaves": 3},
                      lgb.Dataset(x, label=np.arange(48) / 10 + 25), num_boost_round=3)
    model.save_model(str(root / "temperature.txt"))
    meta = {"schema_version": 1, "feature_columns": M.feature_columns(), "max_horizon_hours": 168,
            "model_version": "synthetic-test-only", "trained_through": "2024-12-24T23:00:00+07:00",
            "cell_static": {CELL: STATIC}, "capabilities": {
                name: {"status": "available" if name == "temperature" else "unsupported"}
                for name in M.TARGETS}}
    (root / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
    yield root
    M._load.cache_clear()


def test_features_use_no_future_weather_and_match_serving_window():
    hist = history(200)
    issue = 110
    original = M.issue_features(hist, STATIC).iloc[issue]
    changed = hist.copy()
    changed.loc[issue + 1:, list(M.WEATHER_FEATURES)] = -999
    pd.testing.assert_series_equal(original, M.issue_features(changed, STATIC).iloc[issue])
    short = hist.iloc[issue-47:issue+1].reset_index(drop=True)
    np.testing.assert_allclose(original, M.issue_features(short, STATIC).iloc[-1], atol=1e-5)
    x = M.horizon_features(pd.DataFrame([original, original]),
                           pd.Series([hist.timestamp.iloc[issue]] * 2), [1, 168])
    assert list(x.columns) == M.feature_columns()
    assert list(x.horizon_hours) == [1, 168]
    assert "valid_temperature" not in x


def test_contract_all_168_hours_null_unsupported(artifact):
    out = M.predict(history(), CELL)
    assert out["source"] == "ai"
    assert list(out["predictions"]) == [f"{i}h" for i in range(1, 169)]
    assert len(out["hourly"]) == 168
    last = out["predictions"]["168h"]
    assert pd.Timestamp(last["valid_at"]) - pd.Timestamp(out["issued_at"]) == pd.Timedelta(hours=168)
    assert last["model_version"] == out["model_version"]
    assert last["issued_at"] == out["issued_at"]
    assert last["source"] == "ai"
    assert isinstance(last["temperature"], float)
    assert all(last[n] is None for n in M.TARGETS if n != "temperature")
    assert M.status()["capabilities"]["humidity"]["status"] == "unsupported"
    json.dumps(out, allow_nan=False)


def test_scope_has_no_alias_or_v2_fallback(artifact):
    with pytest.raises(ValueError, match="^unsupported_cell:"):
        M.predict(history(), "tsn")


@pytest.mark.parametrize("kind", ["short", "gap", "duplicate", "missing_temp", "other_cell", "half_hour"])
def test_bad_history_is_explicit(artifact, kind):
    hist = history()
    if kind == "short":
        hist = hist.tail(47)
    elif kind == "gap":
        hist = hist.drop(index=80)
    elif kind == "duplicate":
        hist.loc[95, "timestamp"] = hist.timestamp.iloc[94]
    elif kind == "missing_temp":
        hist.loc[94, "temperature"] = np.nan
    elif kind == "other_cell":
        hist["cell_id"] = "other"
    else:
        hist["timestamp"] += pd.Timedelta(minutes=30)
    with pytest.raises(ValueError, match="^invalid_history:"):
        M.predict(hist, CELL)


def test_replay_rejects_validation_knowledge_not_just_fit_cutoff(artifact):
    hist = history(start="2024-12-21")
    assert hist.timestamp.iloc[-1] == pd.Timestamp("2024-12-24 23:00")
    with pytest.raises(ValueError, match="^replay_leakage:"):
        M.predict(hist, CELL)


def test_aware_history_and_naive_local_history_are_identical(artifact):
    hist = history()
    aware = hist.copy()
    aware["timestamp"] = aware.timestamp.dt.tz_localize(M.TIMEZONE).dt.tz_convert("UTC")
    assert M.predict(hist, CELL) == M.predict(aware, CELL)


def test_missing_broken_and_revision(monkeypatch, tmp_path):
    path = tmp_path / "absent"
    monkeypatch.setenv("LONG_RANGE_MODEL_DIR", str(path))
    assert M.status()["status"] == "untrained"
    assert M.artifact_revision() == (str(path.resolve()), 0)
    with pytest.raises(ValueError, match="^untrained:"):
        M.predict(history(), CELL)
    path.mkdir()
    (path / "metadata.json").write_text("{}", encoding="utf-8")
    assert M.artifact_revision()[1] > 0
    assert M.status()["status"] == "unavailable"
    with pytest.raises(ValueError, match="^unavailable:"):
        M.predict(history(), CELL)


def test_broken_booster_is_unavailable(artifact):
    (artifact / "temperature.txt").unlink()
    assert M.status()["status"] == "unavailable"


def test_purged_splits_have_no_horizon_overlap():
    ts = pd.Series(pd.date_range("2024-06-01", "2025-02-01", freq="h"))
    splits = T.split_masks(ts, pd.Timestamp("2025-02-01"))
    assert (ts[splits["train"]] + pd.Timedelta(hours=168)).max() <= T.TRAIN_END
    assert ts[splits["validation"]].min() - T.TRAIN_END > pd.Timedelta(hours=168)
    assert (ts[splits["validation"]] + pd.Timedelta(hours=168)).max() <= T.VAL_END
    assert ts[splits["test"]].min() - T.VAL_END > pd.Timedelta(hours=168)


def test_sampled_targets_are_real_valid_time_labels_and_climatology_is_train_only():
    hist = history(24 * 500, start="2024-01-01")
    quotas = {"train": 168, "validation": 168, "test": 168}
    out = T.sample_cell(hist, CELL, STATIC, quotas, 5, 42, hist.timestamp.max())
    lookup = hist.set_index("timestamp")
    for split, (x, rows) in out.items():
        assert set(x.horizon_hours) == set(range(1, 169))
        assert (rows.valid_at - rows.issued_at).eq(pd.to_timedelta(rows.horizon_hours, unit="h")).all()
        np.testing.assert_allclose(rows.temperature, lookup.loc[rows.valid_at].temperature)
    perturbed = hist.copy()
    perturbed.loc[perturbed.timestamp >= T.VAL_START, "temperature"] += 100
    again = T.sample_cell(perturbed, CELL, STATIC, quotas, 5, 42, hist.timestamp.max())
    np.testing.assert_allclose(out["test"][1].climatology_temperature,
                               again["test"][1].climatology_temperature)


def test_null_rain_is_not_a_dry_label_and_probability_brier():
    raw = pd.DataFrame({"precipitation": [np.nan, 0.0, 0.1, 0.2, -1, np.inf]})
    result = T.target_values(raw, "rain_probability")
    np.testing.assert_allclose(result, [np.nan, 0, 0, 1, np.nan, np.nan], equal_nan=True)
    assert T.metrics(np.array([0, 1]), np.array([0.25, 0.75]), binary=True)["brier"] == 0.0625


def test_rss_guard_is_measuring_real_process():
    assert T.rss_mib() > 1


def test_absent_target_is_not_imputed_to_zero():
    assert np.isnan(T.target_values(pd.DataFrame({"temperature": [23, 24]}), "humidity")).all()


@pytest.mark.parametrize("change", ["naive_cutoff", "cutoff_before_fit", "bad_static"])
def test_invalid_artifact_metadata_is_unavailable(artifact, change):
    path = artifact / "metadata.json"
    meta = json.loads(path.read_text(encoding="utf-8"))
    if change == "naive_cutoff":
        meta["trained_through"] = "2024-12-24"
    elif change == "cutoff_before_fit":
        meta["fit_labels_through"] = "2025-01-01T00:00:00+07:00"
    else:
        meta["cell_static"][CELL]["lat"] = None
    path.write_text(json.dumps(meta), encoding="utf-8")
    assert M.status()["status"] == "unavailable"
    with pytest.raises(ValueError, match="^unavailable:"):
        M.predict(history(), CELL)


def test_revision_invalidates_cached_metadata(artifact):
    before = M.artifact_revision()
    assert M.status()["model_version"] == "synthetic-test-only"
    path = artifact / "metadata.json"
    meta = json.loads(path.read_text(encoding="utf-8"))
    meta["model_version"] = "replacement-test-model"
    path.write_text(json.dumps(meta), encoding="utf-8")
    assert M.artifact_revision() != before
    assert M.status()["model_version"] == "replacement-test-model"
