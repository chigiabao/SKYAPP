"""Bounded direct-horizon LightGBM training on real historical hourly labels.

Default is read-only inventory. Explicit --train launches a child with a hard
wall-clock limit (180s default), 2 LightGBM threads, and a 950 MiB RSS guard.
One sampled horizon per sampled issue avoids the hourly rows x168 expansion.
All 168 horizons are represented, not relabelled short-range predictions.

Example: python scripts/train_long_range.py --train --max-seconds 180
Output: models/long_range/{metadata,evaluation}.json and six text boosters.
Existing output directories are never overwritten. No downloads or uploads.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
import long_range_model as M

TRAIN_START = pd.Timestamp("2021-01-01")
TRAIN_END = pd.Timestamp("2024-06-30 23:00")
VAL_START = pd.Timestamp("2024-07-08")
VAL_END = pd.Timestamp("2024-12-24 23:00")
TEST_START = pd.Timestamp("2025-01-01")
LIMITATIONS = [
    "Experimental sampled direct-horizon model; not demonstrated superior at every horizon/cell.",
    "Labels are historical weather-model output, not station observations.",
    "The DB has no issue-vintage/availability timestamps: temporal hindcast is not an operational skill claim.",
    "No future NWP inputs, recursive pseudo-labels, serving climatology, or prediction intervals.",
    "Rain probability is uncalibrated; reported Brier/log-loss are held-out, not accuracy percentages.",
    "Spatial scope is trained cells only; no independent spatial holdout in this bounded run.",
]


def connect(path: Path):
    con = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    con.execute("PRAGMA query_only=ON")
    con.execute("BEGIN")  # One consistent read snapshot even if backfill is running.
    return con


def inventory(con) -> list[dict]:
    return pd.read_sql_query("SELECT cell_id, MIN(timestamp) AS first_hour, MAX(timestamp) AS last_hour, "
                             "COUNT(*) AS rows FROM hourly GROUP BY cell_id", con).to_dict("records")


def rss_mib() -> float:
    if os.name == "nt":
        class Counters(ctypes.Structure):
            _fields_ = [("cb", ctypes.c_ulong), ("faults", ctypes.c_ulong)] + [
                (n, ctypes.c_size_t) for n in ("peak", "rss", "qpeak", "quota", "ppeak", "page", "pp", "pf")]
        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        get_process = ctypes.windll.kernel32.GetCurrentProcess
        get_process.restype = ctypes.c_void_p
        get_memory = ctypes.windll.psapi.GetProcessMemoryInfo
        get_memory.argtypes = (ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong)
        if not get_memory(get_process(), ctypes.byref(counters), counters.cb):
            raise OSError("cannot read process memory budget")
        return counters.peak / 1024 ** 2
    import resource
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value / (1024 ** 2 if sys.platform == "darwin" else 1024)


def check_budget(deadline):
    if time.monotonic() > deadline:
        raise TimeoutError("training time budget exhausted")
    if rss_mib() > 950:
        raise MemoryError("training RSS exceeded 950 MiB guard")


def split_masks(times: pd.Series, test_end: pd.Timestamp) -> dict:
    """Every issue and ALL possible horizon labels remain within one split."""
    final = times + pd.Timedelta(hours=M.MAX_HORIZON)
    return {
        "train": (times >= TRAIN_START) & (final <= TRAIN_END),
        "validation": (times >= VAL_START) & (final <= VAL_END),
        "test": (times >= TEST_START) & (final <= test_end),
    }


def target_values(frame, name):
    src, lower, upper = M.TARGETS[name]
    source = frame[src] if src in frame else pd.Series(np.nan, index=frame.index)
    raw = pd.to_numeric(source, errors="coerce").to_numpy(dtype=float, copy=True)
    raw[~np.isfinite(raw)] = np.nan
    if name == "rain_probability":
        return np.where(np.isfinite(raw) & (raw >= 0), (raw > M.RAIN_THRESHOLD_MM).astype(float), np.nan)
    if lower is not None:
        raw[raw < lower] = np.nan
    if upper is not None:
        raw[raw > upper] = np.nan
    return raw


def sample_cell(raw, cell_id, static, quotas, stride, seed, test_end):
    """Choose real issue/valid pairs by timestamp; gaps are NaN, never filled."""
    raw = raw.copy()
    raw["timestamp"] = M.timestamps(raw.timestamp)
    if raw.timestamp.duplicated().any():
        raise ValueError(f"duplicate historical timestamps: {cell_id}")
    raw = raw.set_index("timestamp").sort_index()
    raw = raw.reindex(pd.date_range(raw.index.min(), raw.index.max(), freq="h"))
    raw = raw.rename_axis("timestamp").reset_index()
    features = M.issue_features(raw, static)
    complete = raw.temperature.notna().rolling(M.MIN_HISTORY_HOURS).sum().eq(M.MIN_HISTORY_HOURS)
    rng = np.random.default_rng(seed)
    targets = {name: target_values(raw, name) for name in M.TARGETS}
    train_raw = raw[(raw.timestamp >= TRAIN_START) & (raw.timestamp <= TRAIN_END)].copy()
    clim = {}
    for name, target in targets.items():
        values = pd.Series(target, index=raw.index).loc[train_raw.index]
        table = pd.DataFrame({"month": train_raw.timestamp.dt.month, "hour": train_raw.timestamp.dt.hour,
                              "y": values}).groupby(["month", "hour"]).y.mean()
        clim[name] = (table, float(values.mean()))
    results = {}
    for split, mask in split_masks(raw.timestamp, test_end).items():
        candidates = np.flatnonzero((mask & complete).to_numpy())[int(rng.integers(stride))::stride]
        n = min(quotas[split], len(candidates))
        if n < M.MAX_HORIZON:
            raise ValueError(f"insufficient {split} issues at {cell_id}: {n}")
        indices = np.sort(rng.choice(candidates, n, replace=False))
        horizons = np.resize(np.arange(1, M.MAX_HORIZON + 1), n)
        rng.shuffle(horizons)
        issue_times = raw.timestamp.iloc[indices].reset_index(drop=True)
        valid_times = raw.timestamp.iloc[indices + horizons].reset_index(drop=True)
        x = M.horizon_features(features.iloc[indices], issue_times, horizons)
        rows = pd.DataFrame({"cell_id": cell_id, "issued_at": issue_times,
                             "valid_at": valid_times, "horizon_hours": horizons})
        for name, target in targets.items():
            rows[name] = target[indices + horizons]
            rows[f"persistence_{name}"] = target[indices]
            table, fallback = clim[name]
            keys = pd.MultiIndex.from_arrays([valid_times.dt.month, valid_times.dt.hour])
            rows[f"climatology_{name}"] = table.reindex(keys).fillna(fallback).to_numpy()
        results[split] = (x, rows)
    return results


def metrics(y, pred, binary=False):
    error = np.asarray(pred) - np.asarray(y)
    if binary:
        p = np.clip(pred, 1e-7, 1 - 1e-7)
        return {"brier": float(np.mean(error ** 2)),
                "log_loss": float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))}
    return {"mae": float(np.mean(np.abs(error))), "rmse": float(np.sqrt(np.mean(error ** 2)))}


def evaluate(rows, name, predictions):
    binary = name == "rain_probability"
    y = rows[name].to_numpy()
    pers = rows[f"persistence_{name}"].to_numpy()
    clim = rows[f"climatology_{name}"].to_numpy()
    valid = np.isfinite(y) & np.isfinite(predictions) & np.isfinite(pers) & np.isfinite(clim)
    primary = "brier" if binary else "rmse" if name == "precipitation_mm" else "mae"

    def group(mask):
        mask = mask & valid
        if not mask.any():
            return {"n": 0}
        scores = {label: metrics(y[mask], p[mask], binary) for label, p in
                  (("model", predictions), ("persistence", pers), ("climatology", clim))}
        return {"n": int(mask.sum()), **scores,
                "beats_both_baselines": scores["model"][primary] < min(
                    scores["persistence"][primary], scores["climatology"][primary])}

    h = rows.horizon_hours.to_numpy()
    return {"primary_metric": primary, "overall": group(np.ones(len(rows), dtype=bool)),
            "by_horizon": {str(i): group(h == i) for i in range(1, M.MAX_HORIZON + 1)},
            "by_day": {str(i): group((h > (i - 1) * 24) & (h <= i * 24)) for i in range(1, 8)},
            "by_cell": {cid: group(rows.cell_id.eq(cid).to_numpy()) for cid in sorted(rows.cell_id.unique())}}


def train(args):
    import lightgbm as lgb
    start = time.monotonic()
    deadline = start + args.max_seconds - 3
    output = args.out
    if output.exists():
        raise ValueError(f"output already exists; choose a new --out: {output}")
    quotas = {"train": args.train_samples, "validation": args.eval_samples, "test": args.eval_samples}
    if min(quotas.values()) < M.MAX_HORIZON or max(quotas.values()) > 1000:
        raise ValueError("sample quotas must be 168..1000 per split/cell")
    frames = {key: [] for key in quotas}
    records = {key: [] for key in quotas}
    snapshots = {}
    statics = {}
    with connect(args.db) as con:
        coverage = inventory(con)
        if len(coverage) > 80:
            raise ValueError("bounded run supports at most 80 cells")
        cells = {row[0]: dict(zip(M.STATIC_FEATURES, row[1:])) for row in
                 con.execute("SELECT cell_id,lat,lon,elevation FROM cells")}
        sources = dict(con.execute("SELECT cell_id,source FROM cells"))
        test_end = min(pd.Timestamp(max(r["last_hour"] for r in coverage)),
                       pd.Timestamp.now(tz=M.TIMEZONE).tz_localize(None).floor("h") - pd.Timedelta(hours=1))
        available = {column[1] for column in con.execute("PRAGMA table_info(hourly)")}
        select = ",".join(f'"{name}"' if name in available else f'NULL AS "{name}"'
                          for name in M.WEATHER_FEATURES)
        for i, entry in enumerate(coverage):
            check_budget(deadline)
            cid = entry["cell_id"]
            raw = pd.read_sql_query(f"SELECT timestamp,{select} FROM hourly WHERE cell_id=? "
                                    "AND timestamp>=? AND timestamp<=? ORDER BY timestamp", con,
                                    params=(cid, str(TRAIN_START), str(test_end)))
            sampled = sample_cell(raw, cid, cells[cid], quotas, args.issue_stride, args.seed + i, test_end)
            statics[cid] = cells[cid]
            snapshots[cid] = {**entry, "source": sources[cid]}
            for split, (x, rows) in sampled.items():
                frames[split].append(x)
                records[split].append(rows)
        print(f"Loaded {len(statics)} cells in {time.monotonic()-start:.1f}s", flush=True)
    x = {s: pd.concat(v, ignore_index=True) for s, v in frames.items()}
    rows = {s: pd.concat(v, ignore_index=True) for s, v in records.items()}
    del frames, records, raw, sampled
    if set(rows["train"].horizon_hours) != set(range(1, 169)):
        raise ValueError("not all direct training horizons represented")
    params = dict(num_threads=2, num_leaves=15, min_data_in_leaf=60, learning_rate=0.07,
                  max_bin=63, verbosity=-1, seed=args.seed, deterministic=True, force_col_wise=True)
    models, capabilities, evaluations = {}, {}, {}

    def budget_callback(env):
        check_budget(deadline)

    for name in M.TARGETS:
        check_budget(deadline)
        binary = name == "rain_probability"
        masks = {s: np.isfinite(r[name].to_numpy()) for s, r in rows.items()}
        counts = {s: int(m.sum()) for s, m in masks.items()}
        if min(counts.values()) < 100 or (binary and any(
                rows[s].loc[masks[s], name].nunique() < 2 for s in ("train", "validation"))):
            capabilities[name] = {"status": "unsupported", "reason": "insufficient real labels/classes", "rows": counts}
            continue
        objective = "binary" if binary else "tweedie" if name == "precipitation_mm" else "regression_l1"
        if name == "precipitation_mm" and not (rows["train"].loc[masks["train"], name] > 0).any():
            capabilities[name] = {"status": "unsupported", "reason": "no positive precipitation labels"}
            continue
        metric = "binary_logloss" if binary else "rmse" if name == "precipitation_mm" else "mae"
        model = lgb.train({**params, "objective": objective, "metric": metric},
            lgb.Dataset(x["train"].loc[masks["train"]], label=rows["train"].loc[masks["train"], name]),
            num_boost_round=args.rounds,
            valid_sets=[lgb.Dataset(x["validation"].loc[masks["validation"]],
                                    label=rows["validation"].loc[masks["validation"], name])],
            callbacks=[budget_callback, lgb.early_stopping(15, verbose=False)])
        models[name] = model
        capabilities[name] = {"status": "available", "horizons": [1, 168], "rows": counts,
                              "best_iteration": model.best_iteration}
        evaluations[name] = {s: evaluate(rows[s], name, M.bounded(name, model.predict(x[s], num_threads=2)))
                             for s in ("validation", "test")}
        print(f"{name}: {model.best_iteration} rounds, test={evaluations[name]['test']['overall']}, "
              f"elapsed={time.monotonic()-start:.1f}s RSS={rss_mib():.0f}MiB", flush=True)
    if not models:
        raise ValueError("no target could be trained")
    check_budget(deadline)
    known_through = max(rows["train"].valid_at.max(), rows["validation"].valid_at.max())
    meta = {"schema_version": 1, "model_version": f"lgbm-direct-168h-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}",
            "source": "ai", "trained_at": datetime.now(timezone.utc).isoformat(),
            "trained_through": M.local_iso(known_through),
            "fit_labels_through": M.local_iso(rows["train"].valid_at.max()),
            "selection_labels_through": M.local_iso(rows["validation"].valid_at.max()),
            "max_horizon_hours": 168, "feature_columns": M.feature_columns(), "cell_static": statics,
            "capabilities": capabilities, "data_snapshot": snapshots,
            "data": str(args.db.resolve()), "data_timezone": M.TIMEZONE,
            "units": {"temperature": "celsius", "humidity": "%", "precipitation_mm": "mm/hour",
                      "wind_speed": "km/h", "cloud_cover": "%", "rain_probability": "0..1"},
            "rain_threshold_mm": M.RAIN_THRESHOLD_MM, "limitations": LIMITATIONS,
            "split": {"train": [str(TRAIN_START), str(TRAIN_END)], "validation": [str(VAL_START), str(VAL_END)],
                      "test": [str(TEST_START), str(test_end)], "gap_hours": 168,
                      "rule": "issue and issue+168h inside split; no refit on validation/test",
                      "sample_rows": {s: len(r) for s, r in rows.items()}},
            "sampling": {"method": "random issues without replacement; balanced independently shuffled real horizons",
                         "issue_stride": args.issue_stride, "per_cell": quotas, "seed": args.seed},
            "params": params, "max_rounds": args.rounds,
            "resources": {"elapsed_seconds": round(time.monotonic()-start, 2), "peak_rss_mib": round(rss_mib(), 1)}}
    output.mkdir(parents=True)
    for name, model in models.items():
        model.save_model(str(output / f"{name}.txt"))
    (output / "evaluation.json").write_text(json.dumps(evaluations, indent=2, allow_nan=False), encoding="utf-8")
    # Manifest is published last, so a partial write never appears ready to serve.
    (output / "metadata.json").write_text(json.dumps(meta, indent=2, allow_nan=False), encoding="utf-8")
    print(f"Artifact ready: {output}; trained_through={meta['trained_through']}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=BACKEND / "data/history/cells_history.db")
    parser.add_argument("--out", type=Path, default=M.DEFAULT_MODEL_DIR)
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--max-seconds", type=int, default=180)
    parser.add_argument("--train-samples", type=int, default=672)
    parser.add_argument("--eval-samples", type=int, default=168)
    parser.add_argument("--issue-stride", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=100)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    if not 15 <= args.max_seconds <= 180 or not 1 <= args.rounds <= 200 or not 1 <= args.issue_stride <= 24:
        parser.error("bounded run requires seconds=15..180, rounds=1..200, stride=1..24")
    if not args.train:
        with connect(args.db) as con:
            print(json.dumps({"coverage": inventory(con), "training_started": False}, indent=2))
    elif args.worker:
        train(args)
    else:
        try:
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], "--worker"],
                timeout=args.max_seconds, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8")
        except subprocess.TimeoutExpired:
            raise SystemExit("Stopped at wall-clock budget; no completed artifact is claimed.")
        print(result.stdout, end="", flush=True)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
