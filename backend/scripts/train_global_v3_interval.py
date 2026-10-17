"""
v3 temperature interval, 90 % level (replaces the p10/p90 interval of train_global_v3_ext.py).

Only the INTERVAL model is retrained; the v3 point models (temperature/rain, train <= 2024-06-30)
and every other extension model are untouched.

Data: every cell from 2021-01-01 (61 cells in 2021, 67 from 2022) to the v3 data snapshot end.
Splits (t = issue time, t+h = target time, h <= 6; 7-day gap between splits):
  quantile train : t+6 <= 2023-12-24 23:00   (early stopping: fit <= 2023-06-23, stop on 2023-07-01..12-24,
                                              then refit on the whole train window with the best iteration)
  calibration    : 2024-01-01 <= t, t+6 <= 2024-12-24 23:00   (12 months: dry + rainy season)
  test           : t >= 2025-01-01 (same window and cells as v3)
Method: LightGBM quantile models q05/q95 + conformalized quantile regression (CQR, alpha = 0.1)
with group-wise (Mondrian) offsets, absolute or normalized by the q95-q05 width.
Served interval = [min(lo, point), max(hi, point)]; the calibration never uses the point model
(it was trained on part of 2024), so the point only widens the interval.

Choice of grouping / scale / calibration level WITHOUT the test window: a backtest repeats the
whole pipeline one year earlier (quantile models trained on t+6 <= 2022-12-24, calibrated on 2023,
evaluated on 2024 without the point model). The narrowest (variant, level) with mean cell coverage
>= 90 % and every cell >= 85 % at 1/3/6 h in the backtest is used for serving.

Spatial holdout: quantile models + calibration without the 31 holdout cells of metadata_v3.json,
evaluated on the holdout cells' test window (only groupings that exist for unseen cells).

Usage: python scripts/train_global_v3_interval.py      (env V3INT_SMOKE_CELLS=N for a smoke run)
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path

import joblib
import lightgbm as lgb
import numpy as np
import pandas as pd

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ai_model  # noqa: E402
import train_global_v3 as T  # noqa: E402
from ai_model import HORIZONS, build_features_v3, feature_columns_v3  # noqa: E402

OUT = T.OUT
OUTW = Path(os.environ.get("V3INT_OUT", str(T.OUT)))
SMOKE = int(os.environ.get("V3INT_SMOKE_CELLS", "0"))
LOG = OUTW / "train_interval_log.txt"
LEVEL = 0.90
CELL_MIN = 0.85
LEVELS = (0.90, 0.91, 0.92, 0.93, 0.94)
MIN_GROUP = 300
DATA_START = pd.Timestamp("2021-01-01 00:00")
D = pd.Timestamp
W = {  # (start of t, end of t+6)
    "qtrain": (None, D("2023-12-24 23:00")),
    "es_fit": (None, D("2023-06-23 23:00")),
    "es": (D("2023-07-01 00:00"), D("2023-12-24 23:00")),
    "cal": (D("2024-01-01 00:00"), D("2024-12-24 23:00")),
    "test": (D("2025-01-01 00:00"), None),
    "bt_train": (None, D("2022-12-24 23:00")),
    "bt_cal": (D("2023-01-01 00:00"), D("2023-12-24 23:00")),
    "bt_test": (D("2024-01-01 00:00"), D("2024-12-24 23:00")),
}
QP = {q: dict(T.REG_PARAMS, objective="quantile", alpha=a, metric="quantile") for q, a in (("q05", 0.05), ("q95", 0.95))}
VARIANTS = ai_model.INTERVAL_GROUPINGS


def log(msg):
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def load(con, static, snapshot):
    cols = feature_columns_v3()
    X, M = [], []
    for cid in sorted(snapshot)[:SMOKE or None]:
        last = snapshot[cid][1]
        df = pd.read_sql("SELECT * FROM hourly WHERE cell_id = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
                         con, params=(cid, str(DATA_START - pd.Timedelta(days=2)), last))
        df["timestamp"] = pd.to_datetime(df["timestamp"])
        df = df.drop_duplicates("timestamp").set_index("timestamp")
        df = df.reindex(pd.date_range(df.index.min(), df.index.max(), freq="h"))
        df = df.rename_axis("timestamp").reset_index().drop(columns=["cell_id"])
        f = build_features_v3(df, static[cid])[cols].astype(np.float32)
        m = pd.DataFrame({"timestamp": df.timestamp, "cell_id": cid})
        rain_day = (df.set_index("timestamp").precipitation.resample("D").sum(min_count=1) >= 1.0)
        for h in HORIZONS:
            m[f"y{h}"] = df.temperature.shift(-h).astype(np.float32)
            tt = df.timestamp + pd.Timedelta(hours=h)
            m[f"rd{h}"] = tt.dt.normalize().map(rain_day).astype("float32").values
        ok = (m.timestamp >= DATA_START).values & f.notna().all(axis=1).values
        X.append(f.values[ok]); M.append(m[ok].reset_index(drop=True))
    return np.concatenate(X), pd.concat(M, ignore_index=True)


def mask(meta, w):
    a, b = W[w]
    k = np.ones(len(meta), bool)
    if a is not None:
        k &= (meta.timestamp >= a).values
    if b is not None:
        k &= ((meta.timestamp + pd.Timedelta(hours=max(HORIZONS))) <= b).values
    return k


def fit(X, y, params, rounds, Xv=None, yv=None):
    ok = ~np.isnan(y)
    dtr = lgb.Dataset(X[ok], y[ok], params=dict(params))
    if Xv is None:
        return lgb.train(params, dtr, num_boost_round=rounds)
    okv = ~np.isnan(yv)
    m = lgb.train(params, dtr, num_boost_round=rounds, valid_sets=[lgb.Dataset(Xv[okv], yv[okv], reference=dtr)],
                  callbacks=[lgb.early_stopping(100, verbose=False)])
    return m


def train_set(X, meta, k_train, iters, tag):
    models = {}
    for h in HORIZONS:
        for q in ("q05", "q95"):
            t0 = time.time()
            models[f"{q}_{h}h"] = fit(X[k_train], meta[f"y{h}"].values[k_train], QP[q], iters[f"{q}_{h}h"])
            log(f"[{tag}] {q}_{h}h iters={iters[f'{q}_{h}h']} ({time.time() - t0:.0f}s)")
    return models


def frame(models, X, meta, k, static):
    """Long frame (one row per sample x horizon) with quantiles, truth and group attributes."""
    out = []
    Xk, mk = X[k], meta[k].reset_index(drop=True)
    for h in HORIZONS:
        f = pd.DataFrame({"cell_id": mk.cell_id.values, "h": h, "y": mk[f"y{h}"].values,
                          "qlo": models[f"q05_{h}h"].predict(Xk), "qhi": models[f"q95_{h}h"].predict(Xk),
                          "rd": mk[f"rd{h}"].values})
        tt = mk.timestamp + pd.Timedelta(hours=h)
        f["month"], f["hour"] = tt.dt.month.values, tt.dt.hour.values
        f["t"] = mk.timestamp.values
        out.append(f[f.y.notna()])
    f = pd.concat(out, ignore_index=True)
    lo, hi = np.minimum(f.qlo, f.qhi), np.maximum(f.qlo, f.qhi)
    f["qlo"], f["qhi"] = lo, hi
    for v in VARIANTS:
        f[f"g_{v}"] = ai_model.interval_group_keys(v, f.h.values, f.cell_id.values, f.month.values, f.hour.values, static)
    return f


def scores(f, scale):
    s = np.maximum(f.qlo - f.y, f.y - f.qhi)
    return s / ai_model.interval_scale(f.qlo, f.qhi, scale)


def cq(s, level):
    n = len(s)
    return float(np.quantile(s, min(1.0, math.ceil((n + 1) * level) / n), method="higher"))


def calibrate(cal, variant, scale, level):
    """{group key: offset}; groups with < MIN_GROUP samples fall back to the horizon-wide offset."""
    s = scores(cal, scale)
    table = {f"{h}": cq(s[cal.h.values == h].values, level) for h in HORIZONS}
    if variant != "const":
        for g, sg in s.groupby(cal[f"g_{variant}"].values):
            if len(sg) >= MIN_GROUP:
                table[g] = cq(sg.values, level)
    return table


def apply(f, table, variant, scale, point=None):
    off = pd.Series(f[f"g_{variant}"].values).map(table)
    off = off.fillna(pd.Series(f.h.astype(str).values).map(table)).values
    lo, hi = ai_model.conformal_interval(f.qlo.values, f.qhi.values, off, scale,
                                         point if point is not None else None)
    return lo, hi


def summarize(f, lo, hi):
    c = (f.y.values >= lo) & (f.y.values <= hi)
    d = pd.DataFrame({"cell_id": f.cell_id.values, "h": f.h.values, "c": c, "w": hi - lo})
    pc = d.groupby(["h", "cell_id"]).agg(cov=("c", "mean"), width=("w", "mean"))
    by_h = pc.groupby("h").agg(cov_mean=("cov", "mean"), cov_min=("cov", "min"), width=("width", "mean"))
    return by_h, pc, c, hi - lo


def search(cal, test, allowed):
    rows = []
    for v in allowed:
        for scale in ("abs", "norm"):
            for L in LEVELS:
                lo, hi = apply(test, calibrate(cal, v, scale, L), v, scale)
                b, _, _, _ = summarize(test, lo, hi)
                ok = bool((b.cov_mean >= LEVEL).all() and (b.cov_min >= CELL_MIN).all())
                rows.append({"variant": v, "scale": scale, "level": L, "pass": ok, "width": float(b.width.mean()),
                             **{f"cov_mean_{h}h": round(float(b.cov_mean[h]), 4) for h in HORIZONS},
                             **{f"cov_min_{h}h": round(float(b.cov_min[h]), 4) for h in HORIZONS},
                             **{f"width_{h}h": round(float(b.width[h]), 3) for h in HORIZONS}})
    r = pd.DataFrame(rows)
    ok = r[r["pass"]]
    best = (ok if len(ok) else r.assign(_m=r[[f"cov_min_{h}h" for h in HORIZONS]].min(axis=1))
            .sort_values("_m", ascending=False)).sort_values("width").iloc[0]
    return r, best


def point_preds(X, meta, k):
    out = {}
    for h in HORIZONS:
        m = joblib.load(OUT / f"temperature_model_{h}h.pkl")
        p = m.predict(X[k])
        out[h] = p[meta[f"y{h}"].values[k] == meta[f"y{h}"].values[k]]  # same row filter as frame()
    return np.concatenate([out[h] for h in HORIZONS])


def main():
    global OUT, OUTW, LOG
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=None,
                    help="v3 directory to read and extend (default backend/models/v3)")
    args = ap.parse_args()
    if args.out is not None:
        OUT = OUTW = args.out
        LOG = OUTW / "train_interval_log.txt"
    OUTW.mkdir(parents=True, exist_ok=True)
    LOG.write_text("", encoding="utf-8")
    meta3 = json.loads((OUT / "metadata_v3.json").read_text(encoding="utf-8"))
    static = json.loads((OUT / "cell_static.json").read_text(encoding="utf-8"))
    hold = set(meta3["holdout_cells"])
    con = sqlite3.connect(f"file:{T.DB.as_posix()}?mode=ro", uri=True)
    t0 = time.time()
    X, meta = load(con, static, meta3["data_snapshot"])
    con.close()
    K = {w: mask(meta, w) for w in W}
    K["test"] &= meta.cell_id.isin(meta3["test_cells"]).values
    log(f"rows={len(meta):,} cells={meta.cell_id.nunique()} load={time.time() - t0:.0f}s "
        + " ".join(f"{w}={k.sum():,}" for w, k in K.items()))
    rounds = 30 if SMOKE else 3000

    # 1) early stopping -> iterations
    iters = {}
    for h in HORIZONS:
        y = meta[f"y{h}"].values
        for q in ("q05", "q95"):
            t1 = time.time()
            m = fit(X[K["es_fit"]], y[K["es_fit"]], QP[q], rounds, X[K["es"]], y[K["es"]])
            iters[f"{q}_{h}h"] = max(1, int(m.best_iteration or m.current_iteration()))
            log(f"[es] {q}_{h}h best_iter={iters[f'{q}_{h}h']} ({time.time() - t1:.0f}s)")

    # 2) backtest one year earlier -> choose variant / scale / level (no test data involved)
    bt = train_set(X, meta, K["bt_train"], iters, "backtest")
    f_btc, f_btt = frame(bt, X, meta, K["bt_cal"], static), frame(bt, X, meta, K["bt_test"], static)
    del bt
    grid, best = search(f_btc, f_btt, list(VARIANTS))
    grid_h, best_h = search(f_btc[~f_btc.cell_id.isin(hold)], f_btt[f_btt.cell_id.isin(hold)],
                            [v for v in VARIANTS if not VARIANTS[v].get("needs_cell")])
    del f_btc, f_btt
    log(f"backtest choice: {best.variant}/{best.scale}/L={best.level} width={best.width:.3f} pass={best['pass']}")
    log(f"backtest holdout choice: {best_h.variant}/{best_h.scale}/L={best_h.level} pass={best_h['pass']}")
    grid.to_csv(OUTW / "interval_backtest_grid.csv", index=False)

    # 3) final quantile models + calibration on 2024, evaluated on test
    models = train_set(X, meta, K["qtrain"], iters, "final")
    f_cal, f_test = frame(models, X, meta, K["cal"], static), frame(models, X, meta, K["test"], static)
    pt = point_preds(X, meta, K["test"])
    v, sc, L = best.variant, best.scale, float(best.level)
    table = calibrate(f_cal, v, sc, L)
    lo, hi = apply(f_test, table, v, sc, point=pt)
    b, pc, c, w = summarize(f_test, lo, hi)
    log("TEST served:\n" + b.round(4).to_string())
    lo_np, hi_np = apply(f_test, table, v, sc)
    b_np, _, _, _ = summarize(f_test, lo_np, hi_np)

    # old interval (p10/p90 + val offset) on the same test rows, for comparison
    ext = json.loads((OUT / "extension_v3.json").read_text(encoding="utf-8"))
    old_int = ext.get("interval_previous_p10_p90", ext["interval"])
    olo, ohi = [], []
    mk = K["test"]
    for h in HORIZONS:
        ok = ~np.isnan(meta[f"y{h}"].values[mk])
        Xh = X[mk][ok]
        a, bb = ai_model.temperature_interval(joblib.load(OUT / f"temperature_p10_model_{h}h.pkl").predict(Xh),
                                              joblib.load(OUT / f"temperature_p90_model_{h}h.pkl").predict(Xh),
                                              joblib.load(OUT / f"temperature_model_{h}h.pkl").predict(Xh),
                                              old_int["conformal"][f"{h}h"]["offset"])
        olo.append(a); ohi.append(bb)
    b_old, pc_old, c_old, _ = summarize(f_test, np.concatenate(olo), np.concatenate(ohi))
    log("TEST old p10-p90:\n" + b_old.round(4).to_string())

    # 4) spatial holdout
    kh_tr, kh_cal = K["qtrain"] & ~meta.cell_id.isin(hold).values, K["cal"] & ~meta.cell_id.isin(hold).values
    kh_te = K["test"] & meta.cell_id.isin(hold).values
    mh = train_set(X, meta, kh_tr, iters, "holdout")
    fh_cal, fh_te = frame(mh, X, meta, kh_cal, static), frame(mh, X, meta, kh_te, static)
    pth = point_preds(X, meta, kh_te)
    vh, sch, Lh = best_h.variant, best_h.scale, float(best_h.level)
    loh, hih = apply(fh_te, calibrate(fh_cal, vh, sch, Lh), vh, sch, point=pth)
    b_h, pc_h, _, _ = summarize(fh_te, loh, hih)
    log("HOLDOUT:\n" + b_h.round(4).to_string())
    del mh

    # 5) save models + aggregated diagnostics (no raw records)
    for k, mdl in models.items():
        q, h = k.split("_")
        joblib.dump(mdl, OUTW / f"temperature_{q}_model_{h}.pkl")
    diag = []
    d = pd.DataFrame({"h": f_test.h.values, "cell_id": f_test.cell_id.values, "month": f_test.month.values,
                      "hblock": f_test.hour.values // 6, "rain_day": f_test.rd.values, "c": c, "w": w,
                      "c_old": c_old, "w_old": np.concatenate(ohi) - np.concatenate(olo)})
    for by in ("cell_id", "month", "hblock", "rain_day"):
        a = d.groupby(["h", by]).agg(cov=("c", "mean"), width=("w", "mean"), cov_old=("c_old", "mean"),
                                     width_old=("w_old", "mean"), n=("c", "size")).reset_index()
        diag.append(a.rename(columns={by: "value"}).assign(by=by, value=lambda x: x["value"].astype(str)))
    a = pc_h.reset_index().rename(columns={"cell_id": "value"}).assign(by="holdout_cell")
    diag.append(a)
    pd.concat(diag, ignore_index=True).to_csv(OUTW / "interval_test_diagnostics.csv", index=False)

    def hdict(bb):
        return {f"{h}h": {"cov_mean": round(float(bb.cov_mean[h]), 4), "cov_min_cell": round(float(bb.cov_min[h]), 4),
                          "width": round(float(bb.width[h]), 3)} for h in HORIZONS}
    period = f"{f_test.t.min():%Y-%m-%d}..{f_test.t.max():%Y-%m-%d}"
    interval = {
        "version": 2, "nominal": LEVEL, "quantiles": [0.05, 0.95],
        "models": "temperature_q05_model_{h}h.pkl / temperature_q95_model_{h}h.pkl",
        "method": "LightGBM quantile q05/q95 + Mondrian CQR (alpha=0.1); interval [qlo - off*s, qhi + off*s] "
                  "then widened to contain the point forecast; s = 1 (abs) or max(qhi-qlo, MIN) (norm)",
        "grouping": v, "scale": sc, "calibration_level": L, "offsets": {k: round(x, 4) for k, x in table.items()},
        "min_group": MIN_GROUP, "split": {k: [str(a) if a is not None else None, str(bb) if bb is not None else None]
                                          for k, (a, bb) in W.items()},
        "data_start": str(DATA_START), "best_iterations": iters, "params": QP,
        "selection": "narrowest (grouping, scale, level) with mean cell coverage >= 0.90 and every cell >= 0.85 "
                     "at 1/3/6 h in a backtest one year earlier (train <= 2022, calibrate 2023, check 2024, "
                     "no point model); the test window was not used for any choice",
        "backtest_choice": best.to_dict(), "backtest_holdout_choice": best_h.to_dict(),
        "test_period": period,
        "test": hdict(b), "test_without_point": hdict(b_np), "test_previous_p10_p90": hdict(b_old),
        "holdout": {"grouping": vh, "scale": sch, "calibration_level": Lh, "cells": len(hold), **hdict(b_h)},
    }
    if "interval_previous_p10_p90" not in ext:
        ext["interval_previous_p10_p90"] = ext["interval"]
    ext["interval"] = interval
    (OUTW / "extension_v3.json").write_text(json.dumps(ext, ensure_ascii=False, indent=1, default=str), encoding="utf-8")

    ev = json.loads((OUT / "evaluation_v3.json").read_text(encoding="utf-8"))
    pcd, pco = pc.reset_index(), pc_old.reset_index()
    for cid, e in ev.items():
        src = e.get("alias_of", cid)
        for h in HORIZONS:
            r, ro = pcd[(pcd.cell_id == src) & (pcd.h == h)], pco[(pco.cell_id == src) & (pco.h == h)]
            if r.empty:
                continue
            if f"temperature_interval_coverage_p10_p90_{h}h" not in e and f"temperature_interval_coverage_{h}h" in e:
                e[f"temperature_interval_coverage_p10_p90_{h}h"] = e[f"temperature_interval_coverage_{h}h"]
                e[f"temperature_interval_width_p10_p90_{h}h"] = e[f"temperature_interval_width_{h}h"]
            e[f"temperature_interval_coverage_{h}h"] = round(float(r["cov"].iloc[0]), 4)
            e[f"temperature_interval_width_{h}h"] = round(float(r["width"].iloc[0]), 3)
        if src in set(pcd.cell_id):
            e["interval_nominal_coverage"] = LEVEL
            e["interval_test_period"] = period
    (OUTW / "evaluation_v3.json").write_text(json.dumps(ev, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
