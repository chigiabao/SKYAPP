"""Synthetic daily-rain diagnostics only: no model training or artifact access."""
import sqlite3
from unittest.mock import Mock

import numpy as np
import pandas as pd
import pytest

from scripts import train_global_v3_interval as interval


@pytest.fixture(autouse=True)
def no_training_or_artifacts(monkeypatch):
    fail = Mock(side_effect=AssertionError("rain diagnostics must not train or access model artifacts"))
    for name in ("fit", "train_set", "main"):
        monkeypatch.setattr(interval, name, fail)
    monkeypatch.setattr(interval.lgb, "train", fail)
    monkeypatch.setattr(interval.lgb, "Dataset", fail)
    monkeypatch.setattr(interval.joblib, "load", fail)
    monkeypatch.setattr(interval.joblib, "dump", fail)
    yield
    fail.assert_not_called()


@pytest.fixture
def load_history(monkeypatch):
    # Constant fixture features keep missing rain eligible for temperature diagnostics.
    monkeypatch.setattr(interval, "SMOKE", 0)
    monkeypatch.setattr(interval, "feature_columns_v3", lambda: ["temperature"])
    monkeypatch.setattr(interval, "build_features_v3", lambda df, static: pd.DataFrame({
        "temperature": np.full(len(df), 30.0)}))

    def load(rain, times=None):
        if times is None:
            times = pd.date_range("2021-01-01", periods=len(rain), freq="h")
        history = pd.DataFrame({"timestamp": times, "cell_id": "fixture-cell",
                                "temperature": 30.0, "precipitation": rain})
        with sqlite3.connect(":memory:") as con:
            history.to_sql("hourly", con, index=False)
            return interval.load(con, {"fixture-cell": {}}, {"fixture-cell": (None, str(times.max()))})

    return load


@pytest.mark.parametrize("rain,expected", [
    pytest.param([np.nan] * 24, np.nan, id="all-missing"),
    pytest.param([0.0] * 23 + [np.nan], np.nan, id="partial-dry"),
    pytest.param([2.0] + [0.0] * 22 + [np.nan], np.nan, id="partial-wet"),
    pytest.param([0.0] * 24, 0.0, id="full-dry"),
    pytest.param([0.99] + [0.0] * 23, 0.0, id="full-below-threshold"),
    pytest.param([1.0] + [0.0] * 23, 1.0, id="full-wet-threshold"),
    pytest.param([2.0] * 24, 1.0, id="full-wet"),
])
def test_daily_labels_require_complete_rain(load_history, rain, expected):
    features, meta = load_history(rain)
    assert len(features) == len(meta) == 24
    for h in interval.HORIZONS:
        same_day = meta.timestamp + pd.Timedelta(hours=h) < pd.Timestamp("2021-01-02")
        label = meta.loc[same_day, f"rd{h}"]
        assert label.dtype == np.dtype("float32")
        assert len(label) == 24 - h
        if np.isnan(expected):
            assert label.isna().all()
        else:
            assert (label == expected).all()
        assert meta.loc[~same_day, f"rd{h}"].isna().all()
        assert meta.loc[same_day, f"y{h}"].eq(30.0).all()


@pytest.mark.parametrize("invalid", [np.inf, -np.inf, -0.1, "invalid"])
@pytest.mark.parametrize("total", [0.0, 2.0], ids=["dry", "wet"])
def test_invalid_hour_is_unknown_even_if_partial_total_is_wet(load_history, invalid, total):
    _, meta = load_history([total] + [0.0] * 22 + [invalid])
    assert meta[[f"rd{h}" for h in interval.HORIZONS]].isna().all().all()


@pytest.mark.parametrize("times", [
    pytest.param(pd.date_range("2021-01-01", periods=23, freq="h"), id="truncated-day"),
    pytest.param(pd.date_range("2021-01-01 12:00", periods=24, freq="h"), id="cross-calendar-day"),
    pytest.param(pd.date_range("2021-01-01 00:30", periods=24, freq="h"), id="off-hour-grid"),
    pytest.param(pd.date_range("2021-01-01", periods=24, freq="h").delete(12), id="missing-hour"),
    pytest.param(pd.date_range("2021-01-01", periods=24, freq="h").delete(12).append(
        pd.DatetimeIndex(["2021-01-01 11:00"])), id="duplicate-cannot-fill-missing-hour"),
])
@pytest.mark.parametrize("rain", [0.0, 2.0], ids=["dry", "wet"])
def test_incomplete_calendar_day_is_unknown(load_history, times, rain):
    _, meta = load_history([rain] * len(times), times)
    assert meta[[f"rd{h}" for h in interval.HORIZONS]].isna().all().all()


def test_target_day_mapping_and_diagnostic_counts_exclude_unknown(load_history):
    rain = ([0.0] * 24 + [np.nan] * 24 + [0.0] * 23 + [np.nan]
            + [2.0] + [0.0] * 22 + [np.nan] + [0.0] * 24 + [1.0] * 24 + [0.0] * 12)
    features, meta = load_history(rain)
    days = pd.date_range("2021-01-01", periods=7, freq="D")
    expected = pd.Series([0.0, np.nan, np.nan, np.nan, 0.0, 1.0, np.nan], index=days, dtype="float32")
    for h in interval.HORIZONS:
        target_day = (meta.timestamp + pd.Timedelta(hours=h)).dt.normalize()
        pd.testing.assert_series_equal(meta[f"rd{h}"], target_day.map(expected), check_names=False)

    # Predictions are fixed test doubles, never fitted models.
    models = {f"{q}_{h}h": Mock(predict=lambda X, value=value: np.full(len(X), value))
              for h in interval.HORIZONS for q, value in (("q05", 29.0), ("q95", 31.0))}
    static = {"fixture-cell": {"lat": 10.8, "dist_to_coast_km": 50.0}}
    frame = interval.frame(models, features, meta, np.ones(len(meta), dtype=bool), static)
    assert frame.rd.isna().any()  # Unknown rain must not remove valid temperature targets.
    covered = frame.rd.notna().to_numpy()
    width = np.where(covered, 2.0, 100.0)
    diag = interval.diagnostics(frame, covered, width, ~covered, width + 1.0)
    rain_diag = diag[diag.by == "rain_day"]
    assert set(rain_diag.value) == {"0.0", "1.0"}
    for h in interval.HORIZONS:
        samples = frame[frame.h == h]
        counts = rain_diag[rain_diag.h == h].set_index("value").n.to_dict()
        assert counts == {"0.0": 48 - h, "1.0": 24}
        assert sum(counts.values()) == samples.rd.notna().sum()
        assert sum(counts.values()) < len(samples)
        for by in ("cell_id", "month", "hblock"):
            assert diag[(diag.h == h) & (diag.by == by)].n.sum() == len(samples)
    assert rain_diag["cov"].eq(1.0).all()
    assert rain_diag.width.eq(2.0).all()
    assert rain_diag.cov_old.eq(0.0).all()
    assert rain_diag.width_old.eq(3.0).all()


def test_all_unknown_rain_has_no_dry_or_wet_diagnostics(load_history):
    _, meta = load_history([np.nan] * 48)
    frame = pd.DataFrame({"h": 1, "cell_id": meta.cell_id, "month": meta.timestamp.dt.month,
                          "hour": meta.timestamp.dt.hour, "rd": meta.rd1})
    covered, width = np.ones(len(frame), dtype=bool), np.full(len(frame), 2.0)
    diag = interval.diagnostics(frame, covered, width, covered, width)
    assert diag[diag.by == "rain_day"].empty
    for by in ("cell_id", "month", "hblock"):
        assert diag[diag.by == by].n.sum() == 48
