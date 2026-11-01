"""Small offline regression checks; no real booster fitting or source data writes."""
import json
import sqlite3
from types import SimpleNamespace

import numpy as np
import pandas as pd
import pytest

from scripts import recalibrate_intervals_v3 as R


def test_exact_finite_sample_order_statistic():
    assert R.finite_quantile(np.arange(20)) == 18
    assert R.finite_quantile(np.arange(9)) == 8
    assert R.finite_quantile(np.arange(10)) == 9


@pytest.mark.parametrize("scores", [[], [1] * 8, [np.nan] * 10, [np.inf] * 10, [[1] * 10]])
def test_quantile_rejects_insufficient_or_invalid_labels(scores):
    with pytest.raises(ValueError):
        R.finite_quantile(scores)


def test_disjoint_target_windows_and_purge():
    R.validate_windows()
    times = pd.date_range(R.CAL_END - pd.Timedelta(hours=6), R.TEST_START, freq="h")
    cal = R.window_mask(times, 1, R.CAL_START, R.CAL_END, calibration=True)
    test = R.window_mask(times, 6, R.TEST_START, R.TEST_END)
    assert cal.sum() == 1 and test.sum() == 1 and not (cal & test).any()
    assert times[cal][-1] + pd.Timedelta(hours=6) == R.CAL_END
    assert R.TEST_START - R.CAL_END == pd.Timedelta(days=7, hours=1)
    with pytest.raises(ValueError, match="purge"):
        R.validate_windows(test_start=R.CAL_END + pd.Timedelta(days=6))
    with pytest.raises(ValueError, match="overlapping"):
        R.validate_windows(test_start=R.CAL_END)


def calibration_parts():
    days = pd.date_range(R.CAL_START, periods=150, freq="D").repeat(24).as_unit("ns").asi8
    parts = []
    for h in R.A.HORIZONS:
        keys = np.array([f"{h}|a|wet"] * 800 + [f"{h}|b|wet"] * 2800, dtype=object)
        parts.append((h, keys, days, np.linspace(-.1, .5, len(days))))
    return parts


def test_cell_support_and_unknown_group_fall_back_to_horizon():
    parts = calibration_parts()
    # A has 800 labels but only 34 target days; B has 117 days.
    table, counts = R.fit_offsets(parts)
    assert counts["1|a|wet"]["source"] == "cell_season"
    np.testing.assert_equal(R.offsets_for(["1|a|wet", "1|unseen|dry"], 1, table),
                            [table["1|a|wet"], table["1"]])
    parts[0][1][:700] = "1|small|wet"
    table, counts = R.fit_offsets(parts)
    assert counts["1|small|wet"]["source"] == "horizon"
    assert "1|small|wet" not in table
    np.testing.assert_equal(R.offsets_for(["1|small|wet"], 1, table), [table["1"]])


def test_calibration_rejects_final_window_labels():
    parts = calibration_parts()
    parts[0][2][0] = R.TEST_START.value
    with pytest.raises(ValueError, match="out-of-window"):
        R.fit_offsets(parts)


def test_pool_minimum_and_day_support_fail_closed():
    parts = calibration_parts()
    parts = [(h, keys[:1000], days[:1000], scores[:1000]) for h, keys, days, scores in parts]
    with pytest.raises(ValueError, match="support"):
        R.fit_offsets(parts)


def test_target_season_and_actual_cell_fallback_serving_alignment(monkeypatch):
    cid = "om-8.6819-106.5892"
    static = {cid: {"lat": 8.68, "dist_to_coast_km": 0.0}}
    times = pd.DatetimeIndex(["2026-04-30 23:00"])
    key = R.group_keys(1, cid, times, static)[0]
    assert key == f"1|{cid}|wet"
    policy = {"fallback": {cid: {"1h": {"temperature_weight": .25}}}}
    point, _ = R.A.apply_policy(policy, 1, [cid], [30], [0], [26], [0])
    assert point[0] == 27
    constant = lambda value: SimpleNamespace(predict=lambda x: np.full(len(x), value))
    ext = {"models": {"temp_q05_1h": constant(28), "temp_q95_1h": constant(29)},
           "interval": {"version": 2, "grouping": "cell_season", "scale": "abs", "nominal": .9},
           "offsets": {"1": .1}}
    monkeypatch.setattr(R.A, "_v3", {"static": static})
    actual = R.A._interval_v3(ext, np.zeros((1, 1)), point[0], 1, cid, times[0])
    expected = R.A.conformal_interval([28], [29], R.offsets_for([key], 1, ext["offsets"]), "abs", point)
    np.testing.assert_allclose(actual[:2], [expected[0][0], expected[1][0]])
    assert actual[0] == 27 and actual[2] == .9


def test_future_values_never_change_issue_features():
    frame = pd.DataFrame({c: np.linspace(1, 5, 72) for c in R.A.BASE_VARS + ["wind_direction"]})
    frame["timestamp"] = pd.date_range("2026-04-01", periods=72, freq="h")
    static = dict.fromkeys(R.A.STATIC_FEATURES, 1.0)
    before = R.A.build_features_v3(frame, static).iloc[48]
    frame.loc[49:, R.A.BASE_VARS] = 9999.0
    after = R.A.build_features_v3(frame, static).iloc[48]
    pd.testing.assert_series_equal(before, after)
    pd.testing.assert_series_equal(before, R.A.build_features_v3(frame.iloc[1:49], static).iloc[-1])


def test_spreadsheet_errors_and_nulls_are_missing_not_zero():
    frame = pd.DataFrame({c: np.ones(72) for c in R.A.BASE_VARS + ["wind_direction"]})
    frame["timestamp"] = pd.date_range(R.CAL_START - pd.Timedelta(hours=48), periods=72, freq="h").astype(str)
    frame["cell_id"] = "a"
    frame["temperature"] = frame.temperature.astype(object)
    frame.loc[50, "temperature"] = "#NUM!"
    frame.loc[51, "temperature"] = None
    with sqlite3.connect(":memory:") as con:
        frame.to_sql("hourly", con, index=False)
        result, _, valid, audit = R.read_cell(con, "a", dict.fromkeys(R.A.STATIC_FEATURES, 1),
                                             R.A.feature_columns_v3(), frame.timestamp.iloc[-1])
    assert result.temperature.iloc[50:52].isna().all()
    assert not valid[50:52].any()
    assert audit["ranges_missing"]["temperature"]["invalid_tokens"] == 1
    assert audit["ranges_missing"]["temperature"]["missing"] == 2


def test_dry_run_never_opens_data_or_writes(monkeypatch, capsys):
    def forbidden(*args, **kwargs):
        raise AssertionError("dry run attempted experiment")
    monkeypatch.setattr(R, "run", forbidden)
    R.main([])
    result = json.loads(capsys.readouterr().out)
    assert result["dry_run"] and not result["writes"] and not result["predictions"]


def test_output_allows_new_evaluation_directory_without_touching_inputs(tmp_path, monkeypatch):
    assert R.BACKEND / "models/evaluation/data_upgrade_20261023" in R.ALLOWED_OUTPUTS
    output = tmp_path / "models/evaluation/data_upgrade_20261023"
    output.mkdir(parents=True)
    history = output / "history_before_retrain.json"
    history.write_text("existing history audit", encoding="utf-8")
    monkeypatch.setattr(R, "ALLOWED_OUTPUTS", (output,))
    assert R.validate_output(output, tmp_path / "models/v3_candidate_20261023") == output.resolve()
    assert list(output.iterdir()) == [history]
    assert history.read_text(encoding="utf-8") == "existing history audit"


@pytest.mark.parametrize("relative", ["models/v3", "models/v3_candidate_20261023",
                                     "models/evaluation/data_upgrade_20261023/../unowned"])
def test_output_rejects_model_and_unowned_directories(tmp_path, monkeypatch, relative):
    output = tmp_path / "models/evaluation/data_upgrade_20261023"
    monkeypatch.setattr(R, "ALLOWED_OUTPUTS", (output,))
    with pytest.raises(ValueError, match="restricted"):
        R.validate_output(tmp_path / relative, tmp_path / "models/v3_candidate_20261023")
    assert not output.exists()


@pytest.mark.parametrize("model_relative", [".", "nested-model", ".."])
def test_output_rejects_overlap_with_model_directory(tmp_path, monkeypatch, model_relative):
    output = tmp_path / "evaluation"
    monkeypatch.setattr(R, "ALLOWED_OUTPUTS", (output,))
    with pytest.raises(ValueError, match="overlap"):
        R.validate_output(output, output / model_relative)


@pytest.mark.parametrize("name", ["interval_design.json", "interval_per_cell.csv"])
def test_existing_interval_artifacts_stop_run_before_loading_models(tmp_path, monkeypatch, name):
    output = tmp_path / "evaluation"
    output.mkdir()
    artifact = output / name
    artifact.write_text("previous evidence", encoding="utf-8")
    monkeypatch.setattr(R, "ALLOWED_OUTPUTS", (output,))
    def forbidden(*args, **kwargs):
        raise AssertionError("existing output must be rejected before loading inputs")
    monkeypatch.setattr(R, "fingerprint", forbidden)
    with pytest.raises(FileExistsError, match="already exist"):
        R.run(SimpleNamespace(output=output, model_dir=tmp_path / "model"))
    assert artifact.read_text(encoding="utf-8") == "previous evidence"
    assert list(output.iterdir()) == [artifact]


def test_json_write_never_overwrites_existing_evidence(tmp_path):
    artifact = tmp_path / "interval_report.json"
    R.write_json(artifact, {"original": True})
    before = artifact.read_bytes()
    with pytest.raises(FileExistsError):
        R.write_json(artifact, {"original": False})
    assert artifact.read_bytes() == before


def test_gate_rejects_coverage_or_excessive_width():
    horizon = {"new_coverage": .91, "new_macro_coverage": .91, "width_ratio": 1.1}
    cell = {"cell_id": "a", "h": 1, "new_coverage": .91, "width_ratio": 1.1, "n": 1000}
    assert R.gate({"1h": horizon}, [cell])["pass"]
    assert not R.gate({"1h": {**horizon, "new_coverage": .899}}, [cell])["pass"]
    assert not R.gate({"1h": {**horizon, "width_ratio": 1.151}}, [cell])["pass"]
    assert not R.gate({"1h": horizon}, [{**cell, "width_ratio": 1.251}])["pass"]


def test_recalibration_cutoff_never_backdates_existing_test_guard(monkeypatch):
    windows = {name: [None, str(R.CAL_END)] for name in ("qtrain", "es_fit", "es", "cal", "bt_train", "bt_cal", "bt_test")}
    model = {"static": {"a": {}}, "meta": {"split": {"train_end": "2023-09-23",
             "val": ["2023-10-01", "2024-09-23"], "test_end": str(R.TEST_END)}},
             "ext": {"meta": {"interval": {"version": 2, "split": windows}}}}
    monkeypatch.setattr(R.A, "_v3", model)
    monkeypatch.setattr(R.A, "_load_v3", lambda: True)
    assert pd.Timestamp(R.A.verification_cutoff("a")) == R.TEST_END
