"""
Rolling-origin backtest of the v3 point models (temperature + rain, 1/3/6 h).

For each origin O (every 6 months, most recent last) the whole v3 recipe is repeated using only the past:
    train      t+6 <= O - 12 months - 7 days            fit (same LightGBM parameters as train_global_v3.py)
    es         O - 12 months <= t, t+6 <= O - 7 days    early stopping, isotonic rain calibration, thresholds
    evaluate   O <= t, t+6 < O + 6 months               scored once, never used for any choice
(the 12-month gap between train end and evaluation mirrors production, where train ends ~2 years before test).
Baselines on the same rows: persistence and per-cell climatology of the fold's train period (rain threshold
tuned on the fold's es window). Metrics pooled over cells with 95 % block-bootstrap CIs (7-day blocks).

Cost control (documented in the output): a fixed, representative subset of cells (stratified by region and
distance to the coast, + Tan Son Nhat and Con Dao) and at most --rounds boosting rounds (early stopping 50).

Output: backend/models/evaluation/backtest_rolling_v3.json and backtest_rolling_v3.csv (aggregates only).
Usage:  python scripts/backtest_rolling_v3.py [--cells 21] [--rounds 1500] [--threads 12]
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_global_v3 as T  # noqa: E402
from ai_model import HORIZONS  # noqa: E402

OUT = T.BACKEND / "models" / "evaluation"
ORIGINS = [pd.Timestamp(s) for s in ("2024-04-01", "2024-10-01", "2025-04-01", "2025-10-01", "2026-04-01")]
CONDAO = "om-8.6819-106.5892"


def log(msg: str) -> None:
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with open(OUT / "backtest_log.txt", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def representative_cells(static: dict, n: int) -> list:
    """Per region, cells evenly spaced in distance to the coast (share of n proportional to region size)."""
    chosen = {T.TSN_CELL, CONDAO} & set(static)
    regions = sorted({s["region"] for s in static.values()})
    for reg in regions:
        cs = sorted((c for c, s in static.items() if s["region"] == reg), key=lambda c: static[c]["dist_to_coast_km"])
        k = max(1, round(n * len(cs) / len(static)))
        chosen |= {cs[int(i)] for i in np.linspace(0, len(cs) - 1, k).round()}
    return sorted(chosen)


def window(d, start, end):
    """Rows with start <= t and t+6 <= end (None = open)."""
    k = np.ones(len(d), bool)
    if start is not None:
        k &= (d.timestamp >= start).values
    if end is not None:
        k &= ((d.timestamp + pd.Timedelta(hours=T.MAXH)) <= end).values
    return d[k & d[T.target_cols()].notna().all(axis=1).values]


def run_fold(data, origin, rounds):
    gap = pd.Timedelta(days=7)
    es_start = origin - pd.DateOffset(months=12)
    ev_end = origin + pd.DateOffset(months=6) - pd.Timedelta(hours=1)
    train = window(data, None, es_start - gap)
    es = window(data, es_start, origin - gap)
    ev = window(data, origin, ev_end)
    if ev.empty:
        return None
    log(f"fold {origin:%Y-%m-%d}: train={len(train):,} (..{es_start - gap:%Y-%m-%d}) es={len(es):,} eval={len(ev):,} "
        f"({ev.timestamp.min():%Y-%m-%d}..{ev.timestamp.max():%Y-%m-%d})")
    clim = T.climatology(train)
    clim_thr = T.climatology_thresholds(es, clim)
    models, iters = T.fit_models(train, es, f"bt {origin:%Y-%m}", rounds=rounds, es=50)
    del train
    pe = T.predict_raw(models, es)
    cal = {f"{h}h": T.fit_calibrators(pe[f"rain_{h}h"], es[f"rain_target_{h}h"].values)["isotonic"] for h in HORIZONS}
    policy = {"rain_calibration": cal}
    thr = T.tune_thresholds(pe, es, policy)
    pv = T.predict_raw(models, ev)
    frames = {h: T.score_frame(models, ev, clim, h, policy, preds=pv) for h in HORIZONS}
    ci = T.block_bootstrap_ci(frames, thr, clim_thr)
    cells_beat = T.evaluate(models, thr, ev, clim, clim_thr, policy=policy, preds=pv)
    per_cell = cells_beat.groupby("cell_id").apply(lambda g: all(T.horizon_beats(r) for r in g.itertuples()))
    return {"origin": str(origin.date()), "train_end_target": str(es_start - gap), "es_window": [str(es_start), str(origin - gap)],
            "eval_window": [str(ev.timestamp.min()), str(ev.timestamp.max())], "rows_eval": len(ev),
            "best_iterations": iters, "thresholds": thr, "climatology_thresholds": clim_thr,
            "cells_beating_baselines": int(per_cell.sum()), "cells": int(len(per_cell)), "metrics": ci}


def main():
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--cells", type=int, default=21)
    ap.add_argument("--rounds", type=int, default=1500)
    ap.add_argument("--threads", type=int, default=12)
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()
    OUT = args.out
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "backtest_log.txt").write_text("", encoding="utf-8")
    T.log = log
    T.REG_PARAMS["num_threads"] = T.CLF_PARAMS["num_threads"] = args.threads
    t0 = time.time()
    con = sqlite3.connect(f"file:{T.DB.as_posix()}?mode=ro", uri=True)
    static = T.cell_static(con)
    cells = representative_cells(static, args.cells)
    data = T.load_frames(con, static, False, cells)
    con.close()
    log(f"cells={len(cells)} rows={len(data):,} load={time.time() - t0:.0f}s")
    folds = []
    for o in ORIGINS:
        r = run_fold(data, o, args.rounds)
        if r is not None:
            folds.append(r)
            a = r["metrics"]["all"]
            log(f"  -> MAE {a['mae_model']['value']:.3f} (pers {a['mae_persistence']['value']:.3f}, clim "
                f"{a['mae_climatology']['value']:.3f}); F1 {a['f1_model']['value']:.3f} (pers {a['f1_persistence']['value']:.3f}, "
                f"clim {a['f1_climatology']['value']:.3f}); BSS {a['bss']['value']:.3f}")
    rows = []
    for r in folds:
        for h in [f"{h}h" for h in HORIZONS] + ["all"]:
            m = r["metrics"][h]
            rows.append({"origin": r["origin"], "eval_start": r["eval_window"][0][:10], "eval_end": r["eval_window"][1][:10],
                         "horizon": h, **{k: v["value"] for k, v in m.items()},
                         **{f"{k}_lo": v["ci95"][0] for k, v in m.items() if k in ("mae_model", "f1_model", "bss")},
                         **{f"{k}_hi": v["ci95"][1] for k, v in m.items() if k in ("mae_model", "f1_model", "bss")}})
    pd.DataFrame(rows).round(5).to_csv(OUT / "backtest_rolling_v3.csv", index=False)
    out = {"created_at": datetime.now().isoformat(timespec="seconds"), "design": __doc__.strip().split("\n\n")[1],
           "cost_control": {"cells": cells, "n_cells": len(cells), "of_cells": len(static),
                            "selection": "per region evenly spaced by distance to coast, + Tan Son Nhat and Con Dao",
                            "max_rounds": args.rounds, "early_stopping_rounds": 50,
                            "rain_calibration": "isotonic fitted on the fold's es window (no separate selection window)"},
           "folds": folds, "runtime_s": round(time.time() - t0)}
    (OUT / "backtest_rolling_v3.json").write_text(json.dumps(out, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    log(f"done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
