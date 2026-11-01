"""Serving policy (rain calibration + per-cell fallback), 4-window split and block-bootstrap CIs."""
import json

import numpy as np
import pandas as pd
import pytest
from sklearn.isotonic import IsotonicRegression

import ai_model
from scripts import train_global_v3 as T
from tests.test_train_eval import frame, models_for


def test_isotonic_calibration_matches_sklearn_and_platt_is_monotone():
    rng = np.random.default_rng(0)
    p = rng.random(4000)
    y = (rng.random(4000) < p ** 2).astype(float)
    cal = T.fit_calibrators(p, y)
    iso = IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1).fit(p, y)
    q = np.r_[rng.random(500), 0.0, 1.0, -0.2, 1.3]
    np.testing.assert_allclose(ai_model.calibrate_rain(q, cal["isotonic"]), iso.predict(np.clip(q, 0, 1)))
    pl = ai_model.calibrate_rain(np.linspace(0, 1, 50), cal["platt"])
    assert (np.diff(pl) >= 0).all() and pl.min() >= 0 and pl.max() <= 1
    np.testing.assert_array_equal(ai_model.calibrate_rain(q, cal["none"]), np.clip(q, 0, 1))
    with pytest.raises(ValueError):
        ai_model.calibrate_rain([0.5], {"method": "magic"})


def test_apply_policy_fallback_only_touches_listed_cells_and_horizons():
    policy = {"rain_calibration": {}, "fallback": {"om-x": {"1h": {"temperature_weight": 0.25, "rain_weight": 0.5}}}}
    cells = ["om-x", "om-y"]
    t, p = ai_model.apply_policy(policy, 1, cells, [30.0, 30.0], [0.2, 0.2], [26.0, 26.0], [1.0, 1.0])
    assert t.tolist() == [27.0, 30.0] and p.tolist() == [0.6, 0.2]
    t3, p3 = ai_model.apply_policy(policy, 3, cells, [30.0, 30.0], [0.2, 0.2], [26.0, 26.0], [1.0, 1.0])
    assert t3.tolist() == [30.0, 30.0] and p3.tolist() == [0.2, 0.2]
    t0, p0 = ai_model.apply_policy(None, 1, cells, [30.0, 30.0], [1.2, -0.1], [26.0, 26.0], [0.0, 0.0])
    assert t0.tolist() == [30.0, 30.0] and p0.tolist() == [1.0, 0.0]   # identity (clipped) without a policy


def test_policy_file_is_ignored_for_another_model_version(tmp_path, monkeypatch):
    monkeypatch.setattr(ai_model, "V3_DIR", str(tmp_path))
    assert ai_model._load_policy({"model_version": "m1"}) == {}            # old artifact: no file
    pol = {"model_version": "m1", "rain_calibration": {"1h": {"method": "platt", "a": 1.0, "b": 0.0}}}
    (tmp_path / ai_model.POLICY_FILE).write_text(json.dumps(pol), encoding="utf-8")
    assert ai_model._load_policy({"model_version": "m1"}) == pol
    assert ai_model._load_policy({"model_version": "m2"}) == {}


def test_four_windows_are_ordered_disjoint_and_gapped():
    gap = pd.Timedelta(days=7)
    assert T.TRAIN_END + gap < T.VAL_ES_START < T.VAL_ES_END
    assert T.VAL_ES_END + gap < T.VAL_SEL_START < T.VAL_SEL_END
    assert T.VAL_SEL_END + gap < T.TEST_START
    d = frame(start="2023-09-01", days=800)
    train, es, sel, test = T.split(d)
    tgt = lambda x: x.timestamp + pd.Timedelta(hours=T.MAXH)   # noqa: E731
    assert tgt(train).max() <= T.TRAIN_END
    assert es.timestamp.min() >= T.VAL_ES_START and tgt(es).max() <= T.VAL_ES_END
    assert sel.timestamp.min() >= T.VAL_SEL_START and tgt(sel).max() <= T.VAL_SEL_END
    assert test.timestamp.min() >= T.TEST_START
    assert len(set(train.index) | set(es.index) | set(sel.index) | set(test.index)) == \
        len(train) + len(es) + len(sel) + len(test)


def test_block_bootstrap_ci_brackets_point_and_matches_pooled_metrics():
    train, test = frame(start="2023-07-01", days=62, seed=1), frame(days=60, seed=3)
    clim = T.climatology(train)
    thr = {f"{h}h": 0.2 for h in T.HORIZONS}
    clim_thr = T.climatology_thresholds(test, clim)
    models = models_for(test, temp_offset=0.3)
    frames = {h: T.score_frame(models, test, clim, h, None, cols=["temperature"]) for h in T.HORIZONS}
    ci = T.block_bootstrap_ci(frames, thr, clim_thr, n_boot=200)
    for h in T.HORIZONS:
        f = frames[h]
        assert ci[f"{h}h"]["mae_model"]["value"] == pytest.approx(np.abs(f.y_t - f.m_t).mean(), abs=1e-5)
        assert ci[f"{h}h"]["f1_model"]["value"] == pytest.approx(T.f1(f.y_r, f.m_p >= 0.2), abs=1e-5)
    for k, v in ci["all"].items():
        lo, hi = v["ci95"]
        assert lo - 1e-9 <= hi, k
    days = pd.to_datetime(frames[1].timestamp).dt.floor("D")
    assert ci["days"] == days.nunique() and ci["blocks"] == (days.max() - days.min()).days // T.BLOCK_DAYS + 1
    assert ci["n_boot"] == 200


def test_fallback_blends_with_persistence_where_the_model_loses():
    val = frame(days=40, seed=4)
    clim = T.climatology(frame(start="2023-07-01", days=62, seed=1))
    clim_thr = T.climatology_thresholds(val, clim)
    thr = {f"{h}h": 0.2 for h in T.HORIZONS}
    models = models_for(val, temp_offset=1.5)          # biased 'model': persistence + 1.5 degC
    preds = T.predict_raw(models, val, ["temperature"])
    rules, analysis = T.choose_fallback(models, thr, val, clim, clim_thr, None, preds)
    assert analysis and all("mae" in a["fails"] for a in analysis)
    for cid, r in rules.items():
        for h, rule in r.items():
            assert rule["temperature_weight"] == 0.0     # pure persistence removes the bias


def test_interval_evaluation_uses_served_point_and_horizon_target_mask(monkeypatch):
    from scripts import train_global_v3_interval as interval
    from tests.test_train_eval import Const

    monkeypatch.setattr(interval, "feature_columns_v3", lambda: ["temperature", "precipitation"])
    monkeypatch.setattr(interval.joblib, "load", lambda _: Const(8.0))
    X = np.array([[20.0, 0.0], [25.0, 1.0]])
    meta = pd.DataFrame({"cell_id": ["om-x", "om-y"], "y1": [1.0, 2.0], "y3": [np.nan, 2.0], "y6": [1.0, 2.0]})
    policy = {"fallback": {"om-x": {"1h": {"temperature_weight": 0.25}}}}
    result = interval.point_preds(X, meta, np.ones(2, bool), policy)
    np.testing.assert_allclose(result, [22.0, 33.0, 33.0, 28.0, 33.0])
    temp, _ = ai_model.apply_policy(policy, 1, meta.cell_id, [28.0, 33.0], [0.0, 0.0], X[:, 0], X[:, 1])
    np.testing.assert_array_equal(result[:2], temp)


def test_serving_policy_selection_rule_and_booster_source():
    policy = ai_model._load_policy({"model_version": "lgbm-hcmc-global-v3-20261023"})
    assert "selection_rule" in policy
    sr = policy["selection_rule"]
    assert "decisions" in sr and "booster_source" in sr
    for k in ("temperature_1h", "rain_1h", "temperature_3h", "rain_3h", "temperature_6h", "rain_6h"):
        assert k in sr["decisions"]
        decision = sr["decisions"][k]
        assert "selected" in decision
        assert sr["booster_source"][k] == "v3"

