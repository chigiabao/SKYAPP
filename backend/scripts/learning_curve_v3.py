"""Bounded old-history experiment; aggregates only, never serving models.

Default: 1/3/6 training years ending at T.TRAIN_END, representative_cells(..., 9),
3h temperature/rain, rotating 1/4 issue sampling, 300 rounds, ES 40, two threads.
Raw model and raw climatology each tune their F1 threshold on val_es only.
val_select and test are reports, not inputs to any experimental choice.
"""
from __future__ import annotations

import argparse
import ctypes
import gc
import hashlib
import json
import platform
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_global_v3 as T  # noqa: E402
from backtest_rolling_v3 import representative_cells  # noqa: E402

OUT = T.BACKEND / "models/evaluation/data_upgrade_20261022"
YEARS = (1, 3, 6)
SPLITS = ("train_pool", "val_es", "val_select", "test")
RAW_COLS = T.ai_model.BASE_VARS + ["wind_direction"]


def log(message):
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def train_start(years):
    return T.TRAIN_END + pd.Timedelta(hours=1) - pd.DateOffset(years=years)


def training_window(data, years):
    end = data.timestamp + pd.Timedelta(hours=T.MAXH)
    return data[(data.timestamp >= train_start(years)) & (end <= T.TRAIN_END)]


def sample_mask(timestamps, stride=4):
    """Same deterministic schedule in every cell/window; rotates all 24 hours."""
    if stride < 1 or 24 % stride:
        raise ValueError("issue stride must be a positive divisor of 24")
    hours = ((timestamps - pd.Timestamp("1970-01-01")) // pd.Timedelta(hours=1)).to_numpy()
    return (hours // 24 + hours % 24 + T.SEED) % stride == 0


def clean_cell(raw):
    """Audit before features; malformed numeric values remain missing, never zero."""
    raw = raw.copy()
    digest = hashlib.sha256(pd.util.hash_pandas_object(raw, index=False).values.tobytes()).hexdigest()
    raw["timestamp"] = pd.to_datetime(raw.timestamp, errors="raise")
    if raw.timestamp.isna().any() or not raw.timestamp.eq(raw.timestamp.dt.floor("h")).all():
        raise ValueError("missing or non-hourly timestamp")
    duplicates = int(raw.timestamp.duplicated().sum())
    if duplicates:
        raise ValueError(f"duplicate timestamps: {duplicates}")
    audit = {"rows": len(raw), "start": str(raw.timestamp.min()), "end": str(raw.timestamp.max()),
             "source_rows_sha256": digest, "duplicates": duplicates, "columns": {}}
    for col in RAW_COLS:
        numeric = pd.to_numeric(raw[col], errors="coerce").astype(float)
        finite = np.isfinite(numeric)
        valid = numeric[finite]
        audit["columns"][col] = {
            "dtype": str(raw[col].dtype), "nulls": int(raw[col].isna().sum()),
            "non_numeric": int((numeric.isna() & raw[col].notna()).sum()),
            "infinite": int((numeric.notna() & ~finite).sum()),
            "min": float(valid.min()) if len(valid) else None,
            "max": float(valid.max()) if len(valid) else None,
        }
        raw[col] = numeric.where(finite)
    raw = raw.sort_values("timestamp").set_index("timestamp")
    full_index = pd.date_range(raw.index.min(), raw.index.max(), freq="h")
    audit["missing_hours"] = len(full_index) - len(raw)
    return raw.reindex(full_index).rename_axis("timestamp").reset_index(), audit


def feature_frame(raw, static):
    cols = T.feature_columns_v3()
    features = T.build_features_v3(raw, static)[cols].astype(np.float32)
    targets = T.build_targets(raw).astype(np.float32)
    frame = pd.concat([raw[["timestamp"]], features, targets], axis=1)
    return frame[np.isfinite(features).all(axis=1)].copy()


def peak_memory_mb():
    """Native peak working set, including native LightGBM allocations."""
    if sys.platform == "win32":
        class Counters(ctypes.Structure):
            _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong)] + [
                (name, ctypes.c_size_t) for name in (
                    "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage",
                    "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")]
        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        get_process = ctypes.windll.kernel32.GetCurrentProcess
        get_process.restype = ctypes.c_void_p
        get_memory = ctypes.windll.psapi.GetProcessMemoryInfo
        get_memory.argtypes = [ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_ulong]
        if not get_memory(get_process(), ctypes.byref(counters), counters.cb):
            raise ctypes.WinError()
        return counters.PeakWorkingSetSize / 1024**2
    import resource
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / (1024**2 if sys.platform == "darwin" else 1024)


def check_budget(started, seconds, memory_mb):
    if time.monotonic() - started > seconds:
        raise RuntimeError(f"experiment exceeded {seconds}s budget")
    if peak_memory_mb() > memory_mb:
        raise RuntimeError(f"experiment exceeded {memory_mb} MiB peak working set")


def load_snapshot(db, snapshot_end, stride, budget):
    """One read transaction freezes all cells before loading; no DB/raw-data copy."""
    parts = {name: [] for name in SPLITS}
    climates = {years: [] for years in YEARS}
    audit = {}
    with sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True) as con:
        con.execute("PRAGMA query_only = ON")
        con.execute("BEGIN")
        coverage = pd.read_sql_query(
            "SELECT cell_id, MIN(timestamp) AS start, MAX(timestamp) AS end, COUNT(*) AS rows "
            "FROM hourly WHERE timestamp <= ? GROUP BY cell_id ORDER BY cell_id", con,
            params=(str(snapshot_end),))
        if coverage.empty:
            raise ValueError("snapshot has no rows")
        static = T.cell_static(con)
        cells = representative_cells(static, 9)
        for cid in cells:
            raw = pd.read_sql_query(
                "SELECT * FROM hourly WHERE cell_id = ? AND timestamp <= ? ORDER BY timestamp",
                con, params=(cid, str(snapshot_end)))
            if raw.empty:
                raise ValueError(f"selected cell has no snapshot data: {cid}")
            raw, audit[cid] = clean_cell(raw)
            if not np.isfinite([static[cid][col] for col in T.STATIC_FEATURES]).all():
                raise ValueError(f"nonfinite static features: {cid}")
            frame = feature_frame(raw, static[cid])
            frame["cell_id"] = cid
            audit[cid]["feature_rows"] = len(frame)
            audit[cid]["invalid_feature_rows"] = len(raw) - len(frame)
            train, es, select, test = T.split(frame)
            test = test[(test.timestamp + pd.Timedelta(hours=T.MAXH) <= snapshot_end)
                        & np.isfinite(test[T.target_cols()]).all(axis=1)]
            audit[cid]["climatology_training_rows"] = {}
            for years in YEARS:
                window = training_window(train, years)
                audit[cid]["climatology_training_rows"][str(years)] = len(window)
                climates[years].append(T.climatology(window))
            for name, window in zip(SPLITS, (training_window(train, max(YEARS)), es, select, test)):
                parts[name].append(window.loc[sample_mask(window.timestamp, stride)].copy())
            del raw, frame, train, es, select, test, window
            check_budget(*budget)
            log(f"loaded {cid}: {audit[cid]['rows']:,} source rows")
        # Only small aggregates and sampled features outlive this transaction.
    frames = {}
    for name, chunks in parts.items():
        frames[name] = pd.concat(chunks, ignore_index=True)
        chunks.clear()
        frames[name]["cell_id"] = frames[name].cell_id.astype("category")
    snapshot = {
        "database": str(db), "read_transaction": True, "query_only": True,
        "cutoff_inclusive": str(snapshot_end), "rows": int(coverage.rows.sum()),
        "cells": len(coverage), "start": str(coverage.start.min()), "end": str(coverage.end.max()),
        "coverage": coverage.to_dict("records"), "selected_cells": cells, "audit": audit,
        "selected_static": {cid: static[cid] for cid in cells},
    }
    return frames, {years: pd.concat(chunks) for years, chunks in climates.items()}, snapshot


def common_evaluation(data, climates, horizons):
    """Intersect baseline support across all windows, never change rows by model."""
    keep = np.ones(len(data), dtype=bool)
    for clim in climates.values():
        for h in horizons:
            keep &= np.isfinite(T.clim_at_target(data, clim, h).to_numpy()).all(axis=1)
            keep &= np.isfinite(data[[f"temp_target_{h}h", f"rain_target_{h}h"]]).all(axis=1).to_numpy()
    return data.loc[keep].reset_index(drop=True), int((~keep).sum())


def row_manifest(data):
    columns = ["cell_id", "timestamp", *T.target_cols()]
    digest = hashlib.sha256(pd.util.hash_pandas_object(data[columns], index=False).values.tobytes()).hexdigest()
    return {"rows": len(data), "issue_start": str(data.timestamp.min()), "issue_end": str(data.timestamp.max()),
            "rows_sha256": digest,
            "per_cell_rows": {str(k): int(v) for k, v in data.groupby("cell_id", observed=True).size().items()}}


def fit_window(train, es, horizons, rounds, budget):
    """One binned Dataset per window; optional horizons reuse that Dataset."""
    cols = T.feature_columns_v3()
    params = dict(T.REG_PARAMS, num_threads=2, seed=42, deterministic=True, force_col_wise=True)
    params["histogram_pool_size"] = 64
    dtrain = lgb.Dataset(train[cols].to_numpy(np.float32),
                         label=train[f"temp_target_{horizons[0]}h"].to_numpy(np.float32),
                         params=params, free_raw_data=True).construct()
    x_es = es[cols].to_numpy(np.float32)
    models, iterations = {}, {}

    def guard(env):
        if env.iteration % 10 == 0:
            check_budget(*budget)

    for h in horizons:
        for kind in ("temp", "rain"):
            target = f"{kind}_target_{h}h"
            key = f"{kind}_{h}h"
            dtrain.set_label(train[target].to_numpy(np.float32))
            valid = lgb.Dataset(x_es, es[target].to_numpy(np.float32), reference=dtrain)
            fit_params = dict(params)
            if kind == "rain":
                fit_params.update(objective="binary", metric="binary_logloss")
            model = lgb.train(fit_params, dtrain, num_boost_round=rounds, valid_sets=[valid],
                              callbacks=[lgb.early_stopping(40, verbose=False), guard])
            models[key] = model if model.current_iteration() == model.best_iteration else T._truncate(model)
            iterations[key] = models[key].current_iteration()
            log(f"  {key}: {iterations[key]} rounds, peak={peak_memory_mb():.0f} MiB")
    return models, iterations, params


def metrics(frame, model_threshold, climate_threshold):
    y = frame.y_r.to_numpy()
    climate_brier = float(np.mean((y - frame.c_p.to_numpy()) ** 2))
    model_brier = float(np.mean((y - frame.m_p_raw.to_numpy()) ** 2))
    return {
        "rows": len(frame), "rain_events": int(y.sum()), "rain_rate": float(y.mean()),
        "mae_model": float(np.mean(np.abs(frame.y_t - frame.m_t))),
        "mae_persistence": float(np.mean(np.abs(frame.y_t - frame.p_t))),
        "mae_climatology": float(np.mean(np.abs(frame.y_t - frame.c_t))),
        "f1_model": T.f1(y, frame.m_p_raw.to_numpy() >= model_threshold),
        "f1_persistence": T.f1(y, frame.p_r),
        "f1_climatology": T.f1(y, frame.c_p.to_numpy() >= climate_threshold),
        "brier_model": model_brier, "brier_climatology": climate_brier,
        "brier_persistence": float(np.mean((y - frame.p_r.to_numpy()) ** 2)),
        "bss_model": 1 - model_brier / climate_brier if climate_brier > 0 else None,
    }


def run(args):
    started = time.monotonic()
    budget = (started, args.budget_seconds, 1024)
    args.out.mkdir(parents=True, exist_ok=True)
    frames, climates, snapshot = load_snapshot(args.db, pd.Timestamp(args.snapshot_end), args.stride, budget)
    manifests = {}
    for name in SPLITS[1:]:
        frames[name], excluded = common_evaluation(frames[name], climates, args.horizons)
        if frames[name].empty:
            raise ValueError(f"no common evaluation rows: {name}")
        manifests[name] = {**row_manifest(frames[name]), "excluded_missing_common_support": excluded}
    load_s = time.monotonic() - started
    log(f"frozen {snapshot['rows']:,} rows / {snapshot['cells']} cells; "
        f"selected={len(snapshot['selected_cells'])}; loaded in {load_s:.1f}s")
    result = {
        "created_at_utc": datetime.now(timezone.utc).isoformat(), "status": "running",
        "design": {
            "training_years": YEARS, "train_end_target": str(T.TRAIN_END), "seed": 42,
            "requested_cells": 9, "actual_cells": len(snapshot["selected_cells"]), "horizons": args.horizons,
            "max_rounds": args.rounds, "early_stopping": 40, "threads": 2,
            "sampling": {"stride": args.stride, "rule": "(epoch_day + hour_of_day + 42) % stride == 0",
                         "scope": "same schedule in training, val_es, val_select and test; features built before sampling"},
            "climatology": "raw month/hour/cell means from all feature-valid training hours of each window",
            "thresholds": "model and climatology separately maximize F1 on val_es, grid 0.05..0.95 step 0.01",
            "rain_probabilities": "raw; no calibration or fallback; neither val_select nor test makes choices",
            "train_features": "past/current only; up to 24h context before window start; no fitted preprocessing",
            "purge": "T.split; t and t+6h inside each window; 7-day gaps; all 1/3/6h targets finite",
            "val_es": [str(T.VAL_ES_START), str(T.VAL_ES_END)],
            "val_select": [str(T.VAL_SEL_START), str(T.VAL_SEL_END)], "test_start": str(T.TEST_START),
            "aggregation": "pooled rows across sampled cells; separate per-cell test CSV",
            "budget_seconds": args.budget_seconds, "memory_limit_mib": 1024,
            "source_note": "Open-Meteo model/reanalysis output, not independent station observations",
        },
        "snapshot": snapshot, "evaluation_rows": manifests, "load_seconds": round(load_s, 3),
        "versions": {"python": platform.python_version(), "pandas": pd.__version__,
                     "numpy": np.__version__, "lightgbm": lgb.__version__},
        "source_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (
            Path(__file__), Path(T.__file__), Path(T.ai_model.__file__),
            Path(__file__).with_name("backtest_rolling_v3.py"))},
        "windows": [],
    }
    rows, cell_rows = [], []
    for years in YEARS:
        window_started = time.monotonic()
        train = training_window(frames["train_pool"], years)
        if train.empty or any(train[f"rain_target_{h}h"].nunique() != 2 for h in args.horizons):
            raise ValueError(f"training window {years} lacks rows or both rain classes")
        log(f"{years} years: {len(train):,} training rows; "
            f"es/select/test={','.join(str(len(frames[n])) for n in SPLITS[1:])}")
        models, iterations, params = fit_window(train, frames["val_es"], args.horizons, args.rounds, budget)
        fit_s = time.monotonic() - window_started
        clim = climates[years]
        p_es = T.predict_raw(models, frames["val_es"])
        thresholds, climate_thresholds = {}, {}
        for h in args.horizons:
            y = frames["val_es"][f"rain_target_{h}h"].to_numpy()
            thresholds[f"{h}h"] = T.tune_threshold(y, p_es[f"rain_{h}h"])
            climate_thresholds[f"{h}h"] = T.tune_threshold(y, T.clim_at_target(frames["val_es"], clim, h).rain)
        window_result = {"years": years, "start": str(train_start(years)), "train": row_manifest(train),
                         "climatology_rows": sum(a["climatology_training_rows"][str(years)]
                                                 for a in snapshot["audit"].values()),
                         "iterations": iterations, "thresholds": thresholds,
                         "climatology_thresholds": climate_thresholds, "regression_params": params,
                         "classification_params": dict(params, objective="binary", metric="binary_logloss"),
                         "fit_seconds": round(fit_s, 3), "metrics": {}}
        for name in SPLITS[1:]:
            data = frames[name]
            preds = p_es if name == "val_es" else T.predict_raw(models, data)
            scored = {}
            for h in args.horizons:
                key = f"{h}h"
                score = T.score_frame(models, data, clim, h, preds=preds)
                if len(score) != len(data):
                    raise AssertionError("model-specific evaluation rows changed")
                m = metrics(score, thresholds[key], climate_thresholds[key])
                scored[h] = score
                rows.append({"training_years": years, "split": name, "horizon": key,
                             "rows_sha256": manifests[name]["rows_sha256"],
                             "model_threshold": thresholds[key], "climatology_threshold": climate_thresholds[key], **m})
                window_result["metrics"][f"{name}_{key}"] = m
                if name == "test":
                    for cid, group in score.groupby("cell_id", observed=True):
                        cell_rows.append({"training_years": years, "cell_id": cid, "horizon": key,
                                          **metrics(group, thresholds[key], climate_thresholds[key])})
            if name == "test":
                window_result["test_ci95"] = T.block_bootstrap_ci(
                    scored, thresholds, climate_thresholds, n_boot=500, seed=42)
            del preds, scored, score
            check_budget(*budget)
        window_result["runtime_seconds"] = round(time.monotonic() - window_started, 3)
        result["windows"].append(window_result)
        log(f"{years} years done in {window_result['runtime_seconds']:.1f}s")
        del models, train, p_es
        gc.collect()
    result.update(status="complete", runtime_seconds=round(time.monotonic() - started, 3),
                  peak_working_set_mib=round(peak_memory_mb(), 3))
    check_budget(*budget)
    (args.out / "learning_curve_v3.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=True, allow_nan=False) + "\n", encoding="utf-8")
    pd.DataFrame(rows).to_csv(args.out / "learning_curve_v3.csv", index=False, float_format="%.8f")
    pd.DataFrame(cell_rows).to_csv(args.out / "learning_curve_v3_per_cell.csv", index=False, float_format="%.8f")
    log(f"complete: {result['runtime_seconds']:.1f}s, peak={result['peak_working_set_mib']:.1f} MiB")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=T.DB)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--snapshot-end", default="2026-10-18 23:00:00")
    parser.add_argument("--stride", type=int, default=4)
    parser.add_argument("--horizons", type=int, nargs="+", choices=T.HORIZONS, default=[3])
    parser.add_argument("--rounds", type=int, default=300)
    parser.add_argument("--budget-seconds", type=int, default=720)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 300 or not 1 <= args.budget_seconds <= 720:
        parser.error("rounds must be 1..300 and budget-seconds 1..720")
    if len(set(args.horizons)) != len(args.horizons):
        parser.error("horizons must be unique")
    sample_mask(pd.Series(pd.date_range("2020-01-01", periods=1, freq="h")), args.stride)
    run(args)


if __name__ == "__main__":
    main()
