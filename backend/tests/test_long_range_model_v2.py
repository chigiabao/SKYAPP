"""Small synthetic checks for long-range v2; no ingestion, uploads or real training."""
import json
import sys
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
import pytest

import long_range_model_v2 as M

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import train_long_range_v2 as T  # noqa: E402

STATIC = {"lat": 10.79, "lon": 106.63, "elevation": 6.0}
CELL = "om-test"
VERSION = "synthetic-v2-test-only"


def history(n=96, start="2025-01-02"):
    ts = pd.date_range(start, periods=n, freq="h")
    h = np.arange(n)
    return pd.DataFrame({"timestamp": ts, "temperature": 27 + np.sin(h / 24),
                         "humidity": 60.0 + h % 30, "precipitation": (h % 5 == 0).astype(float),
                         "wind_speed": 5.0 + h % 8, "cloud_cover": (h % 100).astype(float),
                         "pressure_msl": 1008.0 + np.cos(h / 12)})


def climatology():
    hours = np.tile(np.arange(24), 12)
    tables = {key: list(20 + hours * 0.1) for key in M.CLIM_KEYS}
    tables["rain"] = [0.3] * 288
    return {"model_version": VERSION, "cells": {CELL: tables},
            "rho": {n: list(np.exp(-np.arange(1, 169) / 24)) for n in M.TARGETS}}


def rows(hist, clim):
    f = M.issue_features(hist, STATIC, clim["cells"][CELL]).iloc[-48:].reset_index(drop=True)
    s = M.issue_state(hist, clim["cells"][CELL]).iloc[-48:].reset_index(drop=True)
    return M.horizon_rows(f, s, hist.timestamp.iloc[-48:].to_numpy(), np.arange(1, 49),
                          clim["cells"][CELL], clim["rho"])


@pytest.fixture
def artifact(tmp_path, monkeypatch):
    root = tmp_path / "model"
    root.mkdir()
    monkeypatch.setenv("LONG_RANGE_V2_MODEL_DIR", str(root))
    clim = climatology()
    x, _ = rows(history(), clim)
    params = {"num_threads": 1, "verbosity": -1, "min_data_in_leaf": 2, "num_leaves": 3}
    lgb.train({**params, "objective": "regression"}, lgb.Dataset(x, label=np.arange(48) / 100),
              num_boost_round=3).save_model(str(root / "temperature.txt"))
    lgb.train({**params, "objective": "binary"}, lgb.Dataset(x, label=np.arange(48) % 2),
              num_boost_round=3).save_model(str(root / "rain_probability.txt"))
    lgb.train({**params, "objective": "regression"}, lgb.Dataset(x, label=5 + np.arange(48) / 10),
              num_boost_round=3).save_model(str(root / "temperature_short.txt"))
    available = {"temperature", "rain_probability"}
    meta = {"schema_version": M.SCHEMA_VERSION, "feature_columns": M.feature_columns(), "max_horizon_hours": 168,
            "model_version": VERSION, "trained_through": "2024-12-24T23:00:00+07:00",
            "cell_static": {CELL: STATIC}, "target_mode": {n: "damped" for n in M.TARGETS},
            "short_range": {"max_horizon_hours": 24, "target_mode": {"temperature": "raw"}},
            "capabilities": {n: {"status": "available" if n in available else "unsupported"} for n in M.TARGETS}}
    (root / "climatology.json").write_text(json.dumps(clim), encoding="utf-8")
    (root / "serving_policy.json").write_text(json.dumps(
        {"model_version": VERSION, "targets": {"temperature": {"v3_weight": {"1h": 0.5},
                                                               "short_weight": {"2h": 1.0, "3h": 0.5}}}}),
        encoding="utf-8")
    (root / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
    yield root
    M._load.cache_clear()


def test_features_past_only_and_48h_window_matches_full_series():
    clim = climatology()["cells"][CELL]
    hist = history(200)
    issue = 110
    original = M.issue_features(hist, STATIC, clim).iloc[issue]
    changed = hist.copy()
    changed.loc[issue + 1:, list(M.WEATHER_FEATURES)] = -999
    pd.testing.assert_series_equal(original, M.issue_features(changed, STATIC, clim).iloc[issue])
    short = hist.iloc[issue - 47:issue + 1].reset_index(drop=True)
    np.testing.assert_allclose(original, M.issue_features(short, STATIC, clim).iloc[-1], atol=1e-5)
    assert not M.issue_features(short, STATIC, clim).iloc[-1].isna().any()


def test_climatology_interpolation_and_bases():
    table = np.repeat(np.arange(12.0), 24)  # month m (0-based) has value m at every hour
    mid = pd.to_datetime(["2023-03-16 05:00", "2023-12-31 23:00", "2024-02-29 00:00"])
    v = M.clim_values(table, mid)
    assert abs(v[0] - 2.0) < 0.05 and 0 < v[1] < 11 and np.isfinite(v).all()
    clim = climatology()
    x, bases = rows(history(), clim)
    assert list(x.columns) == M.feature_columns()
    assert np.allclose(bases["temperature"]["raw"], 0)
    np.testing.assert_allclose(x.base_temperature, bases["temperature"]["damped"], rtol=1e-6)
    # Damped base reverts to climatology as rho(h) decays.
    gap = np.abs(bases["temperature"]["damped"] - bases["temperature"]["anomaly"])
    assert gap[-1] < gap[0] or gap[0] == 0


def test_contract_policy_and_leakage_guard(artifact, monkeypatch):
    calls = []

    def fake_v3(hist, cell_id):
        calls.append(len(hist))
        return {1: {"temperature": 99.0}, 3: {"temperature": 99.0}, 6: {"temperature": 99.0}}

    monkeypatch.setattr(M, "v3_component", fake_v3)
    meta, models, climate, policy = M._load(*M.artifact_revision())
    hist = M._prepare(history(), CELL)
    values, fallbacks = M.forecast_arrays(hist, CELL, meta, models, climate, policy, fake_v3)
    plain, _ = M.forecast_arrays(hist, CELL, meta, models, climate, {"targets": {}}, fake_v3)
    assert values["temperature"][0] == pytest.approx(0.5 * 99 + 0.5 * plain["temperature"][0])
    long_only = M.blend_short("temperature", {}, plain["temperature"], None)
    np.testing.assert_allclose(values["temperature"][3:], long_only[3:])
    short_rule = {"targets": {"temperature": {"short_weight": {"2h": 1.0, "3h": 0.5}}}}
    mixed, _ = M.forecast_arrays(hist, CELL, meta, models, climate, short_rule, fake_v3)
    np.testing.assert_allclose(values["temperature"][1:3], mixed["temperature"][1:3])
    assert abs(mixed["temperature"][1] - plain["temperature"][1]) > 1  # short booster (label ~5) used at 2h
    assert fallbacks == [] and calls == [48]
    assert ((values["rain_probability"] >= 0) & (values["rain_probability"] <= 1)).all()

    def broken(hist, cell_id):
        raise RuntimeError("no V3")

    failed, fb = M.forecast_arrays(hist, CELL, meta, models, climate, policy, broken)
    np.testing.assert_allclose(failed["temperature"], mixed["temperature"])
    assert fb and fb[0].startswith("v3_unavailable")

    out = M.predict(history(), CELL)
    assert list(out["predictions"]) == [f"{i}h" for i in range(1, 169)] and len(out["hourly"]) == 168
    last = out["predictions"]["168h"]
    assert pd.Timestamp(last["valid_at"]) - pd.Timestamp(out["issued_at"]) == pd.Timedelta(hours=168)
    assert isinstance(last["temperature"], float) and last["humidity"] is None
    assert M.status()["capabilities"]["humidity"]["status"] == "unsupported"
    json.dumps(out, allow_nan=False)
    with pytest.raises(ValueError, match="replay_leakage"):
        M.predict(history(start="2024-12-20"), CELL)
    with pytest.raises(ValueError, match="unsupported_cell"):
        M.predict(history(), "om-other")
    with pytest.raises(ValueError, match="invalid_history"):
        M.predict(history(40), CELL)


def test_policy_version_mismatch_is_unavailable(artifact):
    (artifact / "serving_policy.json").write_text(json.dumps({"model_version": "other", "targets": {}}),
                                                  encoding="utf-8")
    M._load.cache_clear()
    assert M.status()["status"] == "unavailable"
    with pytest.raises(ValueError, match="unavailable"):
        M.predict(history(), CELL)


def test_status_untrained(tmp_path, monkeypatch):
    monkeypatch.setenv("LONG_RANGE_V2_MODEL_DIR", str(tmp_path / "missing"))
    assert M.status()["status"] == "untrained"
    assert M.MAX_HORIZON == 168 and M.MIN_HISTORY_HOURS == 48


def test_trainer_climatology_uses_train_rows_and_samples_stay_in_split():
    ts = pd.date_range("2021-01-01", periods=24 * 400, freq="h")
    raw = history(len(ts)).assign(timestamp=ts)
    train = np.asarray(ts <= pd.Timestamp("2021-12-31 23:00"))
    base = T.climatology_tables(raw, train)
    changed = raw.copy()
    changed.loc[~train, "temperature"] = 1000.0
    assert T.climatology_tables(changed, train) == base
    cd = T.CellData(CELL, raw, STATIC, base, climatology()["rho"])
    rng = np.random.default_rng(0)
    lo, hi = pd.Timestamp("2021-02-01"), pd.Timestamp("2021-06-30 23:00")
    issues, horizons = T.sample(cd, lo, hi, 3, 4, rng)
    assert (raw.timestamp.iloc[issues].to_numpy() >= lo).all()
    assert (raw.timestamp.iloc[issues + horizons].to_numpy() <= hi).all()
    assert horizons.min() >= 1 and horizons.max() <= 168 and (horizons.reshape(-1, 4)[:, 0] <= 24).all()


def test_training_rows_use_leave_one_year_out_climatology():
    ts = pd.date_range("2021-01-01", "2023-12-31 23:00", freq="h")
    raw = history(len(ts)).assign(timestamp=ts)
    raw["temperature"] += (ts.year.to_numpy() - 2021) ** 2 * 3.0  # unequal yearly offsets: folds differ
    train = np.asarray((ts >= T.TRAIN_START) & (ts <= T.TRAIN_END))
    cd = T.CellData(CELL, raw, STATIC, T.climatology_tables(raw, train), climatology()["rho"])
    issues = np.array([100, 9000, 18000, 25000])
    horizons = np.array([5, 30, 168, 1], dtype=np.int32)
    x, _, _ = cd.rows_oof(issues, horizons)
    col = M.feature_columns().index("clim_valid_temperature")
    for i, (issue, h) in enumerate(zip(issues, horizons)):
        valid = ts[issue + h]
        own = T.climatology_tables(raw, train & (ts.year.to_numpy() != valid.year))
        assert x[i, col] == pytest.approx(M.clim_values(own["temperature"], [valid])[0], abs=1e-4)
        assert x[i, col] != pytest.approx(M.clim_values(cd.clim["temperature"], [valid])[0], abs=1e-2)


def _interval_artifact(root, version=VERSION, served=("B1", "B2", "B3", "B4", "B5")):
    """Minimal v2 interval artifact (normalized, std = 1) written like scripts/fit_long_range_v2_intervals.py."""
    import hashlib

    import long_range_model_v21 as S
    bands = {b: {"q_lo": -1.0, "q_hi": 2.0, "n": 100, "cv_coverage": 0.8, "served": b in served} for b in S.BANDS}
    body = {"schema_version": 1, "v2_model_version": version, "level": 0.8,
            "bands": {b: list(r) for b, r in S.BANDS.items()}, "upper_only": ["precipitation_mm"],
            "intervals": {"temperature": {"method": "normalized", "bands": bands}},
            "std": {CELL: {"temperature": [1.0] * 288}}}
    root.mkdir(parents=True, exist_ok=True)
    (root / "intervals.json").write_text(json.dumps(body), encoding="utf-8")
    digest = hashlib.sha256((root / "intervals.json").read_bytes()).hexdigest()
    (root / "metadata.json").write_text(json.dumps({"schema_version": 1, "v2_model_version": version,
                                                    "intervals_sha256": digest}), encoding="utf-8")


def _points(out):
    return {k: {n: r[n] for n in M.TARGETS} for k, r in out["predictions"].items()}


def test_intervals_attach_without_changing_points(artifact, tmp_path, monkeypatch):
    monkeypatch.setattr(M, "v3_component", lambda hist, cid: {1: {"temperature": 30.0}})
    monkeypatch.setenv("LONG_RANGE_V2_INTERVALS_DIR", str(tmp_path / "none"))
    before = M.predict(history(), CELL)
    assert "interval_level" not in before and "temperature_p10" not in before["predictions"]["1h"]
    root = tmp_path / "intervals"
    _interval_artifact(root)
    monkeypatch.setenv("LONG_RANGE_V2_INTERVALS_DIR", str(root))
    after = M.predict(history(), CELL)
    assert _points(after) == _points(before)
    assert after["interval_level"] == 0.8 and "split-conformal" in after["interval_method"]
    for key, rec in after["predictions"].items():
        assert set(M.INTERVAL_KEYS) <= set(rec)
        assert rec["humidity_p10"] is None and rec["precipitation_mm_p90"] is None  # no rule
        if int(key.rstrip("h")) <= 120:
            assert rec["temperature_p10"] == pytest.approx(rec["temperature"] - 1, abs=1e-3)
            assert rec["temperature_p90"] == pytest.approx(rec["temperature"] + 2, abs=1e-3)
        else:  # B6 failed the gate
            assert rec["temperature_p10"] is None and rec["temperature_p90"] is None
    json.dumps(after, allow_nan=False)
    M._load_intervals.cache_clear()


@pytest.mark.parametrize("damage", ["sha", "version", "nan"])
def test_invalid_interval_artifact_serves_points_only(artifact, tmp_path, monkeypatch, damage):
    monkeypatch.setattr(M, "v3_component", lambda hist, cid: {1: {"temperature": 30.0}})
    root = tmp_path / "intervals"
    _interval_artifact(root, version="other" if damage == "version" else VERSION)
    if damage == "sha":
        (root / "intervals.json").write_text("{}", encoding="utf-8")
    if damage == "nan":
        text = (root / "intervals.json").read_text(encoding="utf-8").replace('"q_hi": 2.0', '"q_hi": NaN', 1)
        (root / "intervals.json").write_text(text, encoding="utf-8")
        meta = json.loads((root / "metadata.json").read_text(encoding="utf-8"))
        import hashlib
        meta["intervals_sha256"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
        (root / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
    monkeypatch.setenv("LONG_RANGE_V2_INTERVALS_DIR", str(root))
    out = M.predict(history(), CELL)
    assert "interval_level" not in out and "temperature_p90" not in out["predictions"]["1h"]
    assert isinstance(out["predictions"]["1h"]["temperature"], float)
    M._load_intervals.cache_clear()


def test_revision_tracks_interval_artifact(artifact, tmp_path, monkeypatch):
    root = tmp_path / "intervals"
    monkeypatch.setenv("LONG_RANGE_V2_INTERVALS_DIR", str(root))
    plain = M.artifact_revision()
    _interval_artifact(root)
    assert M.artifact_revision() != plain and M.artifact_revision()[0] == plain[0]


def test_series_router_passes_long_range_intervals(monkeypatch):
    from datetime import datetime

    from routers import weather_series

    def fake_predict(history, cell_id):
        recs = {"1h": {"temperature": 28.0, "humidity": 70.0, "precipitation_mm": 0.0, "wind_speed": 5.0,
                       "cloud_cover": 40.0, "rain_probability": 0.2, "temperature_p10": 27.0,
                       "temperature_p90": 29.5, "humidity_p10": None, "humidity_p90": None,
                       "wind_speed_p10": 3.0, "wind_speed_p90": 8.0, "cloud_cover_p10": None,
                       "cloud_cover_p90": None, "precipitation_mm_p90": 0.4},
                "2h": {"temperature": 28.5, "humidity": 70.0, "precipitation_mm": 0.0, "wind_speed": 5.0,
                       "cloud_cover": 40.0, "rain_probability": 0.2}}
        return {"issued_at": "2026-10-22T10:00:00+07:00", "predictions": recs, "interval_level": 0.8}

    monkeypatch.setattr(weather_series.ai_model, "load_history_from_db", lambda **kw: None)
    monkeypatch.setattr(weather_series.long_range_model, "predict", fake_predict)
    weather_series._own_issue.cache_clear()
    out = weather_series._own_issue("db", "sid", "cell", "2026-10-22T10:00:00", ("r", 1))
    weather_series._own_issue.cache_clear()
    first, second = out[datetime(2026, 10, 22, 11)], out[datetime(2026, 10, 22, 12)]
    assert (first.temperature_p10, first.temperature_p90, first.interval_level) == (27.0, 29.5, 0.8)
    assert first.precipitation_p90 == 0.4 and first.humidity_p10 is None and first.wind_speed_p90 == 8.0
    assert second.temperature_p10 is None and second.interval_level is None
