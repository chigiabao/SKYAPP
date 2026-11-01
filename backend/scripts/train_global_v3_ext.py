"""
v3 extension: uncertainty + new targets, trained on the SAME data snapshot and split as v3.

Run AFTER scripts/train_global_v3.py (it reads metadata_v3.json for the per-cell data snapshot,
the existing rain models, and merges new keys into evaluation_v3.json without touching old ones).
If train_global_v3.py is re-run, re-run this script too.

Split: the four windows of train_global_v3.py (train / val_es / val_select / test). Rows before
2021-01-01 are not used here (memory/time budget; the base v3 point models use all years).
Early stopping and the legacy conformal offset use val_es; the serving gate uses val_select.

1. Temperature interval: LightGBM quantile models p10 / p90 for 1/3/6 h. Served interval =
   [min(q10, point), max(q90, point)] widened/narrowed by a split-conformal offset fitted on val_es
   (CQR) - applied only if raw coverage is outside 80% +/- 3 pp. Coverage reported on test.
   (Superseded at serving time by train_global_v3_interval.py, which must run after this script.)
2. Rain probability calibration: done by train_global_v3.py (serving_policy_v3.json: fitted on val_es,
   method chosen on val_select). If that file exists this script fits no calibrator and reports the
   served (policy-applied) probabilities. Legacy path without it: isotonic fit on the first half of val_es,
   checked on the second half, applied (refit on all val_es) only if Brier improves >= 1 %.
3. New targets, 1/3/6 h: humidity, wind_speed, wind_gusts (L2 regression, metric MAE) and
   precipitation_mm (expected value, Tweedie objective; metric RMSE, because the mean is the
   RMSE-optimal forecast and MAE rewards always predicting 0 mm; MAE is reported too).
   Baselines: persistence (value at t) and per-cell climatology (train mean by target month x hour).

SERVING GATE ("verify before extending"): a cell counts as a win for a target when the model's
metric is lower than BOTH baselines at ALL three horizons on the val_select window. A target is
enabled in predict_for_location only if it wins in >= 80 % of the evaluated cells. Disabled
targets stay in evaluation_v3.json but are never served.

Usage:  python scripts/train_global_v3_ext.py [--out DIR]
        --out: v3 directory to read AND extend (default backend/models/v3), e.g. the retrain candidate
        written by `train_global_v3.py --out DIR`.
"""
from __future__ import annotations

import argparse
import json
import math
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path

import joblib
import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.isotonic import IsotonicRegression

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ai_model  # noqa: E402
import train_global_v3 as T  # noqa: E402
from ai_model import HORIZONS, build_features_v3, feature_columns_v3  # noqa: E402

import os  # noqa: E402

OUT = T.OUT                                            # inputs (v3 files)
OUTW = Path(os.environ.get("V3EXT_OUT", str(T.OUT)))   # outputs (override only for smoke runs)
SMOKE = int(os.environ.get("V3EXT_SMOKE_CELLS", "0"))  # >0: first N cells, 30 rounds (smoke run)
LOG = OUTW / "train_ext_log.txt"
GATE_SHARE = 0.80
COVERAGE_TARGET = 0.80
COVERAGE_TOL = 0.03
ISO_MIN_GAIN = 0.01
ISO_FIT_END = pd.Timestamp("2024-03-31 23:00")   # legacy calibration: first half of val_es
EXT_DATA_START = pd.Timestamp("2021-01-01 00:00")
NEW_TARGETS = {          # name -> (source column, objective, primary metric)
    "humidity": ("humidity", "regression", "mae"),
    "wind_speed": ("wind_speed", "regression", "mae"),
    "wind_gusts": ("wind_gusts", "regression", "mae"),
    "precipitation_mm": ("precipitation", "tweedie", "rmse"),
}
REG = dict(T.REG_PARAMS)
QPARAMS = {q: dict(REG, objective="quantile", alpha=a, metric="quantile") for q, a in (("p10", 0.1), ("p90", 0.9))}
TWEEDIE = dict(REG, objective="tweedie", tweedie_variance_power=1.5, metric="rmse")


def log(msg: str) -> None:
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def load(con, static, snapshot) -> pd.DataFrame:
    """Same features as v3, restricted to the per-cell snapshot v3 was trained on, plus new targets."""
    cols = feature_columns_v3()
    frames = []
    for cid in sorted(snapshot)[:SMOKE or None]:
        first, last, _ = snapshot[cid]
        df = pd.read_sql("SELECT * FROM hourly WHERE cell_id = ? AND timestamp >= ? AND timestamp <= ? "
                         "ORDER BY timestamp", con, params=(cid, str(EXT_DATA_START - pd.Timedelta(days=2)), last))
        df["timestamp"] = pd.to_datetime(df["timestamp"])
        df = df.drop_duplicates("timestamp").set_index("timestamp")
        df = df.reindex(pd.date_range(df.index.min(), df.index.max(), freq="h"))
        df = df.rename_axis("timestamp").reset_index().drop(columns=["cell_id"])
        f = build_features_v3(df, static[cid])[cols].astype(np.float32)
        g = pd.concat([df[["timestamp"]], f], axis=1)
        for h in HORIZONS:
            g[f"temp_target_{h}h"] = df.temperature.shift(-h).astype(np.float32)
            g[f"rain_target_{h}h"] = np.where(df.precipitation.shift(-h).isna(), np.nan,
                                              df.precipitation.shift(-h) > ai_model.RAIN_THRESHOLD_MM).astype(np.float32)
            for name, (src, _, _) in NEW_TARGETS.items():
                g[f"{name}_target_{h}h"] = df[src].shift(-h).astype(np.float32)
        g["cell_id"] = cid
        g = g[g.timestamp >= max(pd.Timestamp(first), EXT_DATA_START)].dropna(subset=cols)
        frames.append(g)
    return pd.concat(frames, ignore_index=True)


def tcols():
    return [f"{k}_target_{h}h" for h in HORIZONS for k in ["temp", "rain", *NEW_TARGETS]]


def train_all(train, val):
    cols = feature_columns_v3()
    tr = train.dropna(subset=tcols())
    va = val.dropna(subset=tcols())
    dtr = lgb.Dataset(tr[cols].values, tr["temp_target_1h"].values, free_raw_data=False,
                      params=dict(REG)).construct()
    Xva = va[cols].values
    models, iters = {}, {}
    jobs = [(f"temp_{q}_{h}h", QPARAMS[q], f"temp_target_{h}h") for h in HORIZONS for q in ("p10", "p90")]
    jobs += [(f"{n}_{h}h", TWEEDIE if obj == "tweedie" else REG, f"{n}_target_{h}h")
             for h in HORIZONS for n, (_, obj, _) in NEW_TARGETS.items()]
    for key, params, y in jobs:
        t0 = time.time()
        dtr.set_label(tr[y].values)
        dva = lgb.Dataset(Xva, va[y].values, reference=dtr)
        m = lgb.train(params, dtr, num_boost_round=30 if SMOKE else 3000, valid_sets=[dva],
                      callbacks=[lgb.early_stopping(100, verbose=False)])
        m = m if m.best_iteration in (0, m.current_iteration()) else T._truncate(m)
        models[key], iters[key] = m, int(m.current_iteration())
        log(f"{key}: iters={iters[key]} ({time.time() - t0:.0f}s)")
    return models, iters


def climatology(train):
    c = train[["cell_id", "timestamp", "temperature", "humidity", "wind_speed", "wind_gusts"]].copy()
    # precipitation (raw) is a feature column too
    c["precipitation_mm"] = train["precipitation"].values
    c["rain"] = (c.precipitation_mm > ai_model.RAIN_THRESHOLD_MM).astype(float)
    c["month"], c["hour"] = c.timestamp.dt.month, c.timestamp.dt.hour
    return c.drop(columns="timestamp").groupby(["cell_id", "month", "hour"]).mean()


def conformal_offset(lo, hi, y, level=COVERAGE_TARGET):
    s = np.maximum(lo - y, y - hi)
    n = len(s)
    return float(np.quantile(s, min(1.0, math.ceil((n + 1) * level) / n), method="higher"))


def ece(p, y, bins=10):
    idx = np.minimum((p * bins).astype(int), bins - 1)
    tot = 0.0
    for b in range(bins):
        m = idx == b
        if m.any():
            tot += m.sum() * abs(p[m].mean() - y[m].mean())
    return float(tot / len(p))


def reliability(p, y, bins=10):
    idx = np.minimum((p * bins).astype(int), bins - 1)
    out = []
    for b in range(bins):
        m = idx == b
        if m.any():
            out.append([round(float(p[m].mean()), 4), round(float(y[m].mean()), 4), int(m.sum())])
    return out


def select_new_targets(val, predictions, clim):
    """Freeze the serving gate from validation only, before inspecting final test."""
    cells = sorted(set(val.cell_id))
    gate = {}
    for name, (src, _, metric) in NEW_TARGETS.items():
        wins = []
        for h in HORIZONS:
            tt = val.timestamp + pd.Timedelta(hours=h)
            baseline = clim.reindex(pd.MultiIndex.from_arrays([val.cell_id, tt.dt.month, tt.dt.hour]))
            f = pd.DataFrame({"cell_id": val.cell_id.values, "y": val[f"{name}_target_{h}h"].values,
                              "m": predictions[f"{name}_{h}h"], "p": val[src].values,
                              "c": baseline[name].values}).replace([np.inf, -np.inf], np.nan).dropna()
            errors = f[["m", "p", "c"]].sub(f.y, axis=0)
            losses = errors.abs() if metric == "mae" else errors ** 2
            scores = losses.groupby(f.cell_id).mean()
            wins.append((scores.m < scores[["p", "c"]].min(axis=1)).reindex(cells, fill_value=False))
        per_cell = pd.concat(wins, axis=1).all(axis=1)
        share = float(per_cell.mean()) if cells else 0.0
        gate[name] = {"metric": metric, "selection_split": "validation", "cells_won": int(per_cell.sum()),
                      "cells": len(cells), "share": round(share, 4), "enabled": share >= GATE_SHARE,
                      "won": per_cell.to_dict()}
    return gate


def merge_evaluation(ev, metrics, enabled):
    """Add extension metrics while preserving the base rain metrics and their climatology."""
    for cid, e in ev.items():
        src = e.get("alias_of", cid)
        mm = metrics[metrics.cell_id == src]
        if mm.empty:
            continue
        for h in ("1h", "3h", "6h"):
            r = mm[mm.horizon == h].iloc[0]
            e[f"temperature_interval_coverage_{h}"] = round(r["cov"], 4)
            e[f"temperature_interval_coverage_raw_{h}"] = round(r.cov_raw, 4)
            e[f"temperature_interval_width_{h}"] = round(r.width, 3)
            e[f"rain_ece_{h}"] = round(r.ece_served, 4)
            for n, (_, _, metric) in NEW_TARGETS.items():
                for met in ("mae", "rmse") if n == "precipitation_mm" else ("mae",):
                    e[f"{n}_{met}_{h}"] = round(r[f"{n}_{met}_m"], 3)
                    e[f"baseline_persistence_{n}_{met}_{h}"] = round(r[f"{n}_{met}_p"], 3)
                    e[f"baseline_climatology_{n}_{met}_{h}"] = round(r[f"{n}_{met}_c"], 3)
        for n, (_, _, metric) in NEW_TARGETS.items():
            e[f"beats_baselines_{n}"] = bool((mm[f"{n}_{metric}_m"] <
                                             mm[[f"{n}_{metric}_p", f"{n}_{metric}_c"]].min(axis=1)).all())
        e["gate_selection_split"] = "validation"
        e["enabled_targets"] = enabled
        e["interval_nominal_coverage"] = COVERAGE_TARGET
    return ev


def main():
    global OUT, OUTW, LOG
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=None,
                    help="v3 directory to read and extend (default backend/models/v3)")
    args = ap.parse_args()
    if args.out is not None:
        OUT = OUTW = args.out
        LOG = OUTW / "train_ext_log.txt"
    OUTW.mkdir(parents=True, exist_ok=True)
    LOG.write_text("", encoding="utf-8")
    meta = json.loads((OUT / "metadata_v3.json").read_text(encoding="utf-8"))
    static = json.loads((OUT / "cell_static.json").read_text(encoding="utf-8"))
    con = sqlite3.connect(f"file:{T.DB.as_posix()}?mode=ro", uri=True)
    t0 = time.time()
    data = load(con, static, meta["data_snapshot"])
    con.close()
    log(f"rows={len(data):,} cells={data.cell_id.nunique()} load={time.time() - t0:.0f}s")
    train, val_es, val, test = T.split(data)        # val = val_select (gate); val_es = early stopping
    test_cells = [c for c in meta["test_cells"] + meta.get("late_cells_evaluated_on_test", []) if c in set(test.cell_id)]
    test = test[test.cell_id.isin(test_cells)]
    del data
    assert (train.timestamp + pd.Timedelta(hours=T.MAXH)).max() < T.VAL_ES_START
    assert (val_es.timestamp + pd.Timedelta(hours=T.MAXH)).max() < T.VAL_SEL_START
    assert (val.timestamp + pd.Timedelta(hours=T.MAXH)).max() < T.TEST_START
    log(f"train={len(train):,} val_es={len(val_es):,} val_select={len(val):,} test={len(test):,} "
        f"(v3 metadata: {meta['split']['rows']})")

    clim = climatology(train)
    models, iters = train_all(train, val_es)
    del train
    cols = feature_columns_v3()
    old = {k: joblib.load(OUT / f"{n}_model_{h}h.pkl") for h in HORIZONS
           for k, n in ((f"temp_{h}h", "temperature"), (f"rain_{h}h", "rain"))}

    def predict(d):
        X = d[cols].values
        return {k: m.predict(X) for k, m in {**old, **models}.items()}

    pv = predict(val)
    gate = select_new_targets(val, pv, clim)
    pv_es = predict(val_es)
    enabled = ["temperature", "rain_probability", "temperature_interval"] + [n for n in NEW_TARGETS if gate[n]["enabled"]]
    for n, g in gate.items():
        log(f"validation gate {n}: {g['cells_won']}/{g['cells']} -> {'ON' if g['enabled'] else 'OFF'}")

    policy = ai_model._load_policy(meta, OUT)

    def served_point(d, predictions, h):
        return ai_model.apply_policy(policy, h, d.cell_id.astype(str).values, predictions[f"temp_{h}h"],
                                      predictions[f"rain_{h}h"], d.temperature.values, d.precipitation.values)

    # ---- temperature interval (conformal decision on val_es only)
    conformal = {}
    for h in HORIZONS:
        ok = val_es[f"temp_target_{h}h"].notna().values
        y = val_es[f"temp_target_{h}h"].values[ok]
        lo, hi = ai_model.temperature_interval(pv_es[f"temp_p10_{h}h"][ok], pv_es[f"temp_p90_{h}h"][ok],
                                               served_point(val_es, pv_es, h)[0][ok], 0.0)
        raw_cov = float(((y >= lo) & (y <= hi)).mean())
        off = conformal_offset(lo, hi, y) if abs(raw_cov - COVERAGE_TARGET) > COVERAGE_TOL else 0.0
        conformal[f"{h}h"] = {"val_raw_coverage": round(raw_cov, 4), "offset": round(off, 4), "applied": off != 0.0}
        log(f"interval {h}h: val raw coverage={raw_cov:.3f} offset={off:.3f}")

    # ---- rain calibration: owned by train_global_v3.py when serving_policy_v3.json exists
    calib = {}
    for h in HORIZONS:
        if policy.get("rain_calibration"):
            calib[f"{h}h"] = {"applied": False, "base_policy_method": policy["rain_calibration"][f"{h}h"]["method"],
                              "note": f"calibrated by train_global_v3.py ({ai_model.POLICY_FILE})"}
            continue
        y = val_es[f"rain_target_{h}h"].values
        ok = ~np.isnan(y)
        p, y, ts = pv_es[f"rain_{h}h"][ok], y[ok], val_es.timestamp.values[ok]
        a, b = ts <= np.datetime64(ISO_FIT_END), ts > np.datetime64(ISO_FIT_END)
        iso = IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1).fit(p[a], y[a])
        br_raw, br_iso = float(((p[b] - y[b]) ** 2).mean()), float(((iso.predict(p[b]) - y[b]) ** 2).mean())
        apply = br_iso < br_raw * (1 - ISO_MIN_GAIN)
        calib[f"{h}h"] = {"val_check_brier_raw": round(br_raw, 5), "val_check_brier_isotonic": round(br_iso, 5),
                          "val_check_ece_raw": round(ece(p[b], y[b]), 4), "applied": bool(apply)}
        if apply:
            joblib.dump(IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1).fit(p, y),
                        OUTW / f"rain_calibrator_{h}h.pkl")
        log(f"rain calib {h}h: {calib[f'{h}h']}")
    calibrators = {h: joblib.load(OUTW / f"rain_calibrator_{h}h.pkl") for h in HORIZONS if calib[f"{h}h"]["applied"]}

    # ---- per-cell test metrics
    pt = predict(test)  # Reporting only: all serving decisions above are frozen.
    rows, rel = [], {}
    for h in HORIZONS:
        tt = test.timestamp + pd.Timedelta(hours=h)
        cl = clim.reindex(pd.MultiIndex.from_arrays([test.cell_id, tt.dt.month, tt.dt.hour]))
        temp, prob = served_point(test, pt, h)
        lo, hi = ai_model.temperature_interval(pt[f"temp_p10_{h}h"], pt[f"temp_p90_{h}h"], temp,
                                               conformal[f"{h}h"]["offset"])
        lo0, hi0 = ai_model.temperature_interval(pt[f"temp_p10_{h}h"], pt[f"temp_p90_{h}h"], temp, 0.0)
        praw = pt[f"rain_{h}h"]
        if policy.get("rain_calibration"):   # exactly what is served: calibration + per-cell fallback
            pcal = prob
        else:
            pcal = calibrators[h].predict(praw) if h in calibrators else praw
        f = pd.DataFrame({"cell_id": test.cell_id.values, "yt": test[f"temp_target_{h}h"].values,
                          "lo": lo, "hi": hi, "lo0": lo0, "hi0": hi0,
                          "yr": test[f"rain_target_{h}h"].values, "praw": praw, "pcal": pcal,
                          "pclim": cl.rain.values})
        for n, (src, _, _) in NEW_TARGETS.items():
            f[f"y_{n}"] = test[f"{n}_target_{h}h"].values
            f[f"m_{n}"] = pt[f"{n}_{h}h"]
            f[f"p_{n}"] = test[src].values
            f[f"c_{n}"] = cl[n].values
        f = f.dropna()
        rel[f"{h}h"] = {"raw": reliability(f.praw.values, f.yr.values), "served": reliability(f.pcal.values, f.yr.values)}
        for cid, g in f.groupby("cell_id"):
            r = {"cell_id": cid, "horizon": f"{h}h", "n": len(g),
                 "cov": float(((g.yt >= g.lo) & (g.yt <= g.hi)).mean()),
                 "cov_raw": float(((g.yt >= g.lo0) & (g.yt <= g.hi0)).mean()),
                 "width": float((g.hi - g.lo).mean()),
                 "brier_raw": float(((g.praw - g.yr) ** 2).mean()), "brier_served": float(((g.pcal - g.yr) ** 2).mean()),
                 "brier_clim": float(((g.pclim - g.yr) ** 2).mean()), "ece_served": ece(g.pcal.values, g.yr.values)}
            for n in NEW_TARGETS:
                for who in ("m", "p", "c"):
                    e = g[f"{who}_{n}"] - g[f"y_{n}"]
                    r[f"{n}_mae_{who}"] = float(e.abs().mean())
                    r[f"{n}_rmse_{who}"] = float(np.sqrt((e ** 2).mean()))
            rows.append(r)
    m = pd.DataFrame(rows)
    m.to_csv(OUTW / "per_cell_metrics_ext.csv", index=False)

    # ---- model files (all trained models saved; serving loads only enabled ones)
    for key, mdl in models.items():
        name, h = key.rsplit("_", 1)
        fname = {"temp_p10": "temperature_p10", "temp_p90": "temperature_p90"}.get(name, name)
        joblib.dump(mdl, OUTW / f"{fname}_model_{h}.pkl")

    # ---- merge into evaluation_v3.json (old keys untouched)
    ev = json.loads((OUT / "evaluation_v3.json").read_text(encoding="utf-8"))
    merge_evaluation(ev, m, enabled)
    (OUTW / "evaluation_v3.json").write_text(json.dumps(ev, ensure_ascii=False, indent=1), encoding="utf-8")

    agg = m.drop(columns="cell_id").groupby("horizon").mean().round(4)
    ext = {
        "model_version": meta["model_version"] + "+ext",
        "base_model_version": meta["model_version"],
        "trained_at": datetime.now().isoformat(timespec="seconds"),
        "data": "same per-cell snapshot and split as metadata_v3.json",
        "rows": {"val_es": len(val_es), "val_select": len(val), "test": len(test)},
        "data_start": str(EXT_DATA_START),
        "gate_selection_split": "validation",
        "gate_window": "val_select",
        "selection_cutoff": str((val.timestamp + pd.Timedelta(hours=T.MAXH)).max()),
        "serving_rule": f"A target is served only if, on the val_select window, the model beats BOTH persistence and "
                        f"climatology (primary metric) at ALL of 1/3/6 h in >= {GATE_SHARE:.0%} of the cells. "
                        f"Disabled targets are still evaluated in evaluation_v3.json but not returned.",
        "enabled_targets": enabled,
        "gate": {k: {kk: vv for kk, vv in v.items() if kk != "won"} for k, v in gate.items()},
        "interval": {"nominal": COVERAGE_TARGET, "method": "LightGBM quantile p10/p90, interval "
                     "[min(p10, point) - offset, max(p90, point) + offset]; offset = split-conformal (CQR) on val, "
                     f"applied only if raw val coverage is outside {COVERAGE_TARGET:.0%} +/- {COVERAGE_TOL:.0%}",
                     "conformal": conformal,
                     "test_mean_coverage": {h: float(agg.loc[h, "cov"]) for h in agg.index},
                     "test_mean_coverage_raw": {h: float(agg.loc[h, "cov_raw"]) for h in agg.index},
                     "test_cell_coverage_min_max": {h: [round(float(g["cov"].min()), 4), round(float(g["cov"].max()), 4)]
                                                    for h, g in m.groupby("horizon")}},
        "rain_calibration": {"method": (f"base model policy ({ai_model.POLICY_FILE}): fitted on val_es, chosen on "
                                        "val_select; no extension calibrator") if policy else
                             (f"isotonic, fit on val_es <= {ISO_FIT_END:%Y-%m-%d}, checked on the rest of val_es; "
                              f"applied (refit on all val_es) if Brier improves >= {ISO_MIN_GAIN:.0%}"), "per_horizon": calib,
                             "test_reliability_bins": rel},
        "precipitation_mm_method": "expected value (LightGBM Tweedie, variance power 1.5); primary metric RMSE",
        "test_mean_metrics": agg.to_dict(orient="index"),
        "best_iterations": iters,
        "params_quantile": QPARAMS, "params_tweedie": TWEEDIE, "params_regression": REG,
    }
    # serving parity samples
    samples = []
    rng = np.random.default_rng(T.SEED)
    for cid in [c for c in (T.TSN_CELL, "om-8.6819-106.5892") if c in test_cells]:
        rr = test[test.cell_id == cid]
        for i in rng.choice(len(rr), 4, replace=False):
            x = rr.iloc[[int(i)]][cols].values.astype(np.float32)
            samples.append({"cell_id": cid, "issued_at": str(rr.iloc[int(i)].timestamp),
                            **{k: {f"{h}h": float(models[f"{k}_{h}h"].predict(x)[0]) for h in HORIZONS}
                               for k in ["temp_p10", "temp_p90", *NEW_TARGETS]}})
    ext["serving_samples"] = samples
    (OUTW / "extension_v3.json").write_text(json.dumps(ext, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    log(f"enabled={enabled}")
    log(f"done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
