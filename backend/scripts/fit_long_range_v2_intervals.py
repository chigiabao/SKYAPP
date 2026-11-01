"""Fit 80 % p10/p90 (precipitation: one-sided p90) for the SERVED v2 long-range points.

Reuses the v2.1 interval machinery unchanged (long_range_model_v21.interval_bounds / interval_scale,
train_long_range_v21.fit_intervals / std_tables): per target x band split-conformal quantiles of
normalized residuals (method chosen as in v2.1), gated by purged 2-fold cross-fitted coverage
(|coverage - nominal| <= 0.03).

Residuals are y - v2 served value, where the served value comes from long_range_model_v2.forecast_arrays
on the same 48-row history predict() uses (short blend + V3 policy included). Calibration window:
VAL_CAL = issues >= 2024-10-14 with issue+168h <= 2024-12-24 23:00, every 7th complete issue per cell
(the v2.1 trainer's --val-stride). Std tables: train labels 2021-01-01..2024-06-30 with v2's own
climatology. Caveat: v2's early stopping / mode / policy selection used its whole validation window
(2024-07-08..2024-12-24), which contains VAL_CAL; VAL_CAL residuals may be slightly optimistic.

  --phase fit      VAL_CAL only -> <out>/intervals.json + metadata.json (never overwritten)
  --phase evaluate frozen artifact -> <out>/evaluation.json: coverage on the UNTOUCHED window (issues
                   from 2026-10-17, all horizons whose label exists in the DB) and a POST-HOC test-window
                   coverage (2025-01-01..2026-10-16, for information only; nothing is tuned on it).
The DB is opened read-only. No ledger writes, no point rescoring.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "scripts"))
import long_range_model_v2 as M  # noqa: E402
import long_range_model_v21 as S  # noqa: E402
import train_long_range_v2 as T2  # noqa: E402
import train_long_range_v21 as TR  # noqa: E402

TRAIN = (pd.Timestamp("2021-01-01"), pd.Timestamp("2024-06-30 23:00"))
VAL_CAL = TR.VAL_CAL
TEST = (TR.TEST_START, TR.TEST_END)
UNTOUCHED_START = pd.Timestamp("2026-10-17")
WARMUP = pd.Timedelta(hours=M.MIN_HISTORY_HOURS)
SCHEMA = 1


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_v2():
    path = M._directory()
    return path, M._load(str(path.resolve()), (path / "metadata.json").stat().st_mtime_ns)


def frames(db: Path, lo, hi):
    with TR.connect(db) as con:  # ?mode=ro + query_only
        last = pd.Timestamp(con.execute("SELECT MAX(timestamp) FROM hourly").fetchone()[0])
    hi = min(hi, last)
    f, static, _, info = TR.load_frames(db, lo, hi)
    return f, static, hi, info


def collect(fr: dict, meta, models, climate, policy, std, lo, hi, stride, require_full=True):
    """Grid of served v2 values and labels: one row per (cell, issue, horizon with a label <= hi)."""
    store, fallbacks, n_issues = {}, 0, 0
    for ci, cid in enumerate(sorted(fr)):
        if cid not in meta["cell_static"]:
            continue
        raw = fr[cid]
        ts = raw.timestamp
        y = T2.labels(raw)
        complete = raw[list(M.WEATHER_FEATURES)].notna().all(axis=1).rolling(M.MIN_HISTORY_HOURS).sum()
        ok = (ts >= lo) & complete.eq(M.MIN_HISTORY_HOURS)
        ok &= (ts + pd.Timedelta(hours=M.MAX_HORIZON) <= hi) if require_full else (ts < hi)
        issues = np.flatnonzero(ok.to_numpy())[::stride]
        for i in issues:
            hist = M._prepare(raw.iloc[i - M.MIN_HISTORY_HOURS + 1:i + 1], cid)
            values, fb = M.forecast_arrays(hist, cid, meta, models, climate, policy)
            fallbacks += bool(fb)
            n_issues += 1
            hmax = min(M.MAX_HORIZON, len(raw) - 1 - i)
            hs = np.arange(1, hmax + 1)
            valid = pd.DatetimeIndex(ts.iloc[i + hs].to_numpy())
            store.setdefault("h", []).append(hs)
            store.setdefault("cell", []).append(np.full(hmax, ci))
            store.setdefault("issue_time", []).append(np.full(hmax, TR.hours(ts.iloc[i])))
            store.setdefault("month", []).append(valid.month.to_numpy())
            for name in S.INTERVAL_TARGETS:
                store.setdefault(f"y_{name}", []).append(y[name][i + hs])
                store.setdefault(f"blend_{name}", []).append(values[name][:hmax])
                store.setdefault(f"std_{name}", []).append(M.clim_values(std[cid][name], valid))
        log(f"cell {ci + 1}/{len(fr)}: {len(issues)} issues")
    grid = {k: np.concatenate(v) for k, v in store.items()}
    return grid, {"issues": n_issues, "issues_with_policy_fallback": fallbacks}


def coverage_table(grid, rules, gated):
    out = {}
    seasons = S.season_of(grid["month"])
    for name in S.INTERVAL_TARGETS:
        rule = rules.get(name)
        y, v = grid[f"y_{name}"], grid[f"blend_{name}"]
        scale = np.ones(len(y)) if rule["method"] == "unnormalized" else grid[f"std_{name}"]
        lo, hi = S.interval_bounds(name, v, scale, grid["h"], seasons, rule, gated=gated)
        out[name] = {}
        for band, (a, b) in S.BANDS.items():
            m = (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(y) & np.isfinite(hi)
            if not m.any():
                out[name][band] = {"n": 0, "served": bool(rule["bands"][band]["served"])}
                continue
            cov = TR.coverage(name, y[m], lo[m], hi[m])
            days = len(np.unique(grid["issue_time"][m] // 24))
            out[name][band] = {"n": int(m.sum()), "issue_days": days, "served": bool(rule["bands"][band]["served"]),
                               "nominal": TR.NOMINAL[name], "coverage": round(cov, 4),
                               "mean_width": round(float(np.mean(hi[m] - (v[m] if name in S.UPPER_ONLY
                                                                          else lo[m]))), 4)}
    return out


def phase_fit(args):
    out = args.out
    if (out / "intervals.json").exists():
        raise SystemExit(f"{out} already holds an artifact; refusing to overwrite")
    path, (meta, models, climate, policy) = load_v2()
    log(f"v2 {meta['model_version']} ({path})")
    fr, _, _, info = frames(args.data, TRAIN[0], TRAIN[1])
    std = {}
    for cid, raw in fr.items():
        if cid in climate["cells"]:
            mask = TR.train_mask(raw.timestamp, *TRAIN)
            std[cid] = {k: [round(v, 5) for v in t] for k, t in
                        TR.std_tables(raw, climate["cells"][cid], mask).items()}
    del fr
    log("std tables ready")
    fr, _, _, info = frames(args.data, VAL_CAL[0] - WARMUP, VAL_CAL[1])
    grid, counts = collect(fr, meta, models, climate, policy, std, VAL_CAL[0], VAL_CAL[1], args.val_stride)
    log(f"VAL_CAL grid: {len(grid['h'])} rows, {counts}")
    rules, diag = TR.fit_intervals(grid, None)
    out.mkdir(parents=True, exist_ok=True)
    body = {"schema_version": SCHEMA, "v2_model_version": meta["model_version"], "level": S.INTERVAL_LEVEL,
            "bands": {b: list(r) for b, r in S.BANDS.items()}, "upper_only": list(S.UPPER_ONLY),
            "intervals": rules, "std": std}
    TR.write_json(out / "intervals.json", body, indent=None)
    gate = {n: {b: {"cv_coverage": e["cv_coverage"], "served": e["served"]} for b, e in r["bands"].items()}
            for n, r in rules.items()}
    metadata = {
        "schema_version": SCHEMA, "v2_model_version": meta["model_version"],
        "v2_artifact_sha256": {f: sha256_file(path / f) for f in ("metadata.json", "serving_policy.json",
                                                                  "climatology.json")},
        "intervals_sha256": sha256_file(out / "intervals.json"),
        "created_at": datetime.now(timezone.utc).isoformat(), "level": S.INTERVAL_LEVEL,
        "nominal": TR.NOMINAL,
        "method": "split-conformal quantiles of (y - v2 served value) / train anomaly std(month, hour) per "
                  "target x band (v2.1 rule: normalized unless unnormalized / Mondrian-by-season lowers the "
                  "cross-fitted |coverage error| by > 1pp); precipitation one-sided p90",
        "gate": f"purged 2-fold cross-fitted VAL_CAL coverage within +-{TR.INTERVAL_GATE} of nominal "
                "(contiguous halves, 168h purge); failed bands are not served",
        "val_cal": {"window": [str(VAL_CAL[0]), str(VAL_CAL[1])], "issue_rule": "issue and issue+168h inside",
                    "issue_stride_hours": args.val_stride, "rows": int(len(grid["h"])), **counts},
        "std_tables": {"labels": [str(TRAIN[0]), str(TRAIN[1])], "climatology": "v2 climatology.json",
                       "floor": TR.STD_FLOOR},
        "served_values": "long_range_model_v2.forecast_arrays on the 48-row prepared history (short blend + "
                         "V3 policy), exactly as predict()",
        "selection_overlap": "v2 used its validation window 2024-07-08..2024-12-24 (contains VAL_CAL) for "
                             "early stopping, target mode and policy weights; VAL_CAL residuals may be slightly "
                             "optimistic. Check untouched-window coverage before relying on it.",
        "gate_results": gate, "diagnostics": diag, "data": info,
        "code_sha256": {f: sha256_file(BACKEND / f) for f in ("scripts/fit_long_range_v2_intervals.py",
                                                              "long_range_model_v2.py", "long_range_model_v21.py")},
        "note": "An 80 % interval covering ~80 % of outcomes is a calibration statement, not 80 % accuracy.",
    }
    TR.write_json(out / "metadata.json", metadata)
    log(json.dumps(gate))


def phase_evaluate(args):
    out = args.out
    body = json.loads((out / "intervals.json").read_text(encoding="utf-8"))
    path, (meta, models, climate, policy) = load_v2()
    if body["v2_model_version"] != meta["model_version"]:
        raise SystemExit("interval artifact belongs to another v2 model")
    rules, std = body["intervals"], body["std"]
    report = {"artifact_sha256": sha256_file(out / "intervals.json"),
              "created_at": datetime.now(timezone.utc).isoformat()}
    fr, _, last, info = frames(args.data, UNTOUCHED_START - WARMUP, pd.Timestamp("2100-01-01"))
    grid, counts = collect(fr, meta, models, climate, policy, std, UNTOUCHED_START, last, args.untouched_stride,
                           require_full=False)
    report["untouched"] = {"issues": [str(UNTOUCHED_START), "labels through " + str(last)],
                           "issue_stride_hours": args.untouched_stride, **counts,
                           "note": "never used for any choice; issues >= 2026-10-17, horizons whose label exists",
                           "coverage": coverage_table(grid, rules, gated=False)}
    del fr, grid
    if args.test_stride:
        fr, _, _, _ = frames(args.data, TEST[0] - WARMUP, TEST[1])
        grid, counts = collect(fr, meta, models, climate, policy, std, TEST[0], TEST[1], args.test_stride)
        report["test_post_hoc"] = {"window": [str(TEST[0]), str(TEST[1])], "issue_stride_hours": args.test_stride,
                                   **counts, "note": "POST-HOC: computed after the artifact was frozen; no "
                                   "choice was tuned on it; not a ledger entry; points not rescored",
                                   "coverage": coverage_table(grid, rules, gated=False)}
    TR.write_json(out / "evaluation.json", report)
    log("evaluation written")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--phase", choices=("fit", "evaluate"), required=True)
    p.add_argument("--data", type=Path, default=BACKEND / "data/history/cells_history.db")
    p.add_argument("--out", type=Path, default=BACKEND / "models/long_range_v2_intervals")
    p.add_argument("--val-stride", type=int, default=7)
    p.add_argument("--untouched-stride", type=int, default=1)
    p.add_argument("--test-stride", type=int, default=71, help="post-hoc test stride (0 = skip)")
    args = p.parse_args()
    (phase_fit if args.phase == "fit" else phase_evaluate)(args)


if __name__ == "__main__":
    main()
