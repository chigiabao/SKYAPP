"""Synthetic checks for long-range v2.1 (serving module + trainer helpers); no real data or real training."""
import argparse
import json
import sqlite3
import sys
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
import pytest

import long_range_model_v2 as M2
import long_range_model_v21 as S

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import export_colab_data as E  # noqa: E402
import train_long_range_v2 as T2  # noqa: E402
import train_long_range_v21 as T  # noqa: E402

STATIC = {"lat": 10.79, "lon": 106.63, "elevation": 6.0}
CELL = "om-test"
VERSION = "lgbm-direct-168h-v21-synthetic-test"
V2_VERSION = "synthetic-v2-parity"


def history(n=96, start="2025-11-02"):
    ts = pd.date_range(start, periods=n, freq="h")
    h = np.arange(n)
    return pd.DataFrame({"timestamp": ts, "temperature": 27 + np.sin(h / 24),
                         "humidity": 60.0 + h % 30, "precipitation": (h % 5 == 0).astype(float),
                         "wind_speed": 5.0 + h % 8, "cloud_cover": (h % 100).astype(float),
                         "pressure_msl": 1008.0 + np.cos(h / 12)})


def climatology(version=VERSION):
    hours = np.tile(np.arange(24), 12)
    tables = {key: list(20 + hours * 0.1) for key in M2.CLIM_KEYS}
    tables["rain"] = [0.3] * 288
    return {"model_version": version, "cells": {CELL: tables},
            "rho": {n: list(np.exp(-np.arange(1, 169) / 24)) for n in M2.TARGETS},
            "std": {CELL: {n: [1.5] * 288 for n in S.INTERVAL_TARGETS}}}


def train_boosters(root: Path):
    clim = climatology()
    hist = history()
    f = M2.issue_features(hist, STATIC, clim["cells"][CELL]).iloc[-48:].reset_index(drop=True)
    s = M2.issue_state(hist, clim["cells"][CELL]).iloc[-48:].reset_index(drop=True)
    x, _ = M2.horizon_rows(f, s, hist.timestamp.iloc[-48:].to_numpy(), np.arange(1, 49), clim["cells"][CELL],
                           clim["rho"])
    params = {"num_threads": 1, "verbosity": -1, "min_data_in_leaf": 2, "num_leaves": 3}
    rng = np.random.default_rng(0)
    for name in M2.TARGETS:
        binary = name == "rain_probability"
        for suffix, shift in (("", 0.0), ("_short", 3.0)):
            label = (np.arange(48) % 2) if binary else rng.normal(shift, 1.0, 48)
            lgb.train({**params, "objective": "binary" if binary else "regression"},
                      lgb.Dataset(x, label=label), num_boost_round=3).save_model(str(root / f"{name}{suffix}.txt"))


def write_artifact(root: Path, policy_targets=None, calibration_bands=None, intervals=None, flags=None):
    root.mkdir(parents=True, exist_ok=True)
    meta = {"schema_version": S.SCHEMA_VERSION, "feature_columns": M2.feature_columns(), "max_horizon_hours": 168,
            "model_version": VERSION, "trained_through": "2024-12-24T23:00:00+07:00",
            "cell_static": {CELL: STATIC}, "target_mode": {n: "damped" for n in M2.TARGETS},
            "short_range": {"max_horizon_hours": 36, "target_mode": {n: "damped" for n in M2.TARGETS}},
            "capabilities": {n: {"status": "available"} for n in M2.TARGETS}}
    (root / "climatology.json").write_text(json.dumps(climatology()), encoding="utf-8")
    (root / "serving_policy.json").write_text(json.dumps(
        {"model_version": VERSION, "targets": policy_targets or {}, "intervals": intervals or {},
         "serve_calibrated_rain": flags or {}}), encoding="utf-8")
    (root / "calibration.json").write_text(json.dumps(
        {"model_version": VERSION, "bands": calibration_bands or {b: {"method": "none"} for b in S.BANDS}}),
        encoding="utf-8")
    (root / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")


FULL_POLICY = {n: {"taper": {"w0": 1.0, "a": 12, "b": 30}} for n in M2.TARGETS}
FULL_POLICY["temperature"]["v3"] = {"weights": {"1h": 1.0, "3h": 0.5, "6h": 0.25}, "stitched": True}
INTERVALS = {"temperature": {"method": "normalized", "bands": {b: {"q_lo": -1.0, "q_hi": 1.2, "served": True}
                                                               for b in S.BANDS}},
             "humidity": {"method": "normalized", "bands": {"B1": {"q_lo": -2.0, "q_hi": 2.0, "served": True},
                                                            "B2": {"q_lo": -2.0, "q_hi": 2.0, "served": False}}},
             "precipitation_mm": {"method": "unnormalized",
                                  "bands": {b: {"q_lo": 0.0, "q_hi": 0.5, "served": True} for b in S.BANDS}}}
CAL = {b: {"method": "none"} for b in S.BANDS}
CAL["B2"] = {"method": "isotonic", "x": [0.0, 0.5, 1.0], "y": [0.01, 0.2, 0.95]}
CAL["B3"] = {"method": "platt", "a": 0.8, "b": -0.2}


@pytest.fixture
def artifact(tmp_path, monkeypatch):
    root = tmp_path / "v21"
    root.mkdir()
    train_boosters(root)
    write_artifact(root, FULL_POLICY, CAL, INTERVALS, {"B2": True, "B3": True})
    monkeypatch.setenv("LONG_RANGE_V21_MODEL_DIR", str(root))
    S._load.cache_clear()
    yield root
    S._load.cache_clear()


def fake_v3_factory(calls):
    def fake(hist, cell_id):
        calls.append(len(hist))
        return {1: {"temperature": 40.0}, 3: {"temperature": 40.0}, 6: {"temperature": 40.0}}
    return fake


# ------------------------------------------------------------------------------------------ serving
def test_v2_helpers_still_importable():
    for name in ("timestamps", "local_iso", "clim_values", "issue_features", "issue_state", "horizon_rows",
                 "bounded", "logit", "model_output", "_prepare", "v3_component", "v3_values", "feature_columns"):
        assert callable(getattr(M2, name))
    for name in ("MAX_HORIZON", "MIN_HISTORY_HOURS", "RAIN_THRESHOLD_MM", "TARGETS", "predict", "status",
                 "artifact_revision"):
        assert hasattr(S, name)
    assert S.MAX_HORIZON == 168 and S.MIN_HISTORY_HOURS == 48 and S.SHORT_MAX_HORIZON == 36
    assert set(S.TARGETS) == set(M2.TARGETS)


def test_status_untrained_and_revision(tmp_path, monkeypatch):
    monkeypatch.setenv("LONG_RANGE_V21_MODEL_DIR", str(tmp_path / "missing"))
    assert S.status()["status"] == "untrained"
    assert S.artifact_revision()[1] == 0
    with pytest.raises(ValueError, match="untrained"):
        S.predict(history(), CELL)


def test_identity_layers_match_v2_point_values(tmp_path, monkeypatch):
    v21 = tmp_path / "v21"
    v21.mkdir()
    train_boosters(v21)
    write_artifact(v21)
    v2 = tmp_path / "v2"
    v2.mkdir()
    for f in v21.glob("*.txt"):
        (v2 / f.name).write_bytes(f.read_bytes())
    meta = json.loads((v21 / "metadata.json").read_text())
    meta.update(schema_version=M2.SCHEMA_VERSION, model_version=V2_VERSION,
                short_range={"max_horizon_hours": 24, "target_mode": meta["short_range"]["target_mode"]})
    (v2 / "metadata.json").write_text(json.dumps(meta))
    clim = climatology(V2_VERSION)
    del clim["std"]
    (v2 / "climatology.json").write_text(json.dumps(clim))
    (v2 / "serving_policy.json").write_text(json.dumps({"model_version": V2_VERSION, "targets": {}}))
    monkeypatch.setenv("LONG_RANGE_V21_MODEL_DIR", str(v21))
    monkeypatch.setenv("LONG_RANGE_V2_MODEL_DIR", str(v2))
    S._load.cache_clear()
    M2._load.cache_clear()
    try:
        a, b = S.predict(history(), CELL), M2.predict(history(), CELL)
    finally:
        S._load.cache_clear()
        M2._load.cache_clear()
    assert set(b) <= set(a) and set(b["predictions"]["1h"]) <= set(a["predictions"]["1h"])
    for key in ("1h", "24h", "25h", "168h"):
        for name in M2.TARGETS:
            assert a["predictions"][key][name] == pytest.approx(b["predictions"][key][name], abs=1e-9)
    assert a["predictions"]["5h"]["temperature_p10"] is None and a["policy_fallbacks"] == []


def test_contract_superset_intervals_and_calibration(artifact, monkeypatch):
    calls = []
    monkeypatch.setattr(S, "v3_component", fake_v3_factory(calls))
    out = S.predict(history(), CELL)
    assert calls == [48] and out["policy_fallbacks"] == []
    assert out["model_version"].startswith("lgbm-direct-168h-v21-") and out["source"] == "ai"
    assert len(out["predictions"]) == 168 and len(out["hourly"]) == 168
    assert out["interval_level"] == 0.8 and set(out["rain_calibration"]) == set(S.BANDS)
    assert out["rain_calibration"]["B2"] == "isotonic" and out["rain_calibration"]["B1"] == "none"
    json.dumps(out, allow_nan=False)
    for rec in out["hourly"]:
        for key in M2.TARGETS:
            assert isinstance(rec[key], float)
        for key in S.EXTRA_RECORD_KEYS:
            assert rec[key] is None or isinstance(rec[key], float)
        assert 0 <= rec["rain_probability"] <= 1 and 0 <= rec["rain_probability_raw"] <= 1
        assert 0 <= rec["humidity"] <= 100 and rec["precipitation_mm"] >= 0
        assert rec["temperature_p10"] <= rec["temperature"] <= rec["temperature_p90"]
        assert rec["precipitation_mm_p90"] >= rec["precipitation_mm"] and rec["precipitation_mm_p90"] >= 0
        if rec["humidity_p90"] is not None:
            assert rec["horizon_hours"] <= 6 and rec["humidity_p10"] <= rec["humidity"] <= rec["humidity_p90"] <= 100
        h = rec["horizon_hours"]
        if 7 <= h <= 24:  # B2 served with the isotonic calibrator
            expected = S.calibrator_apply([rec["rain_probability_raw"]], CAL["B2"])[0]
            assert rec["rain_probability"] == pytest.approx(expected, abs=2e-3)
        elif not 25 <= h <= 48:  # B3 is Platt, the other bands are served raw
            assert rec["rain_probability"] == pytest.approx(rec["rain_probability_raw"], abs=1e-4)
    meta, models, climate, policy, calibration = S._loaded()
    hist = S._prepare(history(), CELL)
    served, _ = S.forecast_arrays(hist, CELL, meta, models, climate, policy, calibration, fake_v3_factory([]))
    plain, fb = S.forecast_arrays(hist, CELL, meta, models, climate, policy, calibration, use_v3=False)
    assert fb == ["v3_knowledge_window"]
    t, p = served["temperature"], plain["temperature"]
    assert t[0] == pytest.approx(40.0, abs=1e-6)  # w(1)=1: V3 value
    np.testing.assert_allclose(t[8:], p[8:])  # stitched correction is 0 from 9h
    c = t[:9] - p[:9]
    assert c[1] == pytest.approx((c[0] + c[2]) / 2, abs=1e-6)  # linear between anchors 1 and 3


def test_v3_knowledge_window_and_replay_guard(artifact, monkeypatch, caplog):
    calls = []
    monkeypatch.setattr(S, "v3_component", fake_v3_factory(calls))
    with caplog.at_level("WARNING", logger="long_range_model_v21"):
        out = S.predict(history(start="2025-05-01"), CELL)
    assert calls == [] and out["policy_fallbacks"] == ["v3_knowledge_window"]
    assert out["components"]["v3_model_version"] is None
    assert any("v3_knowledge_window" in r.message for r in caplog.records)
    with pytest.raises(ValueError, match="replay_leakage"):
        S.predict(history(start="2024-12-20"), CELL)
    with pytest.raises(ValueError, match="unsupported_cell"):
        S.predict(history(), "om-other")
    with pytest.raises(ValueError, match="invalid_history"):
        S.predict(history(40), CELL)


def test_v3_failure_serves_v21_alone(artifact, monkeypatch):
    def broken(hist, cell_id):
        raise RuntimeError("no V3")
    monkeypatch.setattr(S, "v3_component", broken)
    out = S.predict(history(), CELL)
    assert out["policy_fallbacks"][0].startswith("v3_unavailable")
    assert out["components"]["v3_model_version"] is None


def test_version_mismatch_and_broken_calibrator_unavailable(artifact):
    (artifact / "calibration.json").write_text(json.dumps({"model_version": "other", "bands": CAL}))
    S._load.cache_clear()
    assert S.status()["status"] == "unavailable"
    bad = dict(CAL)
    bad["B2"] = {"method": "isotonic", "x": [0, 0.5, 1], "y": [0.5, 0.2, 0.9]}
    (artifact / "calibration.json").write_text(json.dumps({"model_version": VERSION, "bands": bad}))
    S._load.cache_clear()
    assert "monotone" in S.status()["reason"]


def test_revision_tracks_calibration_file(artifact):
    import os
    before = S.artifact_revision()
    st = (artifact / "calibration.json").stat()
    os.utime(artifact / "calibration.json", ns=(st.st_atime_ns, st.st_mtime_ns + 10_000_000))
    assert S.artifact_revision() != before and S.artifact_revision()[0] == before[0]


def test_taper_expansion_and_monotone():
    w = S.taper_weights({"w0": 0.75, "a": 12, "b": 24})
    assert w.shape == (36,) and (w[:12] == 0.75).all() and w[17] == pytest.approx(0.375) and (w[23:] == 0).all()
    assert (np.diff(w[11:]) <= 0).all()
    with pytest.raises(ValueError):
        S.taper_weights({"w0": 1.0, "a": 24, "b": 24})
    long_ = np.zeros((1, 168))
    short = np.ones((1, 36))
    v = S.blend_taper("temperature", long_, short, {"w0": 1.0, "a": 12, "b": 30})
    assert np.abs(np.diff(v[0, :40])).max() <= 1 / 18 + 1e-12  # no jump at the hand-off


def test_v3_correction_anchor_only_and_stitched():
    v21 = np.zeros((2, 168))
    v3 = np.array([[3.0, 3.0, 3.0], [np.nan, 3.0, 3.0]])
    w = {"1h": 1.0, "3h": 0.5, "6h": 0.5}
    a = S.v3_correction(v21, v3, w, stitched=False)
    assert a[0, 0] == 3 and a[0, 2] == 1.5 and a[0, 5] == 1.5 and a[0, 1] == 0 and a[1, 0] == 0
    s = S.v3_correction(v21, v3, w, stitched=True)
    np.testing.assert_allclose(s[0, :9], [3, 2.25, 1.5, 1.5, 1.5, 1.5, 1.0, 0.5, 0.0])
    assert (s[:, 9:] == 0).all()


def test_interval_bounds_ordering_and_bounds():
    values = np.array([0.0, 50.0, 99.0, 2.0])
    lo, hi = S.interval_bounds("humidity", values, np.ones(4) * 5, np.array([1, 10, 30, 100]),
                               np.array(["dry", "wet", "dry", "wet"]),
                               {"method": "normalized", "bands": {b: {"q_lo": 0.3, "q_hi": 2.0, "served": True}
                                                                  for b in S.BANDS}})
    assert (lo <= values).all() and (hi >= values).all() and (lo >= 0).all() and (hi <= 100).all()
    lo, hi = S.interval_bounds("precipitation_mm", values, np.ones(4), np.array([1, 2, 3, 4]), np.array(["dry"] * 4),
                               {"method": "unnormalized", "bands": {"B1": {"q_lo": -9, "q_hi": -1.0, "served": True}}})
    assert np.isnan(lo).all() and (hi >= values).all()


# ------------------------------------------------------------------------------------------ trainer
def synthetic_raw(start="2021-01-01", end="2023-12-31 23:00", seed=0):
    ts = pd.date_range(start, end, freq="h")
    rng = np.random.default_rng(seed)
    n = len(ts)
    h = np.arange(n)
    raw = pd.DataFrame({"timestamp": ts, "temperature": 27 + 3 * np.sin(2 * np.pi * h / 24) + rng.normal(0, 1, n),
                        "humidity": np.clip(70 + rng.normal(0, 8, n), 0, 100),
                        "precipitation": np.round(np.maximum(rng.normal(-0.5, 1, n), 0), 1),
                        "wind_speed": np.abs(rng.normal(8, 3, n)), "cloud_cover": np.clip(rng.normal(50, 25, n), 0, 100),
                        "pressure_msl": 1008 + rng.normal(0, 2, n)})
    for c in T2.V3_COLUMNS:
        raw[c] = 1.0
    return raw


def test_validation_roles_are_purged_and_train_labels_end_on_time():
    ts = pd.Series(pd.date_range("2024-01-01", "2024-12-31 23:00", freq="h"))
    fit = T.issue_window(ts, *T.VAL_FIT)
    cal = T.issue_window(ts, *T.VAL_CAL)
    fit_labels = ts[fit].max() + pd.Timedelta(hours=168)
    cal_first = ts[cal].min() + pd.Timedelta(hours=1)
    assert cal_first - fit_labels > pd.Timedelta(hours=168)
    assert ts[fit].min() >= T.VAL_FIT[0] and ts[cal].max() + pd.Timedelta(hours=168) <= T.VAL_CAL[1]

    class Cell:
        raw = pd.DataFrame({"timestamp": ts})
        complete = np.ones(len(ts), dtype=bool)
    issues, horizons = T2.sample(Cell, T.TRAIN_START, T.TRAIN_END, 5, 4, np.random.default_rng(0))
    assert ts.iloc[issues + horizons].max() <= T.TRAIN_END
    issues, horizons = T2.sample(Cell, *T.VAL_CAL, 5, 4, np.random.default_rng(0))
    labels = ts.iloc[issues + horizons]
    assert labels.min() >= T.VAL_CAL[0] and labels.max() <= T.VAL_CAL[1]  # blend fitting rows stay in VAL_CAL


def test_loyo_rho_equals_v2_damping_with_year_masked():
    raw = synthetic_raw()
    frames = {CELL: raw}
    tables = T.build_tables(frames, T.TRAIN_START)
    for year in (2021, 2022, 2023):
        masked = raw.copy()
        cols = list(T.DATA_COLUMNS)
        masked.loc[masked.timestamp.dt.year == year, cols] = np.nan
        expected = T2.damping({CELL: masked}, {CELL: tables["loyo_clim"][CELL][year]})
        for name in M2.TARGETS:
            np.testing.assert_allclose(tables["loyo_rho"][year][name], expected[name], atol=1e-12)
    assert tables["rho_loyo_max_abs_diff"]["temperature"] >= 0


def test_loyo_training_rows_ignore_own_year_labels():
    raw = synthetic_raw()
    issues = np.flatnonzero((raw.timestamp >= "2022-12-28") & (raw.timestamp <= "2022-12-29"))[:10]
    horizons = np.full(len(issues), 120, dtype=np.int32)  # valid in Jan 2023, issue (and its 48h) in 2022

    def rows(frame):
        tables = T.build_tables({CELL: frame}, T.TRAIN_START)
        cd = T.CellData21(CELL, frame, STATIC, tables, T.TRAIN_START)
        x_oof, _, _ = cd.rows_oof(issues, horizons)
        x_full, _, _ = cd.rows(issues, horizons)
        return x_oof, x_full.to_numpy(dtype=np.float32)
    perturbed = raw.copy()
    in_2023 = perturbed.timestamp.dt.year == 2023
    perturbed.loc[in_2023, list(M2.WEATHER_FEATURES)] += 5.0
    a_oof, a_full = rows(raw)
    b_oof, b_full = rows(perturbed)
    cols = [i for i, c in enumerate(M2.feature_columns()) if c.startswith(("base_", "clim_valid_"))]
    np.testing.assert_array_equal(a_oof[:, cols], b_oof[:, cols])
    assert np.abs(a_full[:, cols] - b_full[:, cols]).max() > 0.1


def test_tables_use_train_window_only():
    raw = synthetic_raw("2020-06-01", "2025-03-31 23:00")
    base = T.build_tables({CELL: raw}, T.TRAIN_START, with_loyo=False)
    changed = raw.copy()
    outside = ((changed.timestamp < T.TRAIN_START) | (changed.timestamp > T.TRAIN_END)).to_numpy()
    changed.loc[outside, list(M2.WEATHER_FEATURES)] = 999.0
    other = T.build_tables({CELL: changed}, T.TRAIN_START, with_loyo=False)
    assert other["clim"] == base["clim"] and other["std"] == base["std"] and other["rho"] == base["rho"]
    assert all((np.asarray(v) > 0).all() and len(v) == 288 for v in base["std"][CELL].values())


def test_diurnal_persistence_uses_past_same_clock_hour():
    raw = synthetic_raw("2021-01-01", "2025-02-28 23:00")
    raw["temperature"] = np.arange(len(raw)) * 0.001
    tables = T.build_tables({CELL: raw}, T.TRAIN_START, with_loyo=False)
    cd = T.CellData21(CELL, raw, STATIC, tables, T.TRAIN_START)
    args = argparse.Namespace(threads=1)
    grid = T.eval_grid({CELL: cd}, {}, 500, T.VAL_START, T.VAL_END, args)
    issue_idx = np.round(grid["pers_temperature"].astype(float) / 0.001)
    d_idx = np.round(grid["dpers_temperature"].astype(float) / 0.001)
    h = grid["h"]
    np.testing.assert_array_equal(d_idx, issue_idx + h - 24 * np.ceil(h / 24))
    assert (d_idx <= issue_idx).all()
    assert (d_idx[h == 25] == issue_idx[h == 25] - 23).all()


def test_block_bootstrap_paired_and_deterministic():
    rng = np.random.default_rng(1)
    day = np.repeat(np.arange(60), 20)
    lb = rng.random(len(day))
    a = T.delta_ci(day, lb + 0.1, lb, "mae")
    assert a == T.delta_ci(day, lb + 0.1, lb, "mae")
    assert a["ci95"][0] == pytest.approx(0.1) and a["ci95"][1] == pytest.approx(0.1)
    zero = T.delta_ci(day, lb, lb, "rmse")
    assert zero["delta"] == 0 and zero["ci95"] == [0, 0] and not zero["significant"]
    better = T.delta_ci(day, lb * 0.5, lb, "mae")
    assert better["significant"] and better["ci95"][1] < 0


def test_calibrators_monotone_bounded_and_json_parity():
    rng = np.random.default_rng(2)
    p = rng.random(4000)
    y = (rng.random(4000) < p ** 2).astype(float)
    iso, cal = T.isotonic_fit(p, y)
    grid = np.linspace(-0.2, 1.2, 2001)
    np.testing.assert_allclose(S.calibrator_apply(grid, cal), iso.predict(grid), atol=1e-9)
    a, b = T.platt_fit(p, y)
    assert a > 0
    for c in (cal, {"method": "platt", "a": a, "b": b}):
        out = S.calibrator_apply(np.sort(p), c)
        assert (np.diff(out) >= -1e-15).all() and out.min() >= 0.001 and out.max() <= 0.999


def test_fit_rain_calibration_cross_fit_on_miscalibrated_grid():
    rng = np.random.default_rng(3)
    n_iss = 400
    h = np.tile(np.arange(1, 169), n_iss)
    issue = np.repeat(T.hours(T.VAL_CAL[0]) + np.arange(n_iss) * 4, 168)
    p = rng.random(len(h))
    y = (rng.random(len(h)) < 0.6 * p).astype(float)
    grid = {"h": h, "issue_time": issue, "served_rain_probability": p, "y_rain_probability": y}
    calibration, flags, diag = T.fit_rain_calibration(grid, VERSION)
    assert all(flags.values()) and all(calibration["bands"][b]["method"] in ("platt", "isotonic") for b in S.BANDS)
    assert all(d["cross_fit"]["none"]["brier"] > d["cross_fit"][d["chosen"]]["brier"] for d in diag.values())


def test_conformal_quantile_rank():
    r = np.arange(1, 10, dtype=float)  # n = 9: hi rank ceil(10*0.9)=9, lo rank floor(10*0.1)=1
    assert T.conformal_q(r, 0.8, False) == (1.0, 9.0)
    assert T.conformal_q(np.arange(1, 100, dtype=float), 0.8, False) == (10.0, 90.0)


def test_spatial_buffer_excludes_neighbours():
    statics = {f"c{i}_{j}": {"lat": 10 + 0.07 * i, "lon": 106 + 0.079 * j, "elevation": 0}
               for i in range(6) for j in range(6)}
    statics[T.CON_DAO] = {"lat": 8.68, "lon": 106.59, "elevation": 7}
    folds = T.spatial_folds(statics)["folds"]
    assert folds["con_dao"]["held_out"] == [T.CON_DAO] and len(folds) == 6
    for fold in folds.values():
        for c in fold["train_cells"]:
            for held in fold["held_out"]:
                d = np.hypot(statics[c]["lat"] - statics[held]["lat"], statics[c]["lon"] - statics[held]["lon"])
                assert d > T.BUFFER_DEG
    assert T.spatial_folds(statics) == T.spatial_folds(statics)


def test_ledger_chain_and_write_once(tmp_path):
    ledger = tmp_path / "ledger" / "test_ledger.jsonl"
    seeds = T.ledger_seed(ledger)
    assert [s["program"] for s in seeds] == ["long_range_v1", "long_range_v2", "v3_val_select_overlap"]
    T.ledger_guard(ledger)
    T.ledger_append(ledger, {"program": T.PROGRAM, "model_version": VERSION, "test_spec_sha256": "x"})
    with pytest.raises(RuntimeError, match="exactly once"):
        T.ledger_guard(ledger)
    lines = ledger.read_text().splitlines()
    for i in (0, len(lines) - 1):
        edited = list(lines)
        entry = json.loads(edited[i])
        entry["scored_at"] = "tampered"
        edited[i] = json.dumps(entry, sort_keys=True)
        bad = tmp_path / f"bad{i}.jsonl"
        bad.write_text("\n".join(edited) + "\n")
        with pytest.raises(ValueError, match="chain broken"):
            T.ledger_verify(bad)


def test_second_test_call_with_other_out_refuses(tmp_path):
    ledger = tmp_path / "drive" / "test_ledger.jsonl"
    T.ledger_seed(ledger)
    T.ledger_append(ledger, {"program": T.PROGRAM, "model_version": VERSION})
    out = tmp_path / "another_out"
    out.mkdir()
    (out / "test_spec.json").write_text("{}")
    (out / "metadata.json").write_text(json.dumps({"test_spec_sha256": T.sha256_file(out / "test_spec.json")}))
    (out / "evaluation.json").write_text("{}")
    with pytest.raises(RuntimeError, match="exactly once"):
        T.main(["--phase", "test", "--out", str(out), "--ledger", str(ledger)])
    (out / "metadata.json").write_text(json.dumps({"test_spec_sha256": "0" * 64}))
    with pytest.raises(SystemExit, match="sha256 differs"):
        T.main(["--phase", "test", "--out", str(out), "--ledger", str(tmp_path / "fresh.jsonl")])


def test_final_requires_selection_and_reason(tmp_path):
    with pytest.raises(SystemExit, match="dev_selection"):
        T.main(["--phase", "final", "--out", str(tmp_path / "a")])
    argmin = {n: "damped" for n in M2.TARGETS}
    sel = tmp_path / "dev_selection.json"
    sel.write_text(json.dumps({"argmin": {"long": argmin, "short": argmin}, "train_start": {"decision": "2021-01-01"},
                               "args": {"train_stride": "3"}}))
    other = ",".join(f"{n}=raw" for n in M2.TARGETS)
    args = T.build_parser().parse_args(["--phase", "final", "--out", str(tmp_path / "a"), "--selection", str(sel),
                                        "--modes", other])
    with pytest.raises(SystemExit, match="override-reason"):
        T.resolve_selection(args)
    args.override_reason = "examiner request"
    _, chosen, override = T.resolve_selection(args)
    assert chosen["long"]["temperature"] == "raw" and override["long"]["argmin"] == argmin


def test_npz_and_sqlite_loaders_identical(tmp_path):
    db = tmp_path / "cells.db"
    con = sqlite3.connect(db)
    cols = ", ".join(f'"{c}" REAL' for c in T.DATA_COLUMNS)
    con.execute(f"CREATE TABLE hourly (cell_id TEXT NOT NULL, timestamp TEXT NOT NULL, {cols}, "
                "PRIMARY KEY (cell_id, timestamp))")
    con.execute("CREATE TABLE cells (cell_id TEXT PRIMARY KEY, lat REAL, lon REAL, elevation REAL, source TEXT)")
    rng = np.random.default_rng(4)
    ts = pd.date_range("2024-06-01", periods=500, freq="h")
    for i, cid in enumerate(("om-a", "om-b", "om-c")):
        con.execute("INSERT INTO cells VALUES (?,?,?,?,?)", (cid, 10 + i * 0.1, 106.5, 5.0 + i, "synthetic"))
        for j, t in enumerate(ts):
            if (i, j) in ((1, 7), (2, 100)):
                continue  # missing hour -> NaN in both loaders
            vals = [round(float(v), 1) for v in rng.normal(50, 30, len(T.DATA_COLUMNS))]
            if j == 11:
                vals[0] = None
            vals[T.DATA_COLUMNS.index("pressure_msl")] = round(1000 + rng.random() * 18.9, 1)
            con.execute(f"INSERT INTO hourly VALUES (?,?,{','.join('?' * len(vals))})",
                        (cid, t.strftime("%Y-%m-%d %H:%M:%S"), *vals))
    con.commit()
    con.close()
    out = tmp_path / "export"
    E.main(["--data", str(db), "--out", str(out), "--no-code"])
    lo, hi = ts[0] - pd.Timedelta(hours=3), ts[-1]
    a = T.load_frames(out / "data", lo, hi)
    b = T.load_frames(db, lo, hi)
    assert a[3]["canonical_sha256"] == b[3]["canonical_sha256"] and a[1] == b[1] and a[2] == b[2]
    for cid in b[0]:
        pd.testing.assert_frame_equal(a[0][cid], b[0][cid])
        assert np.isnan(a[0][cid]["temperature"].iloc[3 + 11])
    manifest = json.loads((out / "data" / "manifest.json").read_text())
    assert manifest["float64_fallback"] == {} and manifest["n_hours"] == 500
    with pytest.raises(SystemExit):
        E.main(["--data", str(db), "--out", str(out), "--no-code"])


def _test_ready_out(out: Path) -> None:
    out.mkdir(parents=True)
    (out / "test_spec.json").write_text(json.dumps({"window": [str(T.TEST_START), str(T.TEST_END)],
                                                    "cell_ids": [CELL]}))
    (out / "metadata.json").write_text(json.dumps({"test_spec_sha256": T.sha256_file(out / "test_spec.json"),
                                                   "model_version": VERSION,
                                                   "split": {"train": [str(T.TRAIN_START), str(T.TRAIN_END)]}}))
    (out / "evaluation.json").write_text("{}")


def test_crash_during_test_scoring_consumes_the_test_window(tmp_path, monkeypatch):
    ledger = tmp_path / "drive" / "test_ledger.jsonl"
    out = tmp_path / "art"
    _test_ready_out(out)

    def oom(*_, **__):
        raise MemoryError("simulated Colab OOM after scoring started")
    monkeypatch.setattr(T, "load_frames", oom)
    with pytest.raises(MemoryError):
        T.main(["--phase", "test", "--out", str(out), "--ledger", str(ledger)])
    mine = [e for e in T.ledger_verify(ledger) if e.get("program") == T.PROGRAM]
    assert [e["status"] for e in mine] == ["started"] and mine[0]["model_version"] == VERSION
    with pytest.raises(RuntimeError, match="exactly once"):  # same global ledger
        T.main(["--phase", "test", "--out", str(out), "--ledger", str(ledger)])
    with pytest.raises(RuntimeError, match="exactly once"):  # fresh ledger: the artifact's copy still refuses
        T.main(["--phase", "test", "--out", str(out), "--ledger", str(tmp_path / "fresh.jsonl")])
    with pytest.raises(RuntimeError, match="exactly once"):  # no fresh final + test after the window is used
        T.main(["--phase", "final", "--out", str(tmp_path / "new_art"), "--ledger", str(ledger)])
    assert not (tmp_path / "new_art").exists()
    other = tmp_path / "art2"
    _test_ready_out(other)
    (other / "figures").mkdir()
    with pytest.raises(SystemExit, match="already started"):
        T.main(["--phase", "test", "--out", str(other), "--ledger", str(tmp_path / "fresh2.jsonl")])


def test_spatial_uses_final_sampling_args_and_checks_folds(tmp_path):
    args = T.build_parser().parse_args(["--phase", "spatial", "--out", str(tmp_path)])
    assert args.train_stride == 3
    meta = {"model_version": VERSION, "sampling_args": {"train_stride": 7, "k": args.k},
            "target_mode": {n: "damped" for n in M2.TARGETS}}
    T.apply_sampling_args(args, meta)
    assert args.train_stride == 7
    with pytest.raises(SystemExit, match="sampling_args"):
        T.apply_sampling_args(args, {"model_version": VERSION})
    fold = tmp_path / "spatial" / "block_1"
    fold.mkdir(parents=True)
    (fold / "fold_meta.json").write_text(json.dumps({"model_version": VERSION, "rho": {},
                                                     "config": {"train_stride": 3, "k": args.k}}))
    with pytest.raises(SystemExit, match="other sampling args"):
        T.load_fold_models(tmp_path / "spatial", meta, {"block_1": {"held_out": [CELL]}})


def test_fold_rho_excludes_held_out_cells():
    from types import SimpleNamespace
    a, b = synthetic_raw(), synthetic_raw()
    c = synthetic_raw()
    for frame, shift in ((b, 1.5), (c, -4.0)):
        frame[list(M2.WEATHER_FEATURES)] = frame[list(M2.WEATHER_FEATURES)] * (1 + 0.1 * shift)
    tables = T.build_tables({"a": a, "b": b, "c": c}, T.TRAIN_START)
    cdata = {k: SimpleNamespace(raw=v) for k, v in (("a", a), ("b", b), ("c", c))}
    rho, loyo = T.fold_damping(cdata, tables, {"a", "b"}, T.TRAIN_START)
    only = T.build_tables({"a": a, "b": b}, T.TRAIN_START)
    assert rho == only["rho"] and loyo == only["loyo_rho"]
    perturbed = c.copy()
    perturbed[list(M2.WEATHER_FEATURES)] += np.random.default_rng(9).normal(0, 3, (len(c), len(M2.WEATHER_FEATURES)))
    tables2 = T.build_tables({"a": a, "b": b, "c": perturbed}, T.TRAIN_START)
    cdata["c"] = SimpleNamespace(raw=perturbed)
    assert T.fold_damping(cdata, tables2, {"a", "b"}, T.TRAIN_START)[0] == rho  # held-out labels never enter
    assert tables2["rho"] != tables["rho"]


def test_cross_fit_folds_are_purged():
    issue = T.hours(T.VAL_CAL[0]) + np.arange(0, 1500, 3)
    grid = {"issue_time": np.repeat(issue, 2)}
    fold = T.week_fold(grid)
    assert set(np.unique(fold)) == {0, 1}
    for k in (0, 1):
        tr = T.purged_train(grid, fold, k)
        held = grid["issue_time"][fold == k]
        assert tr.any() and not (tr & (fold == k)).any()
        gaps = np.abs(grid["issue_time"][tr][:, None] - held[None, :]).min(axis=1)
        assert gaps.min() >= T.PURGE_HOURS


def test_components_report_v3_only_when_applied(artifact, monkeypatch):
    monkeypatch.setattr(S, "v3_component", fake_v3_factory([]))
    assert S.predict(history(), CELL)["components"]["v3_applied_targets"] == ["temperature"]
    write_artifact(artifact, {n: {"taper": {"w0": 1.0, "a": 12, "b": 30}} for n in M2.TARGETS}, CAL, INTERVALS)
    S._load.cache_clear()
    out = S.predict(history(), CELL, v3_result={"model_version": "lgbm-hcmc-global-v3-x"})
    assert out["components"] == {"v3_model_version": None, "v3_applied_targets": []}


def test_stable_features_do_not_depend_on_history_length():
    """Trainer (full series) and serving (48 rows) must build bit-identical rolling features."""
    clim = climatology()["cells"][CELL]
    hist = history()
    full = S.stable_issue_features(hist, STATIC, clim)
    short = S.stable_issue_features(hist.iloc[-48:].reset_index(drop=True), STATIC, clim)
    cols = [c for c in full.columns if c.endswith(("_mean_6", "_mean_24", "_std_24"))]
    assert cols
    np.testing.assert_array_equal(full[cols].iloc[-1].to_numpy(), short[cols].iloc[-1].to_numpy())
    v2 = M2.issue_features(hist, STATIC, clim)
    np.testing.assert_allclose(full[cols].iloc[-1].to_numpy(), v2[cols].iloc[-1].to_numpy(), atol=2e-5)
