"""Bounded, offline interval audit. No writes or predictions unless --run is given."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import sys
import time
from types import SimpleNamespace

for _variable in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ[_variable] = "2"
os.environ["INGEST_ENABLED"] = "0"

import joblib
import numpy as np
import pandas as pd
import psutil

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
import ai_model as A  # noqa: E402

CAL_START = pd.Timestamp("2025-10-01 00:00:00")
CAL_END = pd.Timestamp("2026-03-24 23:00:00")
TEST_START = pd.Timestamp("2026-04-01 00:00:00")
TEST_END = pd.Timestamp("2026-10-18 23:00:00")
LEVEL, MIN_CELL, MIN_DAYS = 0.9, 720, 30
MIN_POOL, MIN_POOL_DAYS = 3000, 60
GROUPING, SCALE = "cell_season", "abs"
SEED, BOOTSTRAPS, THREADS = 42, 1000, 2
MAX_SECONDS, MAX_BYTES = 900, int(1.5 * 1024**3)
DEFAULT_OUTPUT = BACKEND / "models/evaluation/data_upgrade_20261022"
ALLOWED_OUTPUTS = (
    DEFAULT_OUTPUT,
    BACKEND / "models/evaluation/data_upgrade_20261023",
    BACKEND / "models/evaluation/interval_recal_20261023",
)


def design():
    return {
        "status": "preregistered_single_variant_no_test_tuning",
        "calibration": [str(CAL_START), str(CAL_END)],
        "evaluation": [str(TEST_START), str(TEST_END)],
        "time_rule": "local naive Asia/Ho_Chi_Minh; cal issue and issue+6h inside cal; test issue and each target inside test",
        "purge": "2026-03-25..2026-03-31; seven entire days",
        "retrospective": "Reuses previously reported test period; NOT pristine final accuracy evidence",
        "frozen": "All boosters, features, cell roster and serving fallback; no retraining or tuning",
        "variant": {"grouping": GROUPING, "scale": SCALE, "nominal": LEVEL,
                    "quantile": "sorted score at ceil((n+1)*0.90), one-based, no interpolation",
                    "score": "max(qlo-y,y-qhi), before point inclusion; offset=max(0,quantile)",
                    "cell_min_labels": MIN_CELL, "cell_min_target_days": MIN_DAYS,
                    "fallback": "pooled horizon quantile, also for unseen target-season keys",
                    "horizon_min_labels": MIN_POOL, "horizon_min_target_days": MIN_POOL_DAYS},
        "gate": {"all_horizons_pooled_and_macro_coverage_min": .90,
                 "every_cell_coverage_min": .85, "horizon_width_ratio_max": 1.15,
                 "cell_width_ratio_max": 1.25, "cell_eval_labels_min": 720,
                 "all_parity_and_frozen_input_checks": True,
                 "meaning": "Reject on any failure; passing does not guarantee future 90% coverage"},
        "uncertainty": {"method": "paired bootstrap of consecutive seven-day issue blocks; all cells kept together",
                        "replicates": BOOTSTRAPS, "seed": SEED, "interval": "percentile 95%",
                        "limitation": "29 seasonal blocks; temporal/spatial dependence and shift remain"},
        "primary": "same valid rows, API-rounded endpoints, served point fallback included",
        "baseline": "original frozen candidate intervals on the exact same rows",
        "limits": {"seconds": MAX_SECONDS, "peak_process_bytes": MAX_BYTES, "lightgbm_threads": THREADS},
        "promotion": "audit and proposed offsets only; leader and independent QA decide",
    }


def validate_windows(cal_start=CAL_START, cal_end=CAL_END, test_start=TEST_START, test_end=TEST_END):
    if not cal_start < cal_end < test_start < test_end:
        raise ValueError("overlapping or unordered windows")
    if test_start - cal_end < pd.Timedelta(days=7):
        raise ValueError("seven-day purge required")


def window_mask(times, horizon, start, end, calibration=False):
    times = pd.DatetimeIndex(times)
    target = times + pd.Timedelta(hours=max(A.HORIZONS) if calibration else horizon)
    return np.asarray((times >= start) & (target <= end))


def finite_quantile(scores, level=LEVEL):
    scores = np.asarray(scores, dtype=float)
    if scores.ndim != 1 or not len(scores) or not np.isfinite(scores).all() or not 0 < level < 1:
        raise ValueError("finite nonempty one-dimensional calibration scores required")
    rank = math.ceil((len(scores) + 1) * level)
    if rank > len(scores):
        raise ValueError("insufficient labels for a finite conformal quantile")
    return float(np.partition(scores, rank - 1)[rank - 1])


def group_keys(h, cid, times, static, grouping=GROUPING):
    target = pd.DatetimeIndex(times) + pd.Timedelta(hours=h)
    return A.interval_group_keys(grouping, np.full(len(target), h), np.full(len(target), cid),
                                 target.month, target.hour, static)


def offsets_for(keys, h, table):
    fallback = float(table[str(h)])
    return np.array([table.get(str(key), fallback) for key in keys], dtype=float)


def fit_offsets(parts):
    """Only calibration records enter here. Each tuple is h, keys, target days, scores."""
    table, counts = {}, {}
    for h in A.HORIZONS:
        selected = [part for part in parts if part[0] == h]
        if not selected:
            raise ValueError(f"missing calibration horizon {h}")
        keys = np.concatenate([p[1] for p in selected])
        days = np.concatenate([p[2] for p in selected])
        scores = np.concatenate([p[3] for p in selected])
        if not len(keys) == len(days) == len(scores):
            raise ValueError("unaligned calibration rows")
        if (days < CAL_START.normalize().value).any() or (days > CAL_END.normalize().value).any():
            raise ValueError("calibration contains out-of-window target labels")
        n, nd = len(scores), len(np.unique(days))
        if n < MIN_POOL or nd < MIN_POOL_DAYS:
            raise ValueError(f"insufficient horizon calibration support: {h}h {n} labels/{nd} days")
        table[str(h)] = max(0.0, finite_quantile(scores))
        counts[str(h)] = {"n": n, "days": nd, "source": "horizon"}
        for key in np.unique(keys):
            mask = keys == key
            n, nd = int(mask.sum()), len(np.unique(days[mask]))
            eligible = n >= MIN_CELL and nd >= MIN_DAYS
            if eligible:
                table[str(key)] = max(0.0, finite_quantile(scores[mask]))
            counts[str(key)] = {"n": n, "days": nd, "source": "cell_season" if eligible else "horizon"}
    return table, counts


def fingerprint(directory):
    paths = list(directory.glob("*")) + [Path(A.__file__), Path(__file__),
                                          BACKEND / "scripts/train_global_v3_interval.py"]
    result = {}
    for path in paths:
        if path.is_file():
            with path.open("rb") as source:
                result[str(path.resolve())] = hashlib.file_digest(source, "sha256").hexdigest()
    return result


def write_json(path, value):
    content = json.dumps(value, indent=2, allow_nan=False, default=str) + "\n"
    with path.open("x", encoding="utf-8") as output:
        output.write(content)


def validate_output(output, directory):
    out, directory = output.resolve(), directory.resolve()
    if out not in [path.absolute() for path in ALLOWED_OUTPUTS]:
        raise ValueError("writes restricted to owned evaluation directories")
    if out.is_relative_to(directory) or directory.is_relative_to(out):
        raise ValueError("evaluation output must not overlap the model directory")
    if any(out.glob("interval_*")):
        raise FileExistsError("interval artifacts already exist; refusing to overwrite or mix runs")
    return out


class Budget:
    def __init__(self):
        self.start = time.monotonic()
        self.peak = 0
        self.process = psutil.Process()

    def check(self):
        memory = self.process.memory_info()
        self.peak = max(self.peak, memory.rss, getattr(memory, "peak_wset", 0))
        if self.peak > MAX_BYTES or time.monotonic() - self.start > MAX_SECONDS:
            raise RuntimeError("bounded experiment exceeded memory/time limit; no promotion")

    def predict(self, model, x):
        self.check()
        result = model.predict(x, num_threads=THREADS)
        self.check()
        if not np.isfinite(result).all():
            raise ValueError("nonfinite frozen-model prediction")
        return result


def read_cell(con, cid, static, columns, snapshot_end):
    end = min(TEST_END, pd.Timestamp(snapshot_end))
    raw = pd.read_sql_query(
        "SELECT * FROM hourly WHERE cell_id=? AND timestamp>=? AND timestamp<=? ORDER BY timestamp",
        con, params=(cid, str(CAL_START - pd.Timedelta(hours=48)), str(end)))
    if raw.empty:
        raise ValueError(f"empty source cell: {cid}")
    source_types = {k: str(v) for k, v in raw.dtypes.items()}
    raw["timestamp"] = pd.to_datetime(raw.timestamp, errors="raise")
    duplicates = int(raw.timestamp.duplicated().sum())
    if duplicates or raw.timestamp.isna().any() or not (raw.timestamp == raw.timestamp.dt.floor("h")).all():
        raise ValueError("duplicate, missing or nonhourly timestamps")
    fields = [c for c in raw if c not in ("cell_id", "timestamp")]
    numeric_audit = {}
    for field in fields:
        before = raw[field]
        values = pd.to_numeric(before, errors="coerce").astype(float)
        invalid = int((before.notna() & values.isna()).sum())
        nonfinite = int((values.notna() & ~np.isfinite(values)).sum())
        values = values.where(np.isfinite(values))
        raw[field] = values
        numeric_audit[field] = {"missing": int(values.isna().sum()), "invalid_tokens": invalid,
                                "infinite": nonfinite,
                                "min": float(values.min()) if values.notna().any() else None,
                                "max": float(values.max()) if values.notna().any() else None}
    digest = hashlib.sha256(pd.util.hash_pandas_object(raw, index=False).values.tobytes()).hexdigest()
    frame = raw.drop(columns="cell_id").set_index("timestamp")
    frame = frame.reindex(pd.date_range(CAL_START - pd.Timedelta(hours=48), end, freq="h"))
    frame = frame.rename_axis("timestamp").reset_index()
    features = A.build_features_v3(frame, static)[columns].astype(np.float32)
    eligible = np.isfinite(features.to_numpy()).all(axis=1)
    audit = {"cell_id": cid, "raw_rows": len(raw), "columns": len(raw.columns), "dtypes": source_types,
             "source_sha256": digest, "duplicates": duplicates, "gaps": len(frame) - len(raw),
             "feature_rows": len(features), "feature_columns": len(columns),
             "invalid_feature_rows_including_warmup": int((~eligible).sum()),
             "ranges_missing": numeric_audit}
    return frame, features.to_numpy(), eligible, audit


def row_stats(y, old, new, raw_old=None):
    old_lo, old_hi = old
    new_lo, new_hi = new
    values = {"n": len(y), "old_hits": int(((y >= old_lo) & (y <= old_hi)).sum()),
              "new_hits": int(((y >= new_lo) & (y <= new_hi)).sum()),
              "old_width_sum": float(np.sum(old_hi - old_lo)),
              "new_width_sum": float(np.sum(new_hi - new_lo))}
    if raw_old is not None:
        values.update(raw_point_hits=int(((y >= raw_old[0]) & (y <= raw_old[1])).sum()),
                      raw_point_width_sum=float(np.sum(raw_old[1] - raw_old[0])))
    return values


def metrics(stats):
    result = dict(stats)
    n = result["n"]
    for name in ("old", "new"):
        result[f"{name}_coverage"] = result[f"{name}_hits"] / n
        result[f"{name}_width"] = result[f"{name}_width_sum"] / n
    result["coverage_delta"] = result["new_coverage"] - result["old_coverage"]
    result["width_delta"] = result["new_width"] - result["old_width"]
    result["width_ratio"] = result["new_width"] / result["old_width"]
    return result


def bootstrap(blocks):
    values = pd.DataFrame(blocks).groupby("block").sum(numeric_only=True)
    rng = np.random.default_rng(SEED)
    sample = values.to_numpy()[rng.integers(0, len(values), size=(BOOTSTRAPS, len(values)))].sum(axis=1)
    sums = {name: sample[:, i] for i, name in enumerate(values.columns)}
    old, new = sums["old_hits"] / sums["n"], sums["new_hits"] / sums["n"]
    derived = {"old_coverage": old, "new_coverage": new, "coverage_delta": new - old,
               "width_delta": (sums["new_width_sum"] - sums["old_width_sum"]) / sums["n"]}
    return {"blocks": len(values), **{key: np.quantile(v, [.025, .975]).tolist() for key, v in derived.items()}}


def gate(horizons, cells):
    reasons = []
    for h, row in horizons.items():
        if min(row["new_coverage"], row["new_macro_coverage"]) < .90:
            reasons.append(f"{h}: coverage below 90%")
        if row["width_ratio"] > 1.15:
            reasons.append(f"{h}: mean width exceeds 115% of baseline")
    for row in cells:
        if row["new_coverage"] < .85 or row["width_ratio"] > 1.25 or row["n"] < 720:
            reasons.append(f"{row['cell_id']}/{row['h']}h: cell coverage/width/support gate")
    return {"pass": not reasons, "failures": reasons, "promotion": "not performed"}


def run(args):
    validate_windows()
    out = validate_output(args.output, args.model_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_json(out / "interval_design.json", design())
    budget = Budget()
    directory = args.model_dir.resolve()
    before = fingerprint(directory)
    load_json = lambda name: json.loads((directory / name).read_text(encoding="utf-8"))
    meta, extension, static = load_json("metadata_v3.json"), load_json("extension_v3.json"), load_json("cell_static.json")
    old = extension["interval"]
    if old.get("version") != 2 or extension["base_model_version"] != meta["model_version"]:
        raise ValueError("requires compatible v2 interval metadata and frozen v3 boosters")
    if pd.Timestamp(old["split"]["cal"][1]) >= CAL_START or pd.Timestamp(meta["split"]["val_select"][1]) >= CAL_START:
        raise ValueError("new calibration must follow all previous fitting/selection labels")
    columns = load_json("feature_columns.json")
    if columns != A.feature_columns_v3():
        raise ValueError("feature order mismatch")
    policy = A._load_policy(meta, directory)
    if policy != load_json(A.POLICY_FILE):
        raise ValueError("serving policy did not load unchanged")
    cells = sorted(set(meta["test_cells"] + meta.get("late_cells_evaluated_on_test", [])))
    if not cells or any(cid != A.canonical_cell_id(cid) for cid in cells):
        raise ValueError("expected nonempty unique canonical cell roster")
    audits, hashes = [], {}
    con = sqlite3.connect(f"{args.database.resolve().as_uri()}?mode=ro", uri=True)
    con.execute("PRAGMA query_only=ON")
    con.execute("BEGIN")
    try:
        for cid in cells:
            budget.check()
            _, _, _, audit = read_cell(con, cid, static[cid], columns, meta["data_snapshot"][cid][1])
            audits.append(audit)
            hashes[cid] = audit["source_sha256"]
        write_json(out / "interval_data_audit.json", {"cells": len(cells), "cell_audits": audits,
                   "missing_policy": "invalid tokens, nulls and infinities remain missing; no zero imputation",
                   "data_kind": "model/reanalysis output, not independent station observations"})
        print(f"audit complete: {len(cells)} cells; loading 9 frozen boosters", flush=True)
        models = {(q, h): joblib.load(directory / f"temperature{('_' + q) if q else ''}_model_{h}h.pkl")
                  for h in A.HORIZONS for q in ("", "q05", "q95")}
        A._v3.update(static=static)
        interval_models = {f"temp_{q}_{h}h": SimpleNamespace(predict=lambda x, m=m: budget.predict(m, x))
                           for (q, h), m in models.items() if q}
        old_ext = {"models": interval_models, "interval": old, "offsets": old["offsets"]}
        parts, full_rows, test_rows, seasonal_rows = [], [], [], []
        blocks = {h: [] for h in A.HORIZONS}
        parity = {"comparisons": 0, "max_abs_error": 0.0, "fallback_rows": 0, "new_group_fallback_rows": 0}
        row_hash = {h: hashlib.sha256() for h in A.HORIZONS}
        table = None
        for phase in ("calibration", "evaluation"):
            for number, cid in enumerate(cells, 1):
                frame, x, eligible, audit = read_cell(con, cid, static[cid], columns, meta["data_snapshot"][cid][1])
                if audit["source_sha256"] != hashes[cid]:
                    raise ValueError("source changed within frozen read transaction")
                times = pd.DatetimeIndex(frame.timestamp)
                cal_mask = window_mask(times, 6, CAL_START, CAL_END, calibration=True)
                phase_mask = cal_mask if phase == "calibration" else ((times >= CAL_START) & ~cal_mask)
                for h in A.HORIZONS:
                    y_all = frame.temperature.shift(-h).to_numpy(dtype=float)
                    valid = eligible & phase_mask & np.isfinite(y_all) & (times + pd.Timedelta(hours=h) <= TEST_END)
                    xx, y, issued = x[valid], y_all[valid], times[valid]
                    if not len(y):
                        raise ValueError(f"empty {phase} cell/horizon")
                    q1, q2 = (budget.predict(models[q, h], xx) for q in ("q05", "q95"))
                    qlo, qhi = np.minimum(q1, q2), np.maximum(q1, q2)
                    raw_point = budget.predict(models["", h], xx)
                    point, _ = A.apply_policy(policy, h, np.full(len(y), cid), raw_point, np.zeros(len(y)),
                                              xx[:, columns.index("temperature")], xx[:, columns.index("precipitation")])
                    keys = group_keys(h, cid, issued, static)
                    old_off = offsets_for(group_keys(h, cid, issued, static, old["grouping"]), h, old["offsets"])
                    old_interval = A.conformal_interval(qlo, qhi, old_off, old["scale"], point)
                    raw_interval = A.conformal_interval(qlo, qhi, old_off, old["scale"], raw_point)
                    # Historical training reports cast labels to float32; primary API audit uses source precision.
                    full_rows.append({"cell_id": cid, "h": h, **row_stats(y.astype(np.float32), old_interval, old_interval, raw_interval)})
                    if phase == "calibration":
                        scores = np.maximum(qlo - y, y - qhi)
                        days = (issued + pd.Timedelta(hours=h)).normalize().as_unit("ns").asi8
                        parts.append((h, keys, days, scores))
                        continue
                    new_interval = A.conformal_interval(qlo, qhi, offsets_for(keys, h, table), SCALE, point)
                    new_ext = {"models": interval_models, "interval": {"version": 2, "grouping": GROUPING,
                               "scale": SCALE, "nominal": LEVEL}, "offsets": table}
                    for ix in (0, len(y) - 1):
                        for ext, interval in ((old_ext, old_interval), (new_ext, new_interval)):
                            actual = A._interval_v3(ext, xx[[ix]], float(point[ix]), h, cid, issued[ix])[:2]
                            error = float(np.max(np.abs(np.array(actual) - np.array(interval)[:, ix])))
                            parity["comparisons"] += 1
                            parity["max_abs_error"] = max(parity["max_abs_error"], error)
                            if error > 1e-10:
                                raise ValueError("actual interval serving parity failed")
                    keep = window_mask(issued, h, TEST_START, TEST_END)
                    yy, tt = y[keep], issued[keep]
                    oo = tuple(np.round(a[keep], 2) for a in old_interval)
                    nn = tuple(np.round(a[keep], 2) for a in new_interval)
                    if not len(yy) or not all(np.isfinite(a).all() for a in (*oo, *nn)):
                        raise ValueError("empty or nonfinite evaluation intervals")
                    row_hash[h].update(cid.encode())
                    row_hash[h].update(tt.as_unit("ns").asi8.tobytes())
                    row_hash[h].update(yy.tobytes())
                    fallback = float(policy.get("fallback", {}).get(cid, {}).get(f"{h}h", {}).get("temperature_weight", 1)) != 1
                    parity["fallback_rows"] += len(yy) if fallback else 0
                    parity["new_group_fallback_rows"] += int(sum(k not in table for k in keys[keep]))
                    test_rows.append({"cell_id": cid, "h": h, "serving_fallback": fallback, **metrics(row_stats(yy, oo, nn))})
                    target = tt + pd.Timedelta(hours=h)
                    for month in np.unique(target.month):
                        selected = target.month == month
                        seasonal_rows.append({"cell_id": cid, "h": h, "month": int(month),
                             **row_stats(yy[selected], tuple(a[selected] for a in oo), tuple(a[selected] for a in nn))})
                    block_id = ((tt.normalize() - TEST_START).days // 7).to_numpy()
                    for block in np.unique(block_id):
                        selected = block_id == block
                        blocks[h].append({"block": int(block), **row_stats(yy[selected],
                                         tuple(a[selected] for a in oo), tuple(a[selected] for a in nn))})
                if number % 10 == 0 or number == len(cells):
                    print(f"{phase}: {number}/{len(cells)} cells, {time.monotonic()-budget.start:.1f}s, peak {budget.peak/1024**2:.1f} MiB", flush=True)
            if phase == "calibration":
                table, counts = fit_offsets(parts)
                write_json(out / "interval_proposed_offsets.json", {"not_promoted": True, "grouping": GROUPING,
                           "scale": SCALE, "nominal": LEVEL, "calibration_level": LEVEL,
                           "calibration_cutoff": str(CAL_END), "offsets": table, "counts": counts})
                parts.clear()
                print("calibration frozen before evaluating final-window labels", flush=True)
        data = pd.DataFrame(test_rows)
        horizons, old_full = {}, {}
        sums = ["n", "old_hits", "new_hits", "old_width_sum", "new_width_sum"]
        for h in A.HORIZONS:
            group = data[data.h == h]
            result = metrics(group[sums].sum().to_dict())
            result.update(cells=len(group), old_macro_coverage=float(group.old_coverage.mean()),
                          new_macro_coverage=float(group.new_coverage.mean()),
                          old_min_cell_coverage=float(group.old_coverage.min()),
                          new_min_cell_coverage=float(group.new_coverage.min()),
                          cells_below_90=int((group.new_coverage < .9).sum()),
                          cells_below_85=int((group.new_coverage < .85).sum()),
                          paired_rows_sha256=row_hash[h].hexdigest(), ci95=bootstrap(blocks[h]))
            result["target_90_within_ci95"] = bool(result["ci95"]["new_coverage"][0] <= LEVEL <= result["ci95"]["new_coverage"][1])
            horizons[f"{h}h"] = result
            full = pd.DataFrame(full_rows)
            full = full[full.h == h].groupby("cell_id").sum(numeric_only=True)
            old_full[f"{h}h"] = {"n": int(full.n.sum()),
                "served_macro_coverage": float((full.old_hits / full.n).mean()),
                "served_macro_width": float((full.old_width_sum / full.n).mean()),
                "raw_point_macro_coverage": float((full.raw_point_hits / full.n).mean()),
                "raw_point_macro_width": float((full.raw_point_width_sum / full.n).mean()),
                "published": old["test"][f"{h}h"]}
        budget.check()
        after = fingerprint(directory)
        if before != after:
            raise ValueError("frozen source/artifact hashes changed during experiment")
        data.to_csv(out / "interval_per_cell.csv", index=False, mode="x")
        seasonal = pd.DataFrame(seasonal_rows)
        seasonal = seasonal.groupby(["h", "month"])[sums].sum().reset_index()
        pd.DataFrame([metrics(row) for row in seasonal.to_dict("records")]).to_csv(out / "interval_per_month.csv", index=False, mode="x")
        pd.DataFrame(full_rows).groupby(["cell_id", "h"]).sum(numeric_only=True).reset_index().to_csv(out / "interval_old_full_period.csv", index=False, mode="x")
        report = {"design": design(), "horizons": horizons, "gate": gate(horizons, test_rows),
                  "old_full_period_unrounded_parity_audit": old_full, "serving_parity": parity,
                  "source_hashes_unchanged": True, "source_hashes": before,
                  "data_cell_hashes": hashes, "elapsed_seconds": time.monotonic()-budget.start,
                  "peak_process_mib": budget.peak/1024**2,
                  "integration": {"calibration_label_cutoff": str(CAL_END),
                     "verification_cutoff_must_remain_at_least": str(TEST_END),
                     "reason": "Original reported test is reused for evaluation/promotion; never backdate eligibility",
                     "artifact": "none; proposed offsets only; update interval split.cal and evaluation provenance in a separate candidate after QA",
                     "trained_through": "Long-range model field is separate; if shared provenance is introduced it must include calibration and selection cutoffs"}}
        write_json(out / "interval_report.json", report)
        print(json.dumps({"gate": report["gate"], "horizons": horizons, "seconds": report["elapsed_seconds"],
                          "peak_mib": report["peak_process_mib"]}, indent=2), flush=True)
    finally:
        con.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Explicitly run bounded offline audit and write interval outputs")
    parser.add_argument("--model-dir", type=Path, default=BACKEND / "models/v3")
    parser.add_argument("--database", type=Path, default=BACKEND / "data/history/cells_history.db")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    if not args.run:
        print(json.dumps({"dry_run": True, "writes": False, "predictions": False, "design": design()}, indent=2))
        return
    run(args)


if __name__ == "__main__":
    main()
