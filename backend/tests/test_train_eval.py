"""Evaluation methodology of scripts/train_global_v3.py on tiny synthetic frames (no training)."""
import json

import joblib
import numpy as np
import pandas as pd
import pytest

from scripts import train_global_v3 as T


class Const:
    """Stands in for a LightGBM booster: predicts column 0 (+ offset)."""

    def __init__(self, offset=0.0):
        self.offset = offset

    def predict(self, X):
        return X[:, 0] + self.offset


class Flat:
    """Constant rain probability."""

    def __init__(self, p):
        self.p = p

    def predict(self, X):
        return np.full(len(X), self.p)


def frame(cells=("om-a", "om-b"), start="2024-07-08", days=40, seed=0):
    """Hourly rows with a ~15 % rainy afternoon pattern; 'temperature' doubles as the only feature."""
    rng = np.random.default_rng(seed)
    out = []
    for cid in cells:
        ts = pd.date_range(start, periods=24 * days, freq="h")
        afternoon = (ts.hour >= 13) & (ts.hour <= 17)
        rain = rng.random(len(ts)) < np.where(afternoon, 0.3, 0.05)
        temp = 28 + 3 * np.sin(2 * np.pi * ts.hour / 24) + rng.normal(0, 0.3, len(ts))
        d = pd.DataFrame({"timestamp": ts, "cell_id": cid, "temperature": temp,
                          "precipitation": np.where(rain, 1.0, 0.0)})
        for h in T.HORIZONS:
            d[f"temp_target_{h}h"] = d.temperature.shift(-h)
            d[f"rain_target_{h}h"] = (d.precipitation.shift(-h) > 0.1).astype(float).where(d.precipitation.shift(-h).notna())
        out.append(d.dropna())
    return pd.concat(out, ignore_index=True)


def rain_model(data):
    """A probabilistic 'model' that knows the afternoon pattern (column 0 = temperature is ignored)."""
    class P:
        def __init__(self, h):
            self.h = h

        def predict(self, X):
            hour = (data.timestamp + pd.Timedelta(hours=self.h)).dt.hour.values[:len(X)]
            return np.where((hour >= 13) & (hour <= 17), 0.3, 0.05)
    return P


def models_for(data, temp_offset=0.0):
    P = rain_model(data)
    return {**{f"temp_{h}h": Const(temp_offset) for h in T.HORIZONS}, **{f"rain_{h}h": P(h) for h in T.HORIZONS}}


def test_climatology_rain_baseline_threshold_is_tuned_on_val():
    train, val = frame(start="2023-07-01", days=62, seed=1), frame(seed=2)
    clim = T.climatology(train)
    thr = T.climatology_thresholds(val, clim)
    # rain frequency never reaches 0.5, so the old fixed 0.5 threshold gave F1 = 0 for every cell
    assert (clim.rain < 0.5).all()
    assert all(0.05 <= t < 0.5 for t in thr.values())
    m = T.evaluate(models_for(val), {f"{h}h": 0.2 for h in T.HORIZONS}, val, clim, thr, cols=["temperature"])
    assert (m.f1_climatology > 0.3).all()
    fixed = T.evaluate(models_for(val), {f"{h}h": 0.2 for h in T.HORIZONS}, val, clim,
                       {f"{h}h": 0.5 for h in T.HORIZONS}, cols=["temperature"])
    assert (fixed.f1_climatology == 0).all()


def test_brier_and_skill_are_reported_and_gate_beats_baselines():
    train, val = frame(start="2023-07-01", days=62, seed=1), frame(seed=2)
    clim = T.climatology(train)
    thr = T.climatology_thresholds(val, clim)
    m = T.evaluate(models_for(val), {f"{h}h": 0.2 for h in T.HORIZONS}, val, clim, thr, cols=["temperature"])
    assert {"brier_v3", "brier_climatology", "brier_skill"} <= set(m.columns)
    np.testing.assert_allclose(m.brier_skill, 1 - m.brier_v3 / m.brier_climatology)
    e = T.entry("om-a", m[m.cell_id == "om-a"], "p", False, "test")
    for h in ("1h", "3h", "6h"):
        assert {f"rain_brier_uncalibrated_{h}", f"baseline_climatology_brier_{h}",
                f"rain_brier_skill_uncalibrated_{h}"} <= set(e)
    # the "model" equals climatology for rain: F1 not strictly above the tuned baseline -> no win
    assert e["beats_baselines"] is False
    s = T.mean_score(m)
    assert s["beats_baselines"] is False and abs(s["rain_brier_skill"]) < 0.2


def test_selection_scores_both_models_on_the_same_val_rows(tmp_path, monkeypatch):
    train, val = frame(start="2023-07-01", days=365, seed=1), frame(start="2024-10-01", seed=2)
    clim = T.climatology(train)
    thr = T.climatology_thresholds(val, clim)
    served = tmp_path / "v3"
    served.mkdir()
    for h in T.HORIZONS:
        joblib.dump(Const(0.5), served / f"temperature_model_{h}h.pkl")
        joblib.dump(Flat(0.1), served / f"rain_model_{h}h.pkl")
    (served / "feature_columns.json").write_text(json.dumps(["temperature"]), encoding="utf-8")
    (served / "metadata_v3.json").write_text(json.dumps(
        {"model_version": "served-1", "rain_decision_threshold": {f"{h}h": 0.5 for h in T.HORIZONS}}),
        encoding="utf-8")
    cand = models_for(val)
    monkeypatch.setattr(T, "feature_columns_v3", lambda: ["temperature"])
    sel = T.selection(cand, {f"{h}h": 0.2 for h in T.HORIZONS}, val, clim, thr, served)
    assert sel["split"] == "val_select" and sel["current_model_version"] == "served-1"
    assert sel["window"] == [str(T.VAL_SEL_START), str(T.VAL_SEL_END)]
    assert sel["candidate"]["rows"] == sel["current"]["rows"] and sel["candidate"]["cells"] == sel["current"]["cells"]
    assert sel["candidate"]["temperature_mae"] < sel["current"]["temperature_mae"]   # served is biased by 0.5
    # baselines are the same numbers for both (same rows, same climatology threshold)
    for k in ("baseline_climatology_f1", "baseline_persistence_mae", "baseline_climatology_brier"):
        assert sel["candidate"][k] == sel["current"][k]
    assert sel["candidate"]["rain_f1"] > sel["current"]["rain_f1"]
    assert sel["candidate"]["evaluation_rows_sha256"] == sel["current"]["evaluation_rows_sha256"]
    metadata = served / "metadata_v3.json"
    meta = json.loads(metadata.read_text())
    meta["split"] = {"val": ["2024-07-01", "2024-10-10 23:00:00"]}
    metadata.write_text(json.dumps(meta))
    purged = T.selection(cand, {f"{h}h": 0.2 for h in T.HORIZONS}, val, clim, thr, served)
    assert purged["window"][0] == "2024-10-18 00:00:00"
    assert purged["candidate"]["rows"] == purged["current"]["rows"] < sel["candidate"]["rows"]
    alone = T.selection(cand, {f"{h}h": 0.2 for h in T.HORIZONS}, val, clim, thr, None)
    assert alone["current"] is None and alone["current_error"]


def test_late_cells_use_only_final_test_targets():
    regular = frame(start="2025-10-01", days=40, cells=("regular",))
    limited = frame(start="2025-10-01", days=10, cells=("limited",))
    no_test = frame(start="2024-10-01", days=40, cells=("no-test",))
    _, _, val, test = T.split(pd.concat([regular, limited, no_test], ignore_index=True))
    assert T.evaluation_cells(test) == (["regular"], ["limited"])
    assert set(val.cell_id) == {"no-test"}
    assert test.timestamp.min() >= T.TEST_START
    # Rows with features but no targets cannot qualify as 30 days of test coverage.
    regular.loc[:, T.target_cols()] = np.nan
    assert T.evaluation_cells(regular) == ([], [])


def test_nonfinite_predictions_fail_evaluation():
    import pytest

    data = frame()
    clim = T.climatology(frame(start="2023-07-01", days=62))
    models = models_for(data)
    models["temp_1h"] = Flat(float("nan"))
    with pytest.raises(ValueError, match="non-finite"):
        T.evaluate(models, {f"{h}h": 0.2 for h in T.HORIZONS}, data, clim,
                   T.climatology_thresholds(data, clim), cols=["temperature"])


def test_saved_incumbent_uses_legacy_calibration_but_never_selection_fallback(tmp_path):
    from sklearn.isotonic import IsotonicRegression
    import ai_model

    for h in T.HORIZONS:
        joblib.dump(Const(), tmp_path / f"temperature_model_{h}h.pkl")
        joblib.dump(Flat(0.2), tmp_path / f"rain_model_{h}h.pkl")
    (tmp_path / "feature_columns.json").write_text(json.dumps(["temperature"]))
    (tmp_path / "metadata_v3.json").write_text(json.dumps({
        "model_version": "old", "rain_decision_threshold": {f"{h}h": 0.2 for h in T.HORIZONS}}))
    ext = {"base_model_version": "old", "rain_calibration": {"per_horizon": {
        f"{h}h": {"applied": h == 1} for h in T.HORIZONS}}}
    (tmp_path / "extension_v3.json").write_text(json.dumps(ext))
    iso = IsotonicRegression(out_of_bounds="clip").fit([0.0, 0.2, 1.0], [0.0, 0.4, 1.0])
    joblib.dump(iso, tmp_path / "rain_calibrator_1h.pkl")
    policy = T.load_served(tmp_path)[-1]
    np.testing.assert_allclose(ai_model.calibrate_rain([0.2], policy["rain_calibration"]["1h"]), iso.predict([0.2]))
    modern = {"model_version": "old", "rain_calibration": {"1h": {"method": "none"}},
              "fallback": {"om-a": {"1h": {"temperature_weight": 0.0}}}}
    (tmp_path / ai_model.POLICY_FILE).write_text(json.dumps(modern))
    assert T.load_served(tmp_path)[-1] == {"rain_calibration": {"1h": {"method": "none"}}}


def test_extension_merge_preserves_all_base_rain_metrics():
    from scripts import train_global_v3_ext as ext

    base = {f"{name}_{h}h": value for h in T.HORIZONS for name, value in {
        "rain_brier": 0.1, "rain_brier_uncalibrated": 0.12, "baseline_climatology_brier": 0.2,
        "rain_brier_skill": 0.5, "rain_brier_skill_uncalibrated": 0.4,
        "rain_f1": 0.7, "baseline_climatology_f1": 0.5}.items()}
    rows = []
    for h in T.HORIZONS:
        row = {"cell_id": "om-a", "horizon": f"{h}h", "cov": 0.8, "cov_raw": 0.7, "width": 2.0,
               "brier_served": 0.11, "brier_raw": 0.13, "brier_clim": 0.25, "ece_served": 0.02}
        for name in ext.NEW_TARGETS:
            for metric in ("mae", "rmse"):
                row.update({f"{name}_{metric}_m": 0.1, f"{name}_{metric}_p": 0.3, f"{name}_{metric}_c": 0.4})
        rows.append(row)
    ev = {"om-a": dict(base), "tsn": dict(base, alias_of="om-a")}
    ext.merge_evaluation(ev, pd.DataFrame(rows), ["temperature", "humidity"])
    for entry in ev.values():
        assert {k: entry[k] for k in base} == base
        assert entry["temperature_interval_coverage_1h"] == 0.8
        assert entry["rain_ece_1h"] == 0.02
        assert entry["beats_baselines_humidity"] is True


def _interval_search_stubs(monkeypatch, coverage):
    from scripts import train_global_v3_interval as interval

    monkeypatch.setattr(interval, "calibrate", lambda cal, variant, scale, level: level)
    monkeypatch.setattr(interval, "apply", lambda data, level, *_: (np.array([level]), np.array([level])))
    monkeypatch.setattr(interval, "summarize", lambda data, lo, hi: (coverage(float(lo[0])), None, None, None))
    return interval


def test_interval_search_selects_only_passing_configurations(monkeypatch):
    def coverage(level):
        good = level >= 0.92
        return pd.DataFrame({"cov_mean": [0.91 if good else 0.89] * 3, "cov_min": [0.86] * 3,
                             "width": [{0.9: 0.1, 0.91: 0.2, 0.92: 3, 0.93: 2, 0.94: 4}[level]] * 3},
                            index=T.HORIZONS)

    interval = _interval_search_stubs(monkeypatch, coverage)
    grid, best = interval.search(None, None, ["const"])
    assert best["pass"] and best.level == 0.93 and best.width == 2
    assert grid[~grid["pass"]].width.min() < best.width


@pytest.mark.parametrize("mean,minimum", [(0.89, 0.86), (0.91, 0.84), (float("nan"), 0.86)])
def test_interval_search_rejects_all_failing_configurations(monkeypatch, mean, minimum):
    interval = _interval_search_stubs(monkeypatch, lambda _: pd.DataFrame({
        "cov_mean": [mean] * 3, "cov_min": [minimum] * 3, "width": [1.0] * 3}, index=T.HORIZONS))
    with pytest.raises(ValueError, match="No interval configuration meets"):
        interval.search(None, None, ["const"])


def test_failed_interval_search_keeps_existing_published_artifacts(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from unittest.mock import Mock

    interval = _interval_search_stubs(monkeypatch, lambda _: pd.DataFrame({
        "cov_mean": [0.89] * 3, "cov_min": [0.84] * 3, "width": [1.0] * 3}, index=T.HORIZONS))
    (tmp_path / "metadata_v3.json").write_text(json.dumps({"data_snapshot": {}, "test_cells": ["om-a"]}))
    (tmp_path / "cell_static.json").write_text("{}")
    artifacts = ("extension_v3.json", "evaluation_v3.json", "temperature_q05_model_1h.pkl",
                 "interval_backtest_grid.csv", "interval_test_diagnostics.csv")
    for name in artifacts:
        (tmp_path / name).write_bytes(b"existing test artifact")
    original = {name: (tmp_path / name).read_bytes() for name in artifacts}
    for key in ("OUT", "OUTW", "LOG"):
        monkeypatch.setattr(interval, key, getattr(interval, key))
    monkeypatch.setattr(interval.sys, "argv", ["train_global_v3_interval.py", "--out", str(tmp_path)])
    monkeypatch.setattr(interval.sqlite3, "connect", Mock(return_value=Mock()))
    meta = pd.DataFrame({"timestamp": pd.to_datetime(["2024-01-01"]), "cell_id": ["om-a"],
                         **{f"y{h}": [30.0] for h in T.HORIZONS}})
    monkeypatch.setattr(interval, "load", Mock(return_value=(np.zeros((1, 1)), meta)))
    monkeypatch.setattr(interval, "fit", Mock(return_value=SimpleNamespace(best_iteration=1)))
    monkeypatch.setattr(interval, "train_set", Mock(return_value={}))
    monkeypatch.setattr(interval, "frame", Mock(return_value=None))
    monkeypatch.setattr(interval, "log", lambda _: None)
    dump = Mock(side_effect=AssertionError("failed coverage must not publish models"))
    monkeypatch.setattr(interval.joblib, "dump", dump)
    with pytest.raises(ValueError, match="No interval configuration meets"):
        interval.main()
    dump.assert_not_called()
    assert {name: (tmp_path / name).read_bytes() for name in artifacts} == original
