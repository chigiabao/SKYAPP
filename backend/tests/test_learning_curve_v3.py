"""Small methodology tests; no source DB or fitted production models are touched."""
import sqlite3

import numpy as np
import pandas as pd
import pytest

from scripts import learning_curve_v3 as L


def raw_frame(periods=96):
    raw = pd.DataFrame({col: np.ones(periods) for col in L.RAW_COLS})
    raw["timestamp"] = pd.date_range("2023-07-01", periods=periods, freq="h")
    raw["cell_id"] = "a"
    return raw


def test_training_windows_and_splits_purge_future_targets():
    stamps = [L.train_start(6) - pd.Timedelta(hours=1), L.train_start(6), L.train_start(3), L.train_start(1),
              L.T.TRAIN_END - pd.Timedelta(hours=6), L.T.TRAIN_END - pd.Timedelta(hours=5),
              L.T.VAL_ES_START, L.T.VAL_ES_END - pd.Timedelta(hours=6), L.T.VAL_ES_END,
              L.T.VAL_SEL_START, L.T.VAL_SEL_END, L.T.TEST_START]
    data = pd.DataFrame({"timestamp": stamps})
    for col in L.T.target_cols():
        data[col] = 1.0
    train, es, select, test = L.T.split(data)
    for years in L.YEARS:
        window = L.training_window(train, years)
        assert window.timestamp.min() == L.train_start(years)
        assert window.timestamp.max() + pd.Timedelta(hours=6) == L.T.TRAIN_END
    assert len(es) == 2 and len(select) == 1 and len(test) == 1
    assert train.timestamp.max() < es.timestamp.min() < select.timestamp.min() < test.timestamp.min()


def test_sampling_is_nested_chunk_independent_and_covers_all_hours():
    timestamps = pd.Series(pd.date_range("2017-01-01", "2023-09-23 23:00", freq="h"))
    selected = timestamps[L.sample_mask(timestamps)]
    for years in L.YEARS:
        subset = timestamps[timestamps >= L.train_start(years)]
        pd.testing.assert_series_equal(subset[L.sample_mask(subset)], selected[selected >= L.train_start(years)])
    four_days = pd.Series(pd.date_range("2023-01-01", periods=96, freq="h"))
    assert set(four_days[L.sample_mask(four_days)].dt.hour) == set(range(24))
    assert L.sample_mask(four_days).sum() == 24
    with pytest.raises(ValueError, match="divisor"):
        L.sample_mask(four_days, 5)


def test_missing_and_spreadsheet_errors_do_not_turn_into_dry_labels():
    raw = raw_frame()
    raw["precipitation"] = raw.precipitation.astype(object)
    raw.loc[30, "precipitation"] = "#NUM!"
    raw.loc[40, "temperature"] = np.inf
    raw = raw.drop(index=50)
    clean, audit = L.clean_cell(raw)
    assert audit["columns"]["precipitation"]["non_numeric"] == 1
    assert audit["columns"]["temperature"]["infinite"] == 1
    assert audit["missing_hours"] == 1
    targets = L.T.build_targets(clean)
    assert np.isnan(targets.loc[27, "rain_target_3h"])
    assert np.isnan(targets.loc[47, "rain_target_3h"])
    assert np.isnan(targets.loc[37, "temp_target_3h"])
    with pytest.raises(ValueError, match="duplicate"):
        L.clean_cell(pd.concat([raw, raw.iloc[:1]], ignore_index=True))


def test_missing_climatology_in_one_window_uses_common_holdout_rows():
    data = pd.DataFrame({"cell_id": ["a", "a"], "timestamp": pd.to_datetime(["2025-10-01", "2025-11-01"]),
                         "temp_target_3h": [28.0, 29.0], "rain_target_3h": [0.0, 1.0]})
    index = pd.MultiIndex.from_tuples([("a", 10, 3), ("a", 11, 3)], names=["cell_id", "month", "hour"])
    full = pd.DataFrame({"temperature": [28.0, 28.0], "rain": [0.2, 0.3]}, index=index)
    climates = {1: full.iloc[:1], 3: full, 6: full}
    common, excluded = L.common_evaluation(data, climates, [3])
    assert len(common) == 1 and excluded == 1
    for clim in climates.values():
        assert L.T.clim_at_target(common, clim, 3).notna().all().all()


def test_features_are_unchanged_when_future_values_change():
    raw = raw_frame()
    static = dict.fromkeys(L.T.STATIC_FEATURES, 1.0)
    original = L.feature_frame(raw, static)
    raw.loc[raw.index > 60, L.RAW_COLS] = 90.0
    changed = L.feature_frame(raw, static)
    cols = L.T.feature_columns_v3()
    pd.testing.assert_frame_equal(original.loc[original.index <= 60, cols], changed.loc[changed.index <= 60, cols])
    assert original.loc[60, "temp_target_3h"] != changed.loc[60, "temp_target_3h"]


def test_read_transaction_stays_frozen_during_append(tmp_path):
    path = tmp_path / "snapshot.db"
    with sqlite3.connect(path) as writer:
        writer.execute("PRAGMA journal_mode = WAL")
        writer.execute("CREATE TABLE hourly (timestamp TEXT)")
        writer.execute("INSERT INTO hourly VALUES ('2026-10-18 23:00:00')")
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as reader:
        reader.execute("PRAGMA query_only = ON")
        reader.execute("BEGIN")
        assert reader.execute("SELECT COUNT(*) FROM hourly").fetchone()[0] == 1
        with sqlite3.connect(path) as writer:
            writer.execute("INSERT INTO hourly VALUES ('2026-10-19 00:00:00')")
        assert reader.execute("SELECT COUNT(*) FROM hourly").fetchone()[0] == 1
        with pytest.raises(sqlite3.OperationalError, match="readonly"):
            reader.execute("DELETE FROM hourly")


def test_metrics_report_raw_probability_and_tuned_baseline_fairly():
    frame = pd.DataFrame({"y_t": [20.0, 22.0], "m_t": [20.5, 21.5], "p_t": [21.0, 21.0],
                          "c_t": [21.0, 21.0], "y_r": [0.0, 1.0], "m_p_raw": [0.1, 0.4],
                          "c_p": [0.1, 0.3], "p_r": [False, False]})
    result = L.metrics(frame, 0.2, 0.2)
    assert result["f1_model"] == result["f1_climatology"] == 1.0
    assert result["mae_model"] == 0.5
    assert result["brier_model"] == pytest.approx(0.185)
    assert result["bss_model"] == pytest.approx(0.26)
