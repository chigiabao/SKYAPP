"""Global v3 model: output format, no look-ahead leakage, v2 fallback, evaluation_for."""
import json
import os

import pandas as pd
import pytest

import ai_model
from conftest import LAST_TS, freeze_now, write_db
from database import LOCAL_TZ

TSN_CELL = "om-10.7909-106.6313"
T = "2023-06-20 12:00:00"
V3_READY = os.path.exists(os.path.join(ai_model.V3_DIR, "temperature_model_1h.pkl"))
needs_v3 = pytest.mark.skipif(not V3_READY, reason="v3 model files not trained yet")


@pytest.fixture(autouse=True)
def _fresh_v3_cache():
    ai_model.reset_v3_cache()
    yield
    ai_model.reset_v3_cache()


def _hist(tmp_path, syn_rows, until=T, hours=ai_model.MIN_HISTORY_HOURS):
    db = tmp_path / f"h{hours}.db"
    if not db.exists():
        write_db(db, syn_rows)
    return ai_model.load_history_from_db(str(db), until=pd.Timestamp(until).to_pydatetime(), hours=hours)


V3_EXT_READY = os.path.exists(os.path.join(ai_model.V3_DIR, "extension_v3.json"))
needs_ext = pytest.mark.skipif(not (V3_READY and V3_EXT_READY), reason="v3 extension not trained yet")
OLD_KEYS = {"temperature", "rain_probability"}
EXT_KEYS = {"temperature_low", "temperature_high", "interval_level",
            "temperature_p10", "temperature_p90", "uncertainty_note"}   # p10/p90: deprecated aliases


def _check_format(out):
    """v2 format (exact) - also the v3 format when the extension is not available."""
    assert set(out) == {"issued_at", "predictions", "model_version"}
    assert set(out["predictions"]) == {"1h", "3h", "6h"}
    for p in out["predictions"].values():
        assert set(p) == OLD_KEYS
        assert isinstance(p["temperature"], float) and 10 < p["temperature"] < 45
        assert 0 <= p["rain_probability"] <= 1


def _check_format_v3(out):
    """v3: old keys unchanged + enabled_targets; with the extension also interval / note / enabled targets."""
    assert set(out) == {"issued_at", "predictions", "model_version", "enabled_targets"}
    assert set(out["predictions"]) == {"1h", "3h", "6h"}
    extra = set(out["enabled_targets"]) & set(ai_model.EXT_TARGETS)
    has_ext = "temperature_interval" in out["enabled_targets"]
    for p in out["predictions"].values():
        assert set(p) == OLD_KEYS | ((EXT_KEYS | extra) if has_ext else set())
        assert isinstance(p["temperature"], float) and 10 < p["temperature"] < 45
        assert 0 <= p["rain_probability"] <= 1
        if has_ext:
            assert p["temperature_low"] <= p["temperature"] <= p["temperature_high"]
            assert (p["temperature_p10"], p["temperature_p90"]) == (p["temperature_low"], p["temperature_high"])
            assert 0.85 <= p["interval_level"] <= 0.95
            assert isinstance(p["uncertainty_note"], str) and (
                "khoảng ~88%" in p["uncertainty_note"]
                or "khoảng ~89%" in p["uncertainty_note"]
                or "khoảng tin cậy 90%" in p["uncertainty_note"]
            )
        if "humidity" in extra:
            assert 0 <= p["humidity"] <= 100
        for k in extra - {"humidity"}:
            assert p[k] >= 0


@needs_v3
@pytest.mark.parametrize("cell", ["tsn", TSN_CELL, "om-8.6819-106.5892", "om-11.0018-106.6755"])
def test_v3_output_format(tmp_path, syn_rows, cell):
    out = ai_model.predict_for_location(_hist(tmp_path, syn_rows), cell)
    _check_format_v3(out)
    assert out["issued_at"] == pd.Timestamp(T).isoformat()
    assert "v3" in out["model_version"]


@needs_v3
def test_v3_static_features_matter_and_alias(tmp_path, syn_rows):
    h = _hist(tmp_path, syn_rows)
    assert ai_model.predict_for_location(h, "tsn") == ai_model.predict_for_location(h, TSN_CELL)
    assert ai_model.predict_for_location(h, TSN_CELL) != ai_model.predict_for_location(h, "om-8.6819-106.5892")


@needs_v3
def test_v3_no_future_leak(tmp_path, syn_rows):
    """Rows after the issue time must not change the forecast (load cut vs full DB)."""
    full = write_db(tmp_path / "full.db", syn_rows)
    cut = write_db(tmp_path / "cut.db", [r for r in syn_rows if r["timestamp"] <= T])
    until = pd.Timestamp(T).to_pydatetime()
    a = ai_model.predict_for_location(ai_model.load_history_from_db(str(full), until=until), TSN_CELL)
    b = ai_model.predict_for_location(ai_model.load_history_from_db(str(cut), until=until), TSN_CELL)
    assert a == b
    # perturbing a future row inside the frame passed in would be caught: features use rows <= t only
    h = ai_model.load_history_from_db(str(full), until=until, hours=60)
    f = ai_model.build_features_v3(h, ai_model._v3["static"][TSN_CELL])
    pert = h.copy()
    pert.loc[pert.index[-6:], ["temperature", "precipitation", "humidity"]] = 99.0
    g = ai_model.build_features_v3(pert, ai_model._v3["static"][TSN_CELL])
    i = len(h) - 7
    pd.testing.assert_series_equal(f.iloc[i], g.iloc[i])


@needs_v3
def test_v3_rejects_bad_history(tmp_path, syn_rows):
    h = _hist(tmp_path, syn_rows)
    with pytest.raises(ValueError):
        ai_model.predict_for_location(h.iloc[-20:], TSN_CELL)
    with pytest.raises(ValueError, match="contiguous"):
        ai_model.predict_for_location(_hist(tmp_path, syn_rows, hours=60).drop(index=10), TSN_CELL)


def test_fallback_to_v2_when_v3_missing(tmp_path, syn_rows, monkeypatch):
    h = _hist(tmp_path, syn_rows)
    monkeypatch.setattr(ai_model, "V3_DIR", str(tmp_path / "no_v3"))
    for cell in ("tsn", TSN_CELL):
        out = ai_model.predict_for_location(h, cell)
        assert out == ai_model.predict_from_history(h)
        _check_format(out)
    with pytest.raises(ValueError, match="v2 supports TSN only"):
        ai_model.predict_for_location(h, "om-8.6819-106.5892")
    assert ai_model.evaluation_for("tsn") is None


@needs_v3
def test_unknown_cell_cannot_fallback_to_v2(tmp_path, syn_rows):
    h = _hist(tmp_path, syn_rows)
    for cell in ("om-0.0-0.0", None):
        with pytest.raises(ValueError, match="v2 supports TSN only"):
            ai_model.predict_for_location(h, cell)


@needs_v3
def test_evaluation_for():
    with open(os.path.join(ai_model.V3_DIR, "evaluation_v3.json"), encoding="utf-8") as f:
        ev = json.load(f)
    tsn = ai_model.evaluation_for("tsn")
    assert tsn is not None and tsn["cell_id"] == "tsn"
    base = ai_model.evaluation_for(TSN_CELL)
    assert base["cell_id"] == TSN_CELL
    for e in (tsn, base):
        for h in ("1h", "3h", "6h"):
            assert isinstance(e[f"temperature_mae_{h}"], float)
            assert 0 <= e[f"rain_f1_{h}"] <= 1
        assert isinstance(e["beats_baselines"], bool) and isinstance(e["holdout"], bool)
        a, b = e["test_period"].split("..")
        assert pd.Timestamp(a) < pd.Timestamp(b) and len(a) == len(b) == 10
    assert ai_model.evaluation_for("om-0.0-0.0") is None
    assert ai_model.evaluation_for(None) is None
    assert ai_model.evaluation_for("om-8.6819-106.5892")["holdout"] is True
    assert len([k for k in ev if k != "tsn"]) == 67
    # returned dict is a copy: mutating it does not change later answers
    tsn["temperature_mae_1h"] = -1
    assert ai_model.evaluation_for("tsn")["temperature_mae_1h"] != -1


def test_v2_api_unchanged(tmp_path, syn_rows):
    h = _hist(tmp_path, syn_rows)
    out = ai_model.predict_from_history(h)
    _check_format(out)
    assert "v2" in out["model_version"]


# ---------------------------------------------------------------- v3 extension (interval, gate, new targets)
def _ext():
    with open(os.path.join(ai_model.V3_DIR, "extension_v3.json"), encoding="utf-8") as f:
        return json.load(f)


@needs_ext
def test_ext_serving_gate_is_respected(tmp_path, syn_rows):
    """Only targets that beat both baselines in >= 80 % of cells are enabled and returned."""
    ext = _ext()
    for t, g in ext["gate"].items():
        assert g["enabled"] == (g["share"] >= 0.8) == (t in ext["enabled_targets"])
        assert g["cells"] == 67 and g["cells_won"] == round(g["share"] * 67)
    out = ai_model.predict_for_location(_hist(tmp_path, syn_rows), TSN_CELL)
    assert out["enabled_targets"] == ext["enabled_targets"]
    for p in out["predictions"].values():
        for t in ai_model.EXT_TARGETS:
            assert (t in p) == (t in ext["enabled_targets"])


@needs_ext
def test_ext_without_extension_files_keeps_old_format(tmp_path, syn_rows, monkeypatch):
    h = _hist(tmp_path, syn_rows)
    full = ai_model.predict_for_location(h, TSN_CELL)
    ai_model.reset_v3_cache()
    monkeypatch.setattr(ai_model, "_load_v3_ext", lambda: None)
    base = ai_model.predict_for_location(h, TSN_CELL)
    assert base["enabled_targets"] == ["temperature", "rain_probability"]
    for k, p in base["predictions"].items():
        assert set(p) == OLD_KEYS
        assert p["temperature"] == full["predictions"][k]["temperature"]
    _check_format({k: v for k, v in base.items() if k != "enabled_targets"})


def test_temperature_interval_contains_point():
    lo, hi = ai_model.temperature_interval([30.0, 29.0], [31.0, 28.0], [30.5, 30.0], 0.0)
    assert list(lo) == [30.0, 28.0] and list(hi) == [31.0, 30.0]
    lo, hi = ai_model.temperature_interval([30.0], [31.0], [30.5], -2.0)   # negative conformal offset
    assert lo[0] == hi[0] == 30.5
    lo, hi = ai_model.temperature_interval([30.0], [31.0], [30.5], 0.25)
    assert (lo[0], hi[0]) == (29.75, 31.25)


def _cutoff_meta(monkeypatch, extension=None):
    monkeypatch.setattr(ai_model, "_load_v3", lambda: True)
    monkeypatch.setattr(ai_model, "_v3", {
        "static": {TSN_CELL: {}},
        "meta": {"split": {"train_end": "2024-06-30 23:00", "val": ["2024-07-08", "2024-12-24 23:00"],
                           "test_end": "2026-10-16 23:00"}},
        "ext": extension,
    })


@pytest.mark.parametrize("selection_split", [None, "validation"])
def test_verification_cutoff_includes_selection_and_promotion(monkeypatch, selection_split):
    ext = {"interval": {"conformal": {}}}
    if selection_split:
        ext.update(gate_selection_split=selection_split, selection_cutoff="2024-12-24 23:00")
    _cutoff_meta(monkeypatch, {"meta": ext})
    assert ai_model.verification_cutoff("tsn") == "2026-10-16T23:00:00"


def test_verification_cutoff_includes_all_interval_tuning_windows(monkeypatch):
    windows = {w: [None, "2024-12-24 23:00"] for w in
               ("qtrain", "es_fit", "es", "cal", "bt_train", "bt_cal", "bt_test")}
    windows["bt_test"][1] = "2027-02-01T12:00:00+07:00"
    _cutoff_meta(monkeypatch, {"meta": {"interval": {"version": 2, "split": windows}}})
    assert ai_model.verification_cutoff(TSN_CELL) == "2027-02-01T12:00:00"
    del windows["cal"]
    with pytest.raises(ValueError, match="cutoff unavailable"):
        ai_model.verification_cutoff(TSN_CELL)


def test_verification_cutoff_v2_unknown_cell_and_missing_provenance(monkeypatch):
    _cutoff_meta(monkeypatch)
    monkeypatch.setattr(ai_model, "_load_models", lambda: None)
    monkeypatch.setattr(ai_model, "_meta", {w: ["2020-01-01", end] for w, end in
                                         (("train", "2023-12-31 17:00"), ("val", "2024-12-31 17:00"),
                                          ("test", "2026-10-10 17:00"))})
    assert ai_model.verification_cutoff("unknown-cell") == "2026-10-10T23:00:00"
    ai_model._meta.pop("test")
    with pytest.raises(ValueError, match="cutoff unavailable"):
        ai_model.verification_cutoff("unknown-cell")


def test_conformal_interval_groups_and_point():
    lo, hi = ai_model.conformal_interval([30.0, 29.0], [31.0, 28.0], [0.5, 0.0], "abs", [30.5, 30.0])
    assert list(lo) == [29.5, 28.0] and list(hi) == [31.5, 30.0]
    lo, hi = ai_model.conformal_interval([30.0], [31.0], [0.5], "norm")          # scaled by q95 - q05
    assert (lo[0], hi[0]) == (29.5, 31.5)
    lo, hi = ai_model.conformal_interval([30.0], [31.0], [-2.0], "abs", [30.2])   # never inverted
    assert lo[0] <= 30.2 <= hi[0]
    st = {"a": {"lat": 10.8, "dist_to_coast_km": 50}, "b": {"lat": 8.7, "dist_to_coast_km": 1}}
    k = ai_model.interval_group_keys("coast_month", [1, 6], ["a", "b"], [7, 1], [13, 2], st)
    assert list(k) == ["1|inland|m7", "6|island|m1"]
    assert list(ai_model.interval_group_keys("month_hour", [3], ["a"], [12], [23], st)) == ["3|m12|b3"]


@needs_ext
def test_ext_evaluation_metrics():
    ext = _ext()
    for cid in ("tsn", TSN_CELL, "om-8.6819-106.5892"):
        e = ai_model.evaluation_for(cid)
        assert e["enabled_targets"] == ext["enabled_targets"] and "80" in e["serving_rule"]
        for h in ("1h", "3h", "6h"):
            assert 0.5 < e[f"temperature_interval_coverage_{h}"] <= 1
            assert e[f"temperature_interval_width_{h}"] > 0
            assert 0 <= e[f"rain_brier_{h}"] <= 1 and 0 <= e[f"rain_ece_{h}"] <= 1
            for t in ai_model.EXT_TARGETS:          # disabled targets are still evaluated
                for b in ("", "baseline_persistence_", "baseline_climatology_"):
                    assert e[f"{b}{t}_mae_{h}"] >= 0
            assert e[f"precipitation_mm_rmse_{h}"] >= 0
        for t in ai_model.EXT_TARGETS:
            assert isinstance(e[f"beats_baselines_{t}"], bool)
        assert isinstance(e["beats_baselines"], bool) and "temperature_mae_1h" in e   # old keys kept
    iv = ext["interval"]
    assert iv["version"] == 2 and iv["nominal"] == 0.9 and ("2024-01-01" in iv["split"]["cal"][0] or "2024-10-01" in iv["split"]["cal"][0])
    for h in ("1h", "3h", "6h"):
        new, old = iv["test"][h], iv["test_previous_p10_p90"][h]
        assert new["cov_mean"] >= 0.88 and new["cov_min_cell"] >= 0.85      # held-out test
        assert old["cov_mean"] < 0.8 and new["width"] > old["width"]
    assert "interval_previous_p10_p90" in ext and "conformal" in ext["interval_previous_p10_p90"]


@needs_ext
def test_ext_router_passes_new_fields(client, monkeypatch):
    freeze_now(monkeypatch, LAST_TS.replace(tzinfo=LOCAL_TZ))
    r = client.get("/weather/ai-forecast")
    assert r.status_code == 200
    body = r.json()
    assert "temperature_interval" in body["enabled_targets"]
    for p in body["predictions"].values():
        assert {"temperature", "rain_probability", "target_time", "temperature_p10", "temperature_p90",
                "temperature_low", "temperature_high", "interval_level", "uncertainty_note"} <= set(p)
        assert 0.85 <= p["interval_level"] <= 0.95 and p["temperature_low"] <= p["temperature"] <= p["temperature_high"]
    assert "temperature_interval_coverage_1h" in body["evaluation"]


@needs_ext
def test_interval_achieved_coverage_honesty():
    assert ai_model._load_v3()
    ext = ai_model._v3.get("ext")
    assert ext is not None
    iv = ext.get("interval", {})
    achieved = iv.get("achieved_coverage", {})
    assert "1h" in achieved and "3h" in achieved and "6h" in achieved
    assert round(achieved["1h"], 2) == 0.88
    # Test uncertainty note uses achieved coverage note, not hardcoded 90%
    note_1h = ai_model._uncertainty_note(25.0, 30.0, coverage=0.88, period="2025-10-01..2026-10-21", level=achieved["1h"])
    assert "khoảng ~88%" in note_1h
    assert "khoảng tin cậy 90%" not in note_1h
