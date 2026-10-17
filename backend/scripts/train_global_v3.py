"""
Train the global LightGBM v3 model (all Open-Meteo cells of new HCMC) and evaluate it.

Data:   backend/data/history/cells_history.db (table hourly, read-only; the backfill may still be
        writing to it - every run snapshots whatever is there and records per-cell coverage).
Output: backend/models/v3/  (v2 files in backend/models/ are never touched)
        temperature_model_{1,3,6}h.pkl, rain_model_{1,3,6}h.pkl, feature_columns.json,
        cell_static.json, metadata_v3.json, evaluation_v3.json, per_cell_metrics.csv,
        serving_samples.json (for the train/serve parity check in notebooks/global_model.ipynb)

Split (chronological, by issue time t; a row is in a split only if t and t+6h are inside it):
        train  .. 2024-06-30 23:00
        purge  7 days
        val    2024-07-08 00:00 .. 2024-12-24 23:00   (early stopping + rain thresholds)
        purge  7 days
        test   2025-01-01 00:00 ..                    (cells with data in 2025+)
Cells that have no data >= test start yet are left out of val and are evaluated on the val
window instead (their 2024-H2 rows are not used for any fitting/tuning; flagged in the output).
Re-run when the backfill brings more data: the split dates stay fixed, coverage grows.

Spatial holdout: a second model is trained WITHOUT the cells of former Ba Ria-Vung Tau (incl.
Con Dao) and the ring of cells around Thu Dau Mot, then evaluated on those cells.

Usage:  python scripts/train_global_v3.py [--quick]
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

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
import ai_model  # noqa: E402
from ai_model import HORIZONS, STATIC_FEATURES, build_features_v3, build_targets, feature_columns_v3  # noqa: E402

DB = BACKEND / "data" / "history" / "cells_history.db"
LOC_DIR = BACKEND / "data" / "locations"
OUT = BACKEND / "models" / "v3"
TSN_CELL = ai_model.CELL_ALIASES["tsn"]
SEED = 42
MAXH = max(HORIZONS)

TRAIN_END = pd.Timestamp("2024-06-30 23:00")
VAL_START = pd.Timestamp("2024-07-08 00:00")
VAL_END = pd.Timestamp("2024-12-24 23:00")
TEST_START = pd.Timestamp("2025-01-01 00:00")
MIN_TEST_HOURS = 24 * 30        # a cell needs >= 30 days of test rows to be evaluated on the test window

REGION_KEYS = {"TP.HCM cũ": "region_hcm", "Bình Dương cũ": "region_bd", "Bà Rịa–Vũng Tàu cũ": "region_brvt"}
REG_PARAMS = dict(objective="regression", metric="mae", learning_rate=0.05, num_leaves=63,
                  feature_fraction=0.8, bagging_fraction=0.8, bagging_freq=5, min_data_in_leaf=100,
                  seed=SEED, deterministic=True, verbose=-1, num_threads=12)
CLF_PARAMS = dict(REG_PARAMS, objective="binary", metric="binary_logloss")

# Approximate sea coastline (lat, lon), hand-digitised from general maps because
# data/history/coastline_raw is empty. Mainland: Can Gio -> Vung Tau -> Long Hai -> Ho Tram -> Binh Chau;
# Con Dao: a ring around the main island. Accuracy ~ a few km; distance = haversine to the nearest
# point of the densified polyline (cells over water get small values, never negative).
COAST_MAINLAND = [(10.27, 106.73), (10.36, 106.80), (10.39, 106.88), (10.41, 106.97), (10.43, 107.01),
                  (10.40, 107.05), (10.345, 107.07), (10.32, 107.08), (10.34, 107.10), (10.37, 107.14),
                  (10.38, 107.23), (10.40, 107.27), (10.43, 107.34), (10.48, 107.43), (10.50, 107.47),
                  (10.54, 107.55), (10.58, 107.60)]
COAST_CONDAO = [(8.72, 106.58), (8.66, 106.56), (8.65, 106.63), (8.70, 106.66), (8.75, 106.62), (8.72, 106.58)]


def log(msg: str) -> None:
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with open(OUT / "train_log.txt", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def _densify(poly, step_km=0.5):
    pts = []
    for (a, b), (c, d) in zip(poly[:-1], poly[1:]):
        n = max(2, int(_hav(a, b, c, d) / step_km))
        pts += [(a + (c - a) * i / n, b + (d - b) * i / n) for i in range(n)]
    return pts + [poly[-1]]


def _hav(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(a))


def dist_to_coast_km(lat, lon):
    pts = _densify(COAST_MAINLAND) + _densify(COAST_CONDAO)
    return min(_hav(lat, lon, a, b) for a, b in pts)


def cell_static(con) -> dict:
    """lat/lon/elevation from the DB cells table (what the data was requested with) + coast + region."""
    locs = {e["id"]: e for e in json.loads((LOC_DIR / "locations.json").read_text(encoding="utf-8"))}
    cells_json = {c["cell_id"]: c for c in json.loads((LOC_DIR / "cells.json").read_text(encoding="utf-8"))}
    out = {}
    for cid, lat, lon, elev in con.execute("SELECT cell_id, lat, lon, elevation FROM cells"):
        regions = [locs[i]["region"] for i in cells_json[cid]["location_ids"] if i in locs]
        region = max(set(regions), key=regions.count)          # majority region of the cell's wards
        s = {"lat": lat, "lon": lon, "elevation": elev, "dist_to_coast_km": round(dist_to_coast_km(lat, lon), 2)}
        s.update({v: float(region == k) for k, v in REGION_KEYS.items()})
        s["region"] = region
        out[cid] = s
    return out


def holdout_cells(static: dict) -> list:
    """BR-VT cells + Thu Dau Mot's cell and its ring of neighbours (<= 1.5 grid steps)."""
    locs = {e["id"]: e for e in json.loads((LOC_DIR / "locations.json").read_text(encoding="utf-8"))}
    tdm = static[locs["phuong-thu-dau-mot"]["cell_id"]]
    ring = [c for c, s in static.items()
            if max(abs(s["lat"] - tdm["lat"]) / 0.0703, abs(s["lon"] - tdm["lon"]) / 0.0797) <= 1.5]
    brvt = [c for c, s in static.items() if s["region_brvt"] == 1.0]
    return sorted(set(ring) | set(brvt))


def load_frames(con, static: dict, quick: bool) -> pd.DataFrame:
    frames = []
    cols = feature_columns_v3()
    for cid in sorted(static):
        df = pd.read_sql("SELECT * FROM hourly WHERE cell_id = ? ORDER BY timestamp", con, params=(cid,))
        if df.empty:
            continue
        df["timestamp"] = pd.to_datetime(df["timestamp"])
        df = df.drop_duplicates("timestamp").set_index("timestamp")
        df = df.reindex(pd.date_range(df.index.min(), df.index.max(), freq="h"))   # gaps -> NaN rows
        df = df.rename_axis("timestamp").reset_index().drop(columns=["cell_id"])
        if quick:
            df = df[df.timestamp >= "2023-01-01"].reset_index(drop=True)
        f = build_features_v3(df, static[cid])[cols].astype(np.float32)
        t = build_targets(df)
        g = pd.concat([df[["timestamp", "temperature", "precipitation"]], f.drop(columns=["temperature", "precipitation"]),
                       t], axis=1)
        g["cell_id"] = cid
        g = g.dropna(subset=cols)
        frames.append(g)
    return pd.concat(frames, ignore_index=True)


def split(d: pd.DataFrame):
    tgt = d.timestamp + pd.Timedelta(hours=MAXH)
    train = d[tgt <= TRAIN_END]
    val = d[(d.timestamp >= VAL_START) & (tgt <= VAL_END)]
    test = d[d.timestamp >= TEST_START]
    return train, val, test


def tune_threshold(y, p):
    best = (0.5, -1.0)
    for thr in np.round(np.arange(0.05, 0.951, 0.01), 2):
        f = f1(y, p >= thr)
        if f > best[1]:
            best = (float(thr), f)
    return best[0]


def f1(y, yhat):
    y, yhat = np.asarray(y).astype(bool), np.asarray(yhat).astype(bool)
    tp = (y & yhat).sum()
    denom = 2 * tp + (y & ~yhat).sum() + (~y & yhat).sum()
    return float(2 * tp / denom) if denom else 0.0


def fit_models(train, val, tag):
    cols = feature_columns_v3()
    models, thr, iters = {}, {}, {}
    Xtr, Xva = train[cols].values, val[cols].values
    for h in HORIZONS:
        for kind, params, y in (("temp", REG_PARAMS, f"temp_target_{h}h"), ("rain", CLF_PARAMS, f"rain_target_{h}h")):
            t0 = time.time()
            dtr = lgb.Dataset(Xtr, train[y].values, free_raw_data=False)
            dva = lgb.Dataset(Xva, val[y].values, reference=dtr)
            m = lgb.train(params, dtr, num_boost_round=3000, valid_sets=[dva],
                          callbacks=[lgb.early_stopping(100, verbose=False)])
            m = m if m.best_iteration in (0, m.current_iteration()) else _truncate(m)
            models[f"{kind}_{h}h"] = m
            iters[f"{kind}_{h}h"] = int(m.current_iteration())
            if kind == "rain":
                thr[f"{h}h"] = tune_threshold(val[y].values, m.predict(Xva))
            log(f"{tag} {kind} {h}h: iters={iters[f'{kind}_{h}h']} ({time.time() - t0:.0f}s)")
    return models, thr, iters


def _truncate(m):
    """Keep only the best iteration so the saved model predicts exactly what was evaluated."""
    return lgb.Booster(model_str=m.model_to_string(num_iteration=m.best_iteration))


def climatology(train):
    """Per cell: train-period mean temperature and rain frequency by (month, hour) of the TARGET time."""
    c = train[["cell_id", "timestamp", "temperature", "precipitation"]].copy()
    c["month"], c["hour"] = c.timestamp.dt.month, c.timestamp.dt.hour
    c["rain"] = (c.precipitation > ai_model.RAIN_THRESHOLD_MM).astype(float)
    return c.groupby(["cell_id", "month", "hour"])[["temperature", "rain"]].mean()


def evaluate(models, thr, data, clim):
    """Per-cell metrics of the model and both baselines on `data` (rows of one or more cells)."""
    cols = feature_columns_v3()
    X = data[cols].values
    rows = []
    preds = {k: m.predict(X) for k, m in models.items()}
    for h in HORIZONS:
        tt = data.timestamp + pd.Timedelta(hours=h)
        key = pd.MultiIndex.from_arrays([data.cell_id, tt.dt.month, tt.dt.hour])
        cl = clim.reindex(key)
        frame = pd.DataFrame({
            "cell_id": data.cell_id.values, "y_t": data[f"temp_target_{h}h"].values,
            "y_r": data[f"rain_target_{h}h"].values,
            "m_t": preds[f"temp_{h}h"], "m_p": preds[f"rain_{h}h"],
            "p_t": data.temperature.values, "p_r": (data.precipitation.values > ai_model.RAIN_THRESHOLD_MM),
            "c_t": cl.temperature.values, "c_r": cl.rain.values > 0.5})
        frame = frame.dropna(subset=["y_t", "y_r", "c_t"])
        for cid, g in frame.groupby("cell_id"):
            y = g.y_r.values.astype(bool)
            rows.append({"cell_id": cid, "horizon": f"{h}h", "n": len(g), "rain_rate": float(y.mean()),
                         "mae_v3": float(np.abs(g.y_t - g.m_t).mean()),
                         "mae_persistence": float(np.abs(g.y_t - g.p_t).mean()),
                         "mae_climatology": float(np.abs(g.y_t - g.c_t).mean()),
                         "f1_v3": f1(y, g.m_p.values >= thr[f"{h}h"]),
                         "f1_persistence": f1(y, g.p_r.values), "f1_climatology": f1(y, g.c_r.values),
                         "brier_v3": float(((g.m_p - y) ** 2).mean())})
    return pd.DataFrame(rows)


def entry(cid, m: pd.DataFrame, period, holdout, kind):
    e = {"cell_id": cid}
    beats = True
    for h in ("1h", "3h", "6h"):
        r = m[m.horizon == h].iloc[0]
        e[f"temperature_mae_{h}"] = round(r.mae_v3, 3)
        e[f"rain_f1_{h}"] = round(r.f1_v3, 3)
        e[f"baseline_persistence_mae_{h}"] = round(r.mae_persistence, 3)
        e[f"baseline_climatology_mae_{h}"] = round(r.mae_climatology, 3)
        e[f"baseline_persistence_f1_{h}"] = round(r.f1_persistence, 3)
        e[f"baseline_climatology_f1_{h}"] = round(r.f1_climatology, 3)
        beats &= bool(r.mae_v3 < min(r.mae_persistence, r.mae_climatology))
        beats &= bool(r.f1_v3 > max(r.f1_persistence, r.f1_climatology))
    e.update(beats_baselines=bool(beats), test_period=period, holdout=bool(holdout),
             test_kind=kind, n_test_hours=int(m.n.min()))
    return e


def main():
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="drop pre-2023 rows (faster smoke run)")
    ap.add_argument("--out", type=Path, default=OUT, help="output directory (default backend/models/v3)")
    args = ap.parse_args()
    OUT = args.out
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "train_log.txt").write_text("", encoding="utf-8")
    con = sqlite3.connect(f"file:{DB.as_posix()}?mode=ro", uri=True)
    static = cell_static(con)
    hold = holdout_cells(static)
    t0 = time.time()
    data = load_frames(con, static, args.quick)
    con.close()
    log(f"rows={len(data):,} cells={data.cell_id.nunique()} holdout={len(hold)} load={time.time() - t0:.0f}s")

    train, val_all, test_all = split(data)
    n_test = test_all.groupby("cell_id").size()
    test_cells = sorted(n_test[n_test >= MIN_TEST_HOURS].index)
    late_cells = sorted(set(data.cell_id) - set(test_cells))          # no 2025+ data yet
    val = val_all[val_all.cell_id.isin(test_cells)]                   # tuning never sees late cells
    test = test_all[test_all.cell_id.isin(test_cells)]
    late_eval = val_all[val_all.cell_id.isin(late_cells)]
    log(f"train={len(train):,} val={len(val):,} test={len(test):,} test_cells={len(test_cells)} late={len(late_cells)}")

    # leakage / split checks
    assert (train.timestamp + pd.Timedelta(hours=MAXH)).max() < VAL_START
    assert (val.timestamp + pd.Timedelta(hours=MAXH)).max() < TEST_START
    assert not any("target" in c for c in feature_columns_v3())

    clim = climatology(train)
    # ---- full model (served)
    models, thr, iters = fit_models(train, val, "full")
    for h in HORIZONS:
        joblib.dump(models[f"temp_{h}h"], OUT / f"temperature_model_{h}h.pkl")
        joblib.dump(models[f"rain_{h}h"], OUT / f"rain_model_{h}h.pkl")
    m_test = evaluate(models, thr, test, clim).assign(model="full", split="test")
    m_late = evaluate(models, thr, late_eval, clim).assign(model="full", split="val_window_untuned")

    # ---- spatial holdout model
    tr_h, va_h = train[~train.cell_id.isin(hold)], val[~val.cell_id.isin(hold)]
    models_h, thr_h, iters_h = fit_models(tr_h, va_h, "holdout")
    hold_data = pd.concat([test[test.cell_id.isin(hold)], late_eval[late_eval.cell_id.isin(hold)]])
    m_hold = evaluate(models_h, thr_h, hold_data, clim).assign(model="holdout")
    m_hold["split"] = np.where(m_hold.cell_id.isin(test_cells), "test", "val_window_untuned")

    # ---- v2 at tsn on the same rows
    v2 = {k: joblib.load(BACKEND / "models" / f"{n}_model_{h}h.pkl")
          for h in HORIZONS for k, n in ((f"temp_{h}h", "temperature"), (f"rain_{h}h", "rain"))}
    v2_meta = json.loads((BACKEND / "models" / "model_metadata.json").read_text(encoding="utf-8"))
    tsn_rows = test[test.cell_id == TSN_CELL]
    Xv2 = tsn_rows[ai_model.feature_columns()].values
    v2_cmp = []
    for h in HORIZONS:
        ok = tsn_rows[f"temp_target_{h}h"].notna().values
        y_t, y_r = tsn_rows[f"temp_target_{h}h"].values[ok], tsn_rows[f"rain_target_{h}h"].values[ok]
        Xv3 = tsn_rows[feature_columns_v3()].values[ok]
        for name, mt, mr, th in (("v2", v2[f"temp_{h}h"], v2[f"rain_{h}h"], v2_meta["rain_decision_threshold"][f"{h}h"]),
                                 ("v3", models[f"temp_{h}h"], models[f"rain_{h}h"], thr[f"{h}h"])):
            X = Xv2[ok] if name == "v2" else Xv3
            v2_cmp.append({"horizon": f"{h}h", "model": name, "n": int(ok.sum()),
                           "mae": float(np.abs(y_t - mt.predict(X)).mean()),
                           "f1": f1(y_r.astype(bool), mr.predict(X) >= th)})

    # ---- outputs
    metrics = pd.concat([m_test, m_late, m_hold], ignore_index=True)
    metrics["holdout_cell"] = metrics.cell_id.isin(hold)
    metrics.to_csv(OUT / "per_cell_metrics.csv", index=False)
    test_end = test.timestamp.max() if len(test) else TEST_START
    periods = {c: f"{TEST_START:%Y-%m-%d}..{test[test.cell_id == c].timestamp.max():%Y-%m-%d}" for c in test_cells}
    periods.update({c: f"{VAL_START:%Y-%m-%d}..{VAL_END:%Y-%m-%d}" for c in late_cells})
    ev = {}
    for cid in sorted(static):
        if cid not in periods:
            continue
        mm = metrics[(metrics.model == "full") & (metrics.cell_id == cid)]
        kind = "test" if cid in test_cells else "val_window_untuned"
        e = entry(cid, mm, periods[cid], cid in hold, kind)
        if cid in hold:
            e["holdout_model"] = entry(cid, m_hold[m_hold.cell_id == cid], periods[cid], True, kind)
        e["region"] = static[cid]["region"]
        ev[cid] = e
    ev["tsn"] = dict(ev[TSN_CELL], cell_id="tsn", alias_of=TSN_CELL,
                     v2_comparison=[{k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()} for r in v2_cmp])
    (OUT / "evaluation_v3.json").write_text(json.dumps(ev, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "cell_static.json").write_text(json.dumps(static, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "feature_columns.json").write_text(json.dumps(feature_columns_v3(), indent=1), encoding="utf-8")

    cov = data.groupby("cell_id").timestamp.agg(["min", "max", "size"])
    meta = {
        "model_version": f"lgbm-hcmc-global-v3-{datetime.now():%Y%m%d}",
        "data": "backend/data/history/cells_history.db:hourly",
        "data_snapshot": {c: [str(r["min"]), str(r["max"]), int(r["size"])] for c, r in cov.iterrows()},
        "split": {"train_end": str(TRAIN_END), "val": [str(VAL_START), str(VAL_END)], "test_start": str(TEST_START),
                  "test_end": str(test_end), "purge": "7 days between splits; t and t+6h must lie inside a split",
                  "rows": {"train": len(train), "val": len(val), "test": len(test), "late_eval": len(late_eval)}},
        "test_cells": test_cells, "late_cells_evaluated_on_val_window": late_cells, "holdout_cells": hold,
        "rain_threshold_mm": ai_model.RAIN_THRESHOLD_MM, "rain_decision_threshold": thr,
        "holdout_rain_decision_threshold": thr_h, "best_iterations": iters, "holdout_best_iterations": iters_h,
        "params_regression": REG_PARAMS, "params_classification": CLF_PARAMS,
        "static_features": STATIC_FEATURES,
        "dist_to_coast_method": "haversine to nearest point of a hand-digitised coastline polyline "
                                "(Can Gio-Vung Tau-Binh Chau + Con Dao ring), ~few km accuracy; coastline_raw was empty",
        "region_method": "majority region of the cell's wards in data/locations/locations.json",
        "holdout_method": "all cells whose majority region is BR-VT (incl. Con Dao) + Thu Dau Mot cell and neighbours "
                          "within 1.5 grid steps; separate model trained without them",
        "tsn_v2_vs_v3": v2_cmp,
        "quick": args.quick,
        "trained_at": datetime.now().isoformat(timespec="seconds"),
    }
    # serving parity samples: last 48h windows at a few test hours for 3 cells
    samples = []
    rng = np.random.default_rng(SEED)
    for cid in [TSN_CELL] + [c for c in test_cells if c != TSN_CELL][:2]:
        rows = test[test.cell_id == cid]
        for i in rng.choice(len(rows), 5, replace=False):
            r = rows.iloc[int(i)]
            x = r[feature_columns_v3()].values.astype(np.float32)[None, :]
            samples.append({"cell_id": cid, "issued_at": str(r.timestamp),
                            "temp": {f"{h}h": float(models[f"temp_{h}h"].predict(x)[0]) for h in HORIZONS},
                            "rain": {f"{h}h": float(models[f"rain_{h}h"].predict(x)[0]) for h in HORIZONS}})
    (OUT / "serving_samples.json").write_text(json.dumps(samples, indent=1), encoding="utf-8")
    (OUT / "metadata_v3.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    log(f"done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
