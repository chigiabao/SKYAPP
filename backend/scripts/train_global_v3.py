"""
Train the global LightGBM v3 model (all Open-Meteo cells of new HCMC) and evaluate it.

Data:   backend/data/history/cells_history.db (table hourly, read-only; 67 cells, 2017-01-01 onwards).
Output: backend/models/v3/  (v2 files in backend/models/ are never touched)
        temperature_model_{1,3,6}h.pkl, rain_model_{1,3,6}h.pkl, feature_columns.json,
        cell_static.json, metadata_v3.json, evaluation_v3.json, per_cell_metrics.csv,
        selection_v3.json, serving_policy_v3.json, evaluation_report_v3.json,
        serving_samples.json (for the train/serve parity check in notebooks/global_model.ipynb)

Split (chronological, by issue time t; a row is in a split only if t and t+6h are inside it;
7-day gap between consecutive windows; each validation/test window is ~12 months = one dry + one rainy season):
        train       .. 2023-09-23 23:00                fit the boosters
        val_es      2023-10-01 00:00 .. 2024-09-23 23:00   early stopping, rain calibration, decision thresholds
        val_select  2024-10-01 00:00 .. 2025-09-23 23:00   model selection only: calibration method, per-cell
                                                           fallback, promotion (routers/monitor.py)
        test        2025-10-01 00:00 ..                    reporting only (block-bootstrap CIs)
Nothing chosen on a window is ever scored as if it were unseen on that window: val_es scores are in-sample
for the threshold/calibration, val_select scores are in-sample for the fallback/promotion, only test is clean.
Cells with fewer than 30 days of final-test data are labelled "test_limited"; cells without final-test
targets remain unscored. Validation rows are never substituted for a held-out test.

Rain probability calibration: isotonic and Platt (logistic on logit p) are fitted on val_es; the method with the
lowest val_select Brier is served (identity unless it gains >= 0.2 %). Decision thresholds are tuned on the
calibrated val_es probabilities. Brier / ECE before and after are reported on test.

Baselines: persistence (value / rain at t) and per-cell climatology (train-period mean temperature and rain
frequency by target month x hour). The climatology rain probability gets its own decision threshold tuned on
val_es exactly like the model. A cell "beats_baselines" only if, at every horizon, MAE < both baselines,
F1 > both (tuned) baselines and Brier < climatology Brier.

Per-cell fallback: for a (cell, horizon) where the calibrated model does not beat the baselines on val_select,
the served value becomes a blend with persistence (temperature w*model + (1-w)*value at t; rain probability
w*p + (1-w)*[rain at t]); w is chosen on val_select and kept only if it fixes/improves the failing metric there.
Rules are written to serving_policy_v3.json and applied by ai_model.apply_policy (same code here and serving).

Model selection (retrain/promote in routers/monitor.py) uses val_select only: with --compare-with DIR the
served model in DIR is scored on exactly the same val_select rows (calibration applied, fallback not, for both
models) and both scores go to selection_v3.json.

Spatial holdout: a second model is trained WITHOUT the cells of former Ba Ria-Vung Tau (incl.
Con Dao) and the ring of cells around Thu Dau Mot, then evaluated on those cells (raw probabilities).

Usage:  python scripts/train_global_v3.py [--quick] [--out DIR] [--compare-with DIR] [--max-cells N --rounds N]
        --quick drops rows before 2021; --max-cells / --rounds are for smoke runs only.
"""
from __future__ import annotations

import argparse
import hashlib
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
from sklearn.linear_model import LogisticRegression

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

D = pd.Timestamp
TRAIN_END = D("2023-09-23 23:00")                     # last TARGET time of train
VAL_ES_START, VAL_ES_END = D("2023-10-01 00:00"), D("2024-09-23 23:00")
VAL_SEL_START, VAL_SEL_END = D("2024-10-01 00:00"), D("2025-09-23 23:00")
TEST_START = D("2025-10-01 00:00")
VAL_START, VAL_END = VAL_ES_START, VAL_ES_END          # names used by older code (= the tuning window)
QUICK_START = D("2021-01-01 00:00")
MIN_TEST_HOURS = 24 * 30        # a cell needs >= 30 days of test rows to be evaluated on the test window
LIMITED_TEST = "test_limited"
CALIB_MIN_GAIN = 0.002          # calibration is served only if it lowers val_select Brier by >= 0.2 %
TEMP_BLEND_W = (0.75, 0.5, 0.25, 0.0)
RAIN_BLEND_W = (0.9, 0.8, 0.7, 0.6, 0.5)
N_BOOT, BLOCK_DAYS = 1000, 7

REGION_KEYS = {"TP.HCM cũ": "region_hcm", "Bình Dương cũ": "region_bd", "Bà Rịa–Vũng Tàu cũ": "region_brvt"}
REG_PARAMS = dict(objective="regression", metric="mae", learning_rate=0.05, num_leaves=63,
                  feature_fraction=0.8, bagging_fraction=0.8, bagging_freq=5, min_data_in_leaf=100,
                  seed=SEED, deterministic=True, verbose=-1, num_threads=12)
CLF_PARAMS = dict(REG_PARAMS, objective="binary", metric="binary_logloss")
MAX_ROUNDS, ES_ROUNDS = 3000, 100

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


def target_cols():
    return [f"{k}_target_{h}h" for h in HORIZONS for k in ("temp", "rain")]


def _cell_frames(con, static: dict, quick: bool, cells=None, snapshot=None):
    """Yield (cell_id, feature + target rows) per cell, float32."""
    cols = feature_columns_v3()
    for cid in sorted(cells or static):
        if snapshot is None:
            df = pd.read_sql("SELECT * FROM hourly WHERE cell_id = ? ORDER BY timestamp", con, params=(cid,))
        else:
            df = pd.read_sql("SELECT * FROM hourly WHERE cell_id = ? AND timestamp <= ? ORDER BY timestamp",
                             con, params=(cid, snapshot[cid][1]))
        if df.empty:
            continue
        df["timestamp"] = pd.to_datetime(df["timestamp"])
        df = df.drop_duplicates("timestamp").set_index("timestamp")
        df = df.reindex(pd.date_range(df.index.min(), df.index.max(), freq="h"))   # gaps -> NaN rows
        df = df.rename_axis("timestamp").reset_index().drop(columns=["cell_id"])
        if quick:
            df = df[df.timestamp >= QUICK_START - pd.Timedelta(days=2)].reset_index(drop=True)
        f = build_features_v3(df, static[cid])[cols].astype(np.float32)
        t = build_targets(df).astype(np.float32)
        g = pd.concat([df[["timestamp"]], f, t], axis=1)
        g["cell_id"] = cid
        g = g.dropna(subset=cols)
        if quick:
            g = g[g.timestamp >= QUICK_START]
        if snapshot is not None:
            g = g[g.timestamp >= pd.Timestamp(snapshot[cid][0])]
        del df, f, t
        yield cid, g


def load_frames(con, static: dict, quick: bool, cells=None) -> pd.DataFrame:
    """Feature + target rows of every cell in one frame."""
    d = pd.concat([g for _, g in _cell_frames(con, static, quick, cells)], ignore_index=True)
    d["cell_id"] = d["cell_id"].astype("category")
    return d


def load_split(con, static: dict, quick: bool, cells=None):
    """split() applied cell by cell: the full ~6M-row frame never exists at once (peak memory).
    Returns ((train, val_es, val_select, test), per-cell coverage frame)."""
    parts, cov = ([], [], [], []), {}
    for cid, g in _cell_frames(con, static, quick, cells):
        if len(g):
            cov[cid] = (g.timestamp.min(), g.timestamp.max(), len(g))
        for lst, w in zip(parts, split(g)):
            lst.append(w)
        del g
    out = []
    for lst in parts:
        w = pd.concat(lst, ignore_index=True)
        lst.clear()
        w["cell_id"] = w["cell_id"].astype("category")
        out.append(w)
    return tuple(out), pd.DataFrame.from_dict(cov, orient="index", columns=["min", "max", "size"])


def split(d: pd.DataFrame):
    """(train, val_es, val_select, test). Train / val rows need every target; test keeps partial rows
    (each horizon is scored on its own non-missing targets)."""
    tgt = d.timestamp + pd.Timedelta(hours=MAXH)
    full = d[target_cols()].notna().all(axis=1)
    train = d[(tgt <= TRAIN_END) & full]
    val_es = d[(d.timestamp >= VAL_ES_START) & (tgt <= VAL_ES_END) & full]
    val_sel = d[(d.timestamp >= VAL_SEL_START) & (tgt <= VAL_SEL_END) & full]
    test = d[d.timestamp >= TEST_START]
    return train, val_es, val_sel, test


def evaluation_cells(test):
    """Classify cells using final-test targets only; never borrow validation rows."""
    n = test.groupby("cell_id", observed=True)[target_cols()].count().min(axis=1)
    return sorted(n[n >= MIN_TEST_HOURS].index.astype(str)), sorted(n[(n > 0) & (n < MIN_TEST_HOURS)].index.astype(str))


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


def ece(p, y, bins=10):
    """Expected calibration error, equal-width bins."""
    p, y = np.asarray(p, float), np.asarray(y, float)
    if not len(p):
        return float("nan")
    idx = np.minimum((p * bins).astype(int), bins - 1)
    tot = 0.0
    for b in range(bins):
        m = idx == b
        if m.any():
            tot += m.sum() * abs(p[m].mean() - y[m].mean())
    return float(tot / len(p))


def reliability(p, y, bins=10):
    p, y = np.asarray(p, float), np.asarray(y, float)
    idx = np.minimum((p * bins).astype(int), bins - 1)
    return [[round(float(p[idx == b].mean()), 4), round(float(y[idx == b].mean()), 4), int((idx == b).sum())]
            for b in range(bins) if (idx == b).any()]


def fit_models(train, val, tag, rounds=None, es=None):
    """Boosters for temperature (L2/MAE) and rain (binary) at every horizon; early stopping on `val`
    (= val_es). One binned training Dataset is reused for all six targets (memory)."""
    cols = feature_columns_v3()
    models, iters = {}, {}
    dtr = lgb.Dataset(train[cols].to_numpy(np.float32), label=train["temp_target_1h"].to_numpy(np.float32),
                      params=dict(REG_PARAMS), free_raw_data=True).construct()
    Xva = val[cols].to_numpy(np.float32)
    for h in HORIZONS:
        for kind, params, y in (("temp", REG_PARAMS, f"temp_target_{h}h"), ("rain", CLF_PARAMS, f"rain_target_{h}h")):
            t0 = time.time()
            dtr.set_label(train[y].to_numpy(np.float32))
            dva = lgb.Dataset(Xva, val[y].to_numpy(np.float32), reference=dtr)
            m = lgb.train(params, dtr, num_boost_round=rounds or MAX_ROUNDS, valid_sets=[dva],
                          callbacks=[lgb.early_stopping(es or ES_ROUNDS, verbose=False)])
            m = m if m.best_iteration in (0, m.current_iteration()) else _truncate(m)
            models[f"{kind}_{h}h"] = m
            iters[f"{kind}_{h}h"] = int(m.current_iteration())
            log(f"{tag} {kind} {h}h: iters={iters[f'{kind}_{h}h']} ({time.time() - t0:.0f}s)")
    del dtr
    return models, iters


def _truncate(m):
    """Keep only the best iteration so the saved model predicts exactly what was evaluated."""
    return lgb.Booster(model_str=m.model_to_string(num_iteration=m.best_iteration))


def predict_raw(models, data, cols=None):
    cols = cols or feature_columns_v3()
    X = data[cols].to_numpy(np.float32)
    return {k: m.predict(X) for k, m in models.items()}


def climatology(train):
    """Per cell: train-period mean temperature and rain frequency by (month, hour) of the TARGET time."""
    c = train[["cell_id", "timestamp", "temperature", "precipitation"]].copy()
    c["cell_id"] = c.cell_id.astype(str)
    c["month"], c["hour"] = c.timestamp.dt.month, c.timestamp.dt.hour
    c["rain"] = (c.precipitation > ai_model.RAIN_THRESHOLD_MM).astype(float)
    return c.groupby(["cell_id", "month", "hour"])[["temperature", "rain"]].mean()


def clim_at_target(data, clim, h):
    """Climatology (temperature, rain frequency) at the target time t+h of every row of `data`."""
    tt = data.timestamp + pd.Timedelta(hours=h)
    return clim.reindex(pd.MultiIndex.from_arrays([data.cell_id.astype(str), tt.dt.month, tt.dt.hour]))


def climatology_thresholds(val, clim):
    """Decision threshold of the climatology rain baseline, tuned on val_es with the model's own rule."""
    thr = {}
    for h in HORIZONS:
        p = clim_at_target(val, clim, h).rain.values
        y = val[f"rain_target_{h}h"].values
        ok = ~(np.isnan(p) | np.isnan(y))
        thr[f"{h}h"] = tune_threshold(y[ok], p[ok])
    return thr


def score_frame(models, data, clim, h, policy=None, cols=None, preds=None) -> pd.DataFrame:
    """Row-level frame at horizon h: targets, served model outputs (policy applied), raw rain probability,
    persistence and climatology. Rows without a target or climatology are dropped."""
    preds = preds if preds is not None else predict_raw(models, data, cols)
    cl = clim_at_target(data, clim, h)
    m_t, m_p = ai_model.apply_policy(policy, h, data.cell_id.astype(str).values, preds[f"temp_{h}h"],
                                     preds[f"rain_{h}h"], data.temperature.values, data.precipitation.values)
    frame = pd.DataFrame({
        "cell_id": data.cell_id.astype(str).values, "timestamp": data.timestamp.values,
        "y_t": data[f"temp_target_{h}h"].values, "y_r": data[f"rain_target_{h}h"].values,
        "m_t": m_t, "m_p": m_p, "m_p_raw": np.clip(preds[f"rain_{h}h"], 0, 1),
        "p_t": data.temperature.values, "p_r": (data.precipitation.values > ai_model.RAIN_THRESHOLD_MM),
        "c_t": cl.temperature.values, "c_p": cl.rain.values})
    frame = frame.dropna(subset=["y_t", "y_r", "c_t", "c_p"])
    if not np.isfinite(frame[["m_t", "m_p", "m_p_raw"]].to_numpy()).all():
        raise ValueError("non-finite model predictions on evaluation rows")
    return frame


def evaluate(models, thr, data, clim, clim_thr, cols=None, policy=None, preds=None):
    """Per-cell metrics of the (served) model and both baselines on `data` (rows of one or more cells)."""
    rows = []
    if len(data) == 0:
        return pd.DataFrame(rows)
    preds = preds if preds is not None else predict_raw(models, data, cols)
    for h in HORIZONS:
        frame = score_frame(models, data, clim, h, policy, cols, preds)
        for cid, g in frame.groupby("cell_id"):
            y = g.y_r.values.astype(bool)
            brier_m, brier_c = float(((g.m_p - y) ** 2).mean()), float(((g.c_p - y) ** 2).mean())
            rows.append({"cell_id": cid, "horizon": f"{h}h", "n": len(g), "rain_rate": float(y.mean()),
                         "mae_v3": float(np.abs(g.y_t - g.m_t).mean()),
                         "mae_persistence": float(np.abs(g.y_t - g.p_t).mean()),
                         "mae_climatology": float(np.abs(g.y_t - g.c_t).mean()),
                         "f1_v3": f1(y, g.m_p.values >= thr[f"{h}h"]),
                         "f1_persistence": f1(y, g.p_r.values),
                         "f1_climatology": f1(y, g.c_p.values >= clim_thr[f"{h}h"]),
                         "brier_v3": brier_m, "brier_v3_raw": float(((g.m_p_raw - y) ** 2).mean()),
                         "brier_climatology": brier_c,
                         "brier_skill": 1 - brier_m / brier_c if brier_c > 0 else float("nan")})
    return pd.DataFrame(rows)


def horizon_beats(r) -> bool:
    return bool(r.mae_v3 < min(r.mae_persistence, r.mae_climatology)
                and r.f1_v3 > max(r.f1_persistence, r.f1_climatology) and r.brier_v3 < r.brier_climatology)


def mean_score(m: pd.DataFrame) -> dict:
    """Mean over cells and horizons (the aggregation routers/monitor.py uses), with the baselines."""
    a = m[[c for c in m.columns if c.startswith(("mae_", "f1_", "brier_"))]].mean()
    out = {"temperature_mae": a.mae_v3, "rain_f1": a.f1_v3, "rain_brier": a.brier_v3,
           "baseline_persistence_mae": a.mae_persistence, "baseline_climatology_mae": a.mae_climatology,
           "baseline_persistence_f1": a.f1_persistence, "baseline_climatology_f1": a.f1_climatology,
           "baseline_climatology_brier": a.brier_climatology}
    out = {k: round(float(v), 5) for k, v in out.items()}
    out["rain_brier_skill"] = (round(1 - a.brier_v3 / a.brier_climatology, 5)
                               if a.brier_climatology > 0 else None)
    out["beats_baselines"] = bool(
        out["temperature_mae"] < min(out["baseline_persistence_mae"], out["baseline_climatology_mae"])
        and out["rain_f1"] > max(out["baseline_persistence_f1"], out["baseline_climatology_f1"])
        and out["rain_brier"] < out["baseline_climatology_brier"])
    out.update(cells=int(m.cell_id.nunique()), rows=int(m[m.horizon == f"{HORIZONS[0]}h"].n.sum()))
    return out


# ------------------------------------------------------------------ calibration / thresholds / fallback
def fit_calibrators(p, y) -> dict:
    """Isotonic and Platt calibrators of one horizon, fitted on val_es, as JSON for ai_model.calibrate_rain."""
    p, y = np.clip(np.asarray(p, float), 0, 1), np.asarray(y, float)
    iso = IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1).fit(p, y)
    q = np.clip(p, 1e-6, 1 - 1e-6)
    lr = LogisticRegression(C=1e6, max_iter=1000).fit(np.log(q / (1 - q))[:, None], y)
    return {"none": {"method": "none"},
            "isotonic": {"method": "isotonic", "x": iso.X_thresholds_.tolist(), "y": iso.y_thresholds_.tolist()},
            "platt": {"method": "platt", "a": float(lr.coef_[0, 0]), "b": float(lr.intercept_[0])}}


def brier(p, y):
    return float(((np.asarray(p, float) - np.asarray(y, float)) ** 2).mean())


def choose_calibration(pred_es, val_es, pred_sel, val_sel):
    """Fit on val_es, choose on val_select. Returns ({h: calibrator}, report)."""
    chosen, report = {}, {}
    for h in HORIZONS:
        k = f"{h}h"
        y_es, y_sel = val_es[f"rain_target_{k}"].values, val_sel[f"rain_target_{k}"].values
        cands = fit_calibrators(pred_es[f"rain_{k}"], y_es)
        r = {}
        for name, cal in cands.items():
            pe = ai_model.calibrate_rain(pred_es[f"rain_{k}"], cal)
            ps = ai_model.calibrate_rain(pred_sel[f"rain_{k}"], cal)
            r[name] = {"val_es_brier": round(brier(pe, y_es), 6), "val_es_ece": round(ece(pe, y_es), 5),
                       "val_select_brier": round(brier(ps, y_sel), 6), "val_select_ece": round(ece(ps, y_sel), 5)}
        best = min(r, key=lambda n: r[n]["val_select_brier"])
        if r[best]["val_select_brier"] > r["none"]["val_select_brier"] * (1 - CALIB_MIN_GAIN):
            best = "none"
        chosen[k] = cands[best]
        report[k] = {"candidates": r, "chosen": best,
                     "isotonic_knots": len(cands["isotonic"]["x"]), "platt": cands["platt"]}
    return chosen, report


def tune_thresholds(pred, val, policy):
    thr = {}
    for h in HORIZONS:
        _, p = ai_model.apply_policy(policy, h, val.cell_id.astype(str).values, pred[f"temp_{h}h"],
                                     pred[f"rain_{h}h"], val.temperature.values, val.precipitation.values)
        thr[f"{h}h"] = tune_threshold(val[f"rain_target_{h}h"].values, p)
    return thr


def choose_fallback(models, thr, val_sel, clim, clim_thr, policy, preds):
    """Per (cell, horizon) failing the baseline rule on val_select: blend weights with persistence that fix /
    improve the failing metric on val_select. Returns (fallback rules, analysis rows)."""
    m = evaluate(models, thr, val_sel, clim, clim_thr, policy=policy, preds=preds)
    rules, analysis = {}, []
    frames = {h: score_frame(models, val_sel, clim, h, policy, preds=preds) for h in HORIZONS}
    for r in m.itertuples():
        if horizon_beats(r):
            continue
        h = int(r.horizon.rstrip("h"))
        g = frames[h][frames[h].cell_id == r.cell_id]
        y = g.y_r.values.astype(bool)
        a = {"cell_id": r.cell_id, "horizon": r.horizon,
             "fails": [n for n, bad in (("mae", r.mae_v3 >= min(r.mae_persistence, r.mae_climatology)),
                                        ("f1", r.f1_v3 <= max(r.f1_persistence, r.f1_climatology)),
                                        ("brier", r.brier_v3 >= r.brier_climatology)) if bad],
             "val_select_before": {"mae": round(r.mae_v3, 4), "mae_persistence": round(r.mae_persistence, 4),
                                   "mae_climatology": round(r.mae_climatology, 4), "f1": round(r.f1_v3, 4),
                                   "f1_persistence": round(r.f1_persistence, 4),
                                   "f1_climatology": round(r.f1_climatology, 4), "brier": round(r.brier_v3, 5),
                                   "brier_climatology": round(r.brier_climatology, 5)}}
        rule = {}
        if "mae" in a["fails"]:
            maes = {w: float(np.abs(g.y_t - (w * g.m_t + (1 - w) * g.p_t)).mean()) for w in TEMP_BLEND_W}
            w = min(maes, key=maes.get)
            if maes[w] < r.mae_v3:
                rule["temperature_weight"] = w
                a["val_select_after_mae"] = round(maes[w], 4)
        if "f1" in a["fails"] or "brier" in a["fails"]:
            best = None
            for w in RAIN_BLEND_W:
                p = w * g.m_p.values + (1 - w) * g.p_r.values
                f, b = f1(y, p >= thr[r.horizon]), brier(p, y)
                if b < r.brier_climatology and (best is None or f > best[1]):
                    best = (w, f, b)
            if best and best[1] > r.f1_v3:
                rule["rain_weight"] = best[0]
                a["val_select_after_f1"], a["val_select_after_brier"] = round(best[1], 4), round(best[2], 5)
        a["rule"] = rule
        analysis.append(a)
        if rule:
            rules.setdefault(r.cell_id, {})[r.horizon] = rule
    return rules, analysis


# ------------------------------------------------------------------ block bootstrap CI
def _daily_stats(frame, thr, clim_thr, h):
    k = f"{h}h"
    y = frame.y_r.values.astype(bool)
    pm, pc, pp = frame.m_p.values >= thr[k], frame.c_p.values >= clim_thr[k], frame.p_r.values.astype(bool)
    s = pd.DataFrame({"day": pd.to_datetime(frame.timestamp.values).floor("D"), "n": 1.0,
                      "ae_m": np.abs(frame.y_t - frame.m_t).values, "ae_p": np.abs(frame.y_t - frame.p_t).values,
                      "ae_c": np.abs(frame.y_t - frame.c_t).values,
                      "b_m": (frame.m_p.values - y) ** 2, "b_raw": (frame.m_p_raw.values - y) ** 2,
                      "b_c": (frame.c_p.values - y) ** 2})
    for name, pred in (("m", pm), ("p", pp), ("c", pc)):
        s[f"tp_{name}"], s[f"fp_{name}"], s[f"fn_{name}"] = (y & pred), (~y & pred), (y & ~pred)
    return s.groupby("day").sum()


def _metrics(S):
    """Metrics from summed sufficient statistics (array [..., stat] in STAT order)."""
    g = dict(zip(_STATS, np.moveaxis(S, -1, 0)))
    f = {n: 2 * g[f"tp_{n}"] / np.maximum(2 * g[f"tp_{n}"] + g[f"fp_{n}"] + g[f"fn_{n}"], 1) for n in "mpc"}
    mae = {n: g[f"ae_{n}"] / g["n"] for n in "mpc"}
    return {"mae_model": mae["m"], "mae_persistence": mae["p"], "mae_climatology": mae["c"],
            "mae_gain_vs_best_baseline": np.minimum(mae["p"], mae["c"]) - mae["m"],
            "f1_model": f["m"], "f1_persistence": f["p"], "f1_climatology": f["c"],
            "f1_gain_vs_best_baseline": f["m"] - np.maximum(f["p"], f["c"]),
            "brier_model": g["b_m"] / g["n"], "brier_model_uncalibrated": g["b_raw"] / g["n"],
            "brier_climatology": g["b_c"] / g["n"], "bss": 1 - g["b_m"] / g["b_c"]}


_STATS = ["n", "ae_m", "ae_p", "ae_c", "b_m", "b_raw", "b_c"] + [f"{a}_{n}" for n in "mpc" for a in ("tp", "fp", "fn")]


def block_bootstrap_ci(frames: dict, thr, clim_thr, n_boot=N_BOOT, block_days=BLOCK_DAYS, seed=SEED) -> dict:
    """Pooled (all cells) metrics per horizon and over all horizons with 95 % CIs from a block bootstrap:
    the test days are cut into consecutive blocks of `block_days` days (keeps weather autocorrelation and the
    cross-cell correlation of a day), blocks are resampled with replacement, the same blocks for every horizon."""
    daily = {h: _daily_stats(f, thr, clim_thr, h)[_STATS] for h, f in frames.items()}
    days = sorted(set().union(*[d.index for d in daily.values()]))
    if not days:
        return {}
    d0 = days[0]
    blocks = {}
    for h, d in daily.items():
        b = ((d.index - d0).days // block_days).values
        blocks[h] = d.groupby(b).sum().reindex(range(int(((days[-1] - d0).days // block_days)) + 1), fill_value=0)
    nb = len(next(iter(blocks.values())))
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, nb, size=(n_boot, nb))
    counts = np.stack([np.bincount(r, minlength=nb) for r in idx])           # n_boot x nb
    out = {"method": f"block bootstrap, {block_days}-day blocks of test days ({nb} blocks), {n_boot} replicates, "
                     "pooled over cells, percentile 95 % CI", "n_boot": n_boot, "block_days": block_days,
           "blocks": nb, "days": len(days)}
    total_point, total_boot = 0, 0
    for h in frames:
        A = blocks[h].to_numpy(float)
        point, boot = A.sum(0), counts @ A
        total_point, total_boot = total_point + point, total_boot + boot
        out[f"{h}h"] = _ci(point, boot)
    out["all"] = _ci(total_point, total_boot)
    return out


def _ci(point, boot):
    pm, bm = _metrics(point), _metrics(boot)
    return {k: {"value": round(float(pm[k]), 5), "ci95": [round(float(np.percentile(bm[k], 2.5)), 5),
                                                          round(float(np.percentile(bm[k], 97.5)), 5)]}
            for k in pm}


# ------------------------------------------------------------------ selection vs served model
def load_served(d: Path):
    """Models, rain thresholds, feature columns, version and calibration-only policy of a v3 directory."""
    meta = json.loads((d / "metadata_v3.json").read_text(encoding="utf-8"))
    cols = json.loads((d / "feature_columns.json").read_text(encoding="utf-8"))
    models = {k: joblib.load(d / f"{n}_model_{h}h.pkl")
              for h in HORIZONS for k, n in ((f"temp_{h}h", "temperature"), (f"rain_{h}h", "rain"))}
    policy = {}
    try:
        p = json.loads((d / ai_model.POLICY_FILE).read_text(encoding="utf-8"))
        if p.get("model_version") == meta.get("model_version"):
            policy = {"rain_calibration": p.get("rain_calibration") or {}}
    except (OSError, ValueError):
        pass
    if not policy.get("rain_calibration") and (d / "extension_v3.json").exists():
        ext = json.loads((d / "extension_v3.json").read_text(encoding="utf-8"))
        if ext.get("base_model_version") == meta.get("model_version"):
            calibrations = {}
            for h in HORIZONS:
                k = f"{h}h"
                if ext["rain_calibration"]["per_horizon"][k]["applied"]:
                    iso = joblib.load(d / f"rain_calibrator_{k}.pkl")
                    calibrations[k] = {"method": "isotonic", "x": iso.X_thresholds_.tolist(),
                                       "y": iso.y_thresholds_.tolist()}
            policy = {"rain_calibration": calibrations}
    return models, meta["rain_decision_threshold"], cols, meta.get("model_version"), policy


def selection(models, thr, val, clim, clim_thr, compare_with, policy=None):
    """val_select scores of the new model and (optionally) the served model on the SAME rows.
    Calibration is applied for both (each its own); per-cell fallback is not (it was chosen on val_select)."""
    sel = {"split": "val_select", "window": [str(VAL_SEL_START), str(VAL_SEL_END)],
           "comparison_policy": "rain_calibration_only",
           "note": "decides promotion on identical validation rows; calibration parameters and thresholds are "
                   "fitted on val_es, calibration method chosen on val_select; incumbent fitting/tuning rows "
                   "and a 7-day gap are excluded; test is reporting only",
           "candidate": None,
           "current": None, "current_dir": str(compare_with) if compare_with else None,
           "current_model_version": None, "current_error": None}
    served = None
    start = VAL_SEL_START
    if compare_with is None or not (compare_with / "metadata_v3.json").exists():
        sel["current_error"] = "no served model to compare with"
    else:
        try:
            served = load_served(compare_with)
            meta = json.loads((compare_with / "metadata_v3.json").read_text(encoding="utf-8"))
            split_info = meta.get("split", {})
            cutoffs = [pd.Timestamp(split_info[k][1]) for k in ("val", "val_es", "val_select") if k in split_info]
            if "train_end" in split_info:
                cutoffs.append(pd.Timestamp(split_info["train_end"]))
            if cutoffs:
                cutoff = max(cutoffs)
                start = max(start, cutoff + pd.Timedelta(days=7, hours=1))
                sel["current_fit_selection_cutoff"] = str(cutoff)
            missing = sorted(set(served[2]) - set(val.columns))
            if missing:
                raise ValueError(f"served model needs features this code does not build: {missing[:5]}")
        except (OSError, ValueError, KeyError) as e:
            served = None
            sel["current_error"] = f"{type(e).__name__}: {e}"
    sel["window"] = [str(start), str(VAL_SEL_END)]
    val = val[(val.timestamp >= start) & (val.timestamp + pd.Timedelta(hours=MAXH) <= VAL_SEL_END)]
    if val.empty:
        sel["current_error"] = "no common validation rows after incumbent fitting/selection and purge"
        return sel
    row_hash = hashlib.sha256(pd.util.hash_pandas_object(
        val[["cell_id", "timestamp", *target_cols()]].sort_values(["cell_id", "timestamp"]), index=False
    ).values.tobytes()).hexdigest()
    sel["candidate"] = mean_score(evaluate(models, thr, val, clim, clim_thr,
                                          policy={"rain_calibration": (policy or {}).get("rain_calibration", {})}))
    sel["candidate"]["evaluation_rows_sha256"] = row_hash
    if served is not None:
        try:
            cur, cur_thr, cur_cols, version, cur_policy = served
            sel["current"] = mean_score(evaluate(cur, cur_thr, val, clim, clim_thr, cols=cur_cols, policy=cur_policy))
            sel["current"]["evaluation_rows_sha256"] = row_hash
            sel["current_model_version"] = version
            sel["current_calibrated"] = bool(cur_policy.get("rain_calibration"))
        except (OSError, ValueError, KeyError) as e:
            sel["current_error"] = f"{type(e).__name__}: {e}"
    return sel


def evaluate_saved_selection(directory, compare_with):
    """Re-score saved boosters on their frozen snapshot, without fitting or writing model artifacts."""
    meta = json.loads((directory / "metadata_v3.json").read_text(encoding="utf-8"))
    if meta["split"]["train_end"] != str(TRAIN_END) or meta["split"]["val_select"] != [str(VAL_SEL_START), str(VAL_SEL_END)]:
        raise ValueError("saved model split differs from this evaluation recipe")
    static = json.loads((directory / "cell_static.json").read_text(encoding="utf-8"))
    models, thr, cols, version, policy = load_served(directory)
    if cols != feature_columns_v3():
        raise ValueError("saved model features differ from this evaluation recipe")
    vals, climates = [], []
    with sqlite3.connect(f"file:{DB.as_posix()}?mode=ro", uri=True) as con:
        for _, data in _cell_frames(con, static, False, snapshot=meta["data_snapshot"]):
            train, _, val, _ = split(data)
            climates.append(climatology(train))
            vals.append(val)
    result = selection(models, thr, pd.concat(vals, ignore_index=True), pd.concat(climates),
                       meta["climatology_rain_decision_threshold"], compare_with, policy)
    result["candidate_model_version"] = version
    return result


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
        e[f"baseline_climatology_f1_{h}"] = round(r.f1_climatology, 3)   # threshold tuned on val_es
        raw = r.brier_v3_raw if "brier_v3_raw" in m.columns else r.brier_v3
        e[f"rain_brier_{h}"] = round(r.brier_v3, 5)
        e[f"rain_brier_uncalibrated_{h}"] = round(raw, 5)
        e[f"baseline_climatology_brier_{h}"] = round(r.brier_climatology, 5)
        e[f"rain_brier_skill_{h}"] = round(r.brier_skill, 4)
        e[f"rain_brier_skill_uncalibrated_{h}"] = round(1 - raw / r.brier_climatology, 4) if r.brier_climatology else None
        beats &= horizon_beats(r)
    e.update(beats_baselines=bool(beats), test_period=period, holdout=bool(holdout),
             test_kind=kind, n_test_hours=int(m.n.min()))
    return e


def calibration_report_test(frames):
    out = {}
    for h, f in frames.items():
        y = f.y_r.values
        out[f"{h}h"] = {"brier_uncalibrated": round(brier(f.m_p_raw, y), 6), "brier_served": round(brier(f.m_p, y), 6),
                        "brier_climatology": round(brier(f.c_p, y), 6),
                        "ece_uncalibrated": round(ece(f.m_p_raw.values, y), 5), "ece_served": round(ece(f.m_p.values, y), 5),
                        "reliability_uncalibrated": reliability(f.m_p_raw.values, y),
                        "reliability_served": reliability(f.m_p.values, y)}
    return out


def main():
    global OUT, MAX_ROUNDS
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="drop pre-2021 rows (faster run)")
    ap.add_argument("--out", type=Path, default=OUT, help="output directory (default backend/models/v3)")
    ap.add_argument("--compare-with", type=Path, default=None,
                    help="served v3 directory to score on the same val_select rows (written to selection_v3.json)")
    ap.add_argument("--max-cells", type=int, default=0, help="smoke run: first N cells (+ the tsn cell)")
    ap.add_argument("--rounds", type=int, default=0, help="smoke run: max boosting rounds")
    ap.add_argument("--evaluate-only", action="store_true", help="re-score saved selection; never train or modify models")
    ap.add_argument("--selection-out", type=Path, help="new JSON output path for --evaluate-only")
    args = ap.parse_args()
    if args.evaluate_only:
        if args.selection_out is None or args.selection_out.exists():
            ap.error("--evaluate-only requires a new --selection-out path")
        result = evaluate_saved_selection(args.out, args.compare_with)
        args.selection_out.parent.mkdir(parents=True, exist_ok=True)
        args.selection_out.write_text(json.dumps(result, indent=1, allow_nan=False), encoding="utf-8")
        print(json.dumps(result, indent=1, allow_nan=False), flush=True)
        return
    OUT = args.out
    MAX_ROUNDS = args.rounds or MAX_ROUNDS
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "train_log.txt").write_text("", encoding="utf-8")
    con = sqlite3.connect(f"file:{DB.as_posix()}?mode=ro", uri=True)
    static = cell_static(con)
    cells = None
    if args.max_cells:
        cells = sorted(set(sorted(static)[:args.max_cells]) | {TSN_CELL})
        static = {c: static[c] for c in cells}
    hold = holdout_cells(static) if not args.max_cells else [c for c in holdout_cells(cell_static(con)) if c in static]
    t0 = time.time()
    (train, val_es, val_sel_all, test_all), cov = load_split(con, static, args.quick, cells)
    con.close()
    log(f"rows={int(cov['size'].sum()):,} cells={len(cov)} holdout={len(hold)} load={time.time() - t0:.0f}s "
        f"span={cov['min'].min()}..{cov['max'].max()}")
    test_cells, late_cells = evaluation_cells(test_all)
    val_sel = val_sel_all
    test = test_all[test_all.cell_id.isin(test_cells)]
    late_eval = test_all[test_all.cell_id.isin(late_cells)]
    del val_sel_all, test_all
    rows = {"train": len(train), "val_es": len(val_es), "val_select": len(val_sel), "test": len(test),
            "late_eval": len(late_eval)}
    log(f"rows per split {rows} test_cells={len(test_cells)} late={len(late_cells)}")

    # leakage / split checks: windows ordered, separated by >= 7 days, targets inside their window
    assert (train.timestamp + pd.Timedelta(hours=MAXH)).max() <= TRAIN_END < VAL_ES_START - pd.Timedelta(days=7)
    assert val_es.timestamp.min() >= VAL_ES_START and (val_es.timestamp + pd.Timedelta(hours=MAXH)).max() <= VAL_ES_END
    assert VAL_ES_END < VAL_SEL_START - pd.Timedelta(days=7) and VAL_SEL_END < TEST_START - pd.Timedelta(days=7)
    assert val_sel.timestamp.min() >= VAL_SEL_START and (val_sel.timestamp + pd.Timedelta(hours=MAXH)).max() <= VAL_SEL_END
    assert test.timestamp.min() >= TEST_START
    assert not any("target" in c for c in feature_columns_v3())

    clim = climatology(train)
    clim_thr = climatology_thresholds(val_es, clim)
    # ---- full model (served): fit on train, early stopping on val_es
    models, iters = fit_models(train, val_es, "full")
    for h in HORIZONS:
        joblib.dump(models[f"temp_{h}h"], OUT / f"temperature_model_{h}h.pkl")
        joblib.dump(models[f"rain_{h}h"], OUT / f"rain_model_{h}h.pkl")
    pred_es, pred_sel = predict_raw(models, val_es), predict_raw(models, val_sel)
    # ---- calibration fitted on val_es, method chosen on val_select; thresholds on calibrated val_es
    calibration, calib_report = choose_calibration(pred_es, val_es, pred_sel, val_sel)
    policy_cal = {"rain_calibration": calibration}
    thr = tune_thresholds(pred_es, val_es, policy_cal)
    log(f"calibration chosen={ {k: v['chosen'] for k, v in calib_report.items()} } thresholds={thr}")
    # ---- promotion score on val_select (calibration only, no fallback)
    sel = selection(models, thr, val_sel, clim, clim_thr, args.compare_with, policy=policy_cal)
    (OUT / "selection_v3.json").write_text(json.dumps(sel, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"val_select selection: candidate={sel['candidate']} current={sel['current']} ({sel['current_error']})")
    # ---- per-cell fallback chosen on val_select
    fallback, fb_analysis = choose_fallback(models, thr, val_sel, clim, clim_thr, policy_cal, pred_sel)
    del pred_es, pred_sel
    log(f"fallback: {len(fb_analysis)} failing (cell, horizon) on val_select; rules for {len(fallback)} cells")
    model_version = f"lgbm-hcmc-global-v3-{datetime.now():%Y%m%d}"
    policy = {"model_version": model_version, "rain_calibration": calibration, "fallback": fallback,
              "fallback_rule": "per (cell, horizon) failing beats_baselines on val_select: temperature = "
                               "w*model + (1-w)*persistence, rain probability = w*p + (1-w)*[rain at t]; "
                               "w chosen on val_select, kept only if it improves the failing metric there"}
    (OUT / ai_model.POLICY_FILE).write_text(json.dumps(policy, ensure_ascii=False, indent=1), encoding="utf-8")

    # ---- test: reporting only (all decisions above are frozen)
    pred_test = predict_raw(models, test)
    m_test = evaluate(models, thr, test, clim, clim_thr, policy=policy, preds=pred_test).assign(model="full", split="test")
    m_test_model_only = evaluate(models, thr, test, clim, clim_thr, policy=policy_cal, preds=pred_test)
    frames = {h: score_frame(models, test, clim, h, policy, preds=pred_test) for h in HORIZONS}
    ci = block_bootstrap_ci(frames, thr, clim_thr)
    calib_test = calibration_report_test(frames)
    del frames
    for a in fb_analysis:   # test effect of each fallback rule (reporting only)
        mo = m_test_model_only[(m_test_model_only.cell_id == a["cell_id"]) & (m_test_model_only.horizon == a["horizon"])]
        ms = m_test[(m_test.cell_id == a["cell_id"]) & (m_test.horizon == a["horizon"])]
        if len(mo) and len(ms):
            mo, ms = mo.iloc[0], ms.iloc[0]
            a["test_model_only"] = {"mae": round(mo.mae_v3, 4), "f1": round(mo.f1_v3, 4), "brier": round(mo.brier_v3, 5),
                                    "beats": horizon_beats(mo)}
            a["test_served"] = {"mae": round(ms.mae_v3, 4), "f1": round(ms.f1_v3, 4), "brier": round(ms.brier_v3, 5),
                                "mae_persistence": round(ms.mae_persistence, 4), "mae_climatology": round(ms.mae_climatology, 4),
                                "f1_persistence": round(ms.f1_persistence, 4), "f1_climatology": round(ms.f1_climatology, 4),
                                "brier_climatology": round(ms.brier_climatology, 5), "beats": horizon_beats(ms)}
    del pred_test
    m_late = evaluate(models, thr, late_eval, clim, clim_thr, policy=policy).assign(model="full", split=LIMITED_TEST)
    log(f"test (served policy): {mean_score(m_test)}")

    # ---- spatial holdout model (raw probabilities, threshold on its own val_es)
    tr_h, va_h = train[~train.cell_id.isin(hold)], val_es[~val_es.cell_id.isin(hold)]
    del train
    models_h, iters_h = fit_models(tr_h, va_h, "holdout")
    del tr_h
    thr_h = tune_thresholds(predict_raw(models_h, va_h), va_h, None)
    clim_thr_h = climatology_thresholds(va_h, clim)
    hold_data = pd.concat([test[test.cell_id.isin(hold)], late_eval[late_eval.cell_id.isin(hold)]])
    m_hold = evaluate(models_h, thr_h, hold_data, clim, clim_thr_h).assign(model="holdout")
    if len(m_hold):
        m_hold["split"] = np.where(m_hold.cell_id.isin(test_cells), "test", LIMITED_TEST)

    # ---- v2 at tsn on the same rows (raw outputs of both)
    v2_cmp = []
    if TSN_CELL in test_cells:
        v2 = {k: joblib.load(BACKEND / "models" / f"{n}_model_{h}h.pkl")
              for h in HORIZONS for k, n in ((f"temp_{h}h", "temperature"), (f"rain_{h}h", "rain"))}
        v2_meta = json.loads((BACKEND / "models" / "model_metadata.json").read_text(encoding="utf-8"))
        tsn_rows = test[test.cell_id == TSN_CELL]
        Xv2 = tsn_rows[ai_model.feature_columns()].values
        for h in HORIZONS:
            ok = tsn_rows[f"temp_target_{h}h"].notna().values
            y_t, y_r = tsn_rows[f"temp_target_{h}h"].values[ok], tsn_rows[f"rain_target_{h}h"].values[ok]
            Xv3 = tsn_rows[feature_columns_v3()].values[ok]
            for name, mt, mr, th in (("v2", v2[f"temp_{h}h"], v2[f"rain_{h}h"], v2_meta["rain_decision_threshold"][f"{h}h"]),
                                     ("v3", models[f"temp_{h}h"], models[f"rain_{h}h"], thr[f"{h}h"])):
                X = Xv2[ok] if name == "v2" else Xv3
                pr = mr.predict(X) if name == "v2" else ai_model.calibrate_rain(mr.predict(X), calibration[f"{h}h"])
                v2_cmp.append({"horizon": f"{h}h", "model": name, "n": int(ok.sum()),
                               "mae": float(np.abs(y_t - mt.predict(X)).mean()), "f1": f1(y_r.astype(bool), pr >= th)})

    # ---- outputs
    metrics = pd.concat([m_test, m_late, m_hold], ignore_index=True)
    metrics["holdout_cell"] = metrics.cell_id.isin(hold)
    metrics.to_csv(OUT / "per_cell_metrics.csv", index=False)
    test_end = test.timestamp.max() if len(test) else TEST_START
    periods = {c: f"{TEST_START:%Y-%m-%d}..{test[test.cell_id == c].timestamp.max():%Y-%m-%d}" for c in test_cells}
    periods.update({c: f"{TEST_START:%Y-%m-%d}..{late_eval[late_eval.cell_id == c].timestamp.max():%Y-%m-%d}"
                    for c in late_cells})
    ev = {}
    for cid in sorted(static):
        if cid not in periods:
            continue
        mm = metrics[(metrics.model == "full") & (metrics.cell_id == cid)]
        if len(mm) != len(HORIZONS):
            continue
        kind = "test" if cid in test_cells else LIMITED_TEST
        e = entry(cid, mm, periods[cid], cid in hold, kind)
        mo = m_test_model_only[m_test_model_only.cell_id == cid]
        if len(mo) == len(HORIZONS):
            e["beats_baselines_model_only"] = bool(all(horizon_beats(r) for r in mo.itertuples()))
        if cid in fallback:
            e["serving_fallback"] = fallback[cid]
        if cid in hold and len(m_hold[m_hold.cell_id == cid]):
            e["holdout_model"] = entry(cid, m_hold[m_hold.cell_id == cid], periods[cid], True, kind)
        e["region"] = static[cid]["region"]
        ev[cid] = e
    if TSN_CELL in ev:
        ev["tsn"] = dict(ev[TSN_CELL], cell_id="tsn", alias_of=TSN_CELL,
                         v2_comparison=[{k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()} for r in v2_cmp])
    (OUT / "evaluation_v3.json").write_text(json.dumps(ev, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "cell_static.json").write_text(json.dumps(static, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "feature_columns.json").write_text(json.dumps(feature_columns_v3(), indent=1), encoding="utf-8")

    report = {"model_version": model_version, "test_window": [str(TEST_START), str(test_end)],
              "test_mean_score_served": mean_score(m_test), "test_mean_score_model_only": mean_score(m_test_model_only),
              "test_bootstrap_ci": ci, "rain_calibration": {"selection": calib_report, "test": calib_test},
              "fallback_analysis": fb_analysis,
              "cells_beating_baselines_test": {"served": int(sum(e["beats_baselines"] for c, e in ev.items() if c != "tsn")),
                                               "model_only": int(sum(e.get("beats_baselines_model_only", False)
                                                                     for c, e in ev.items() if c != "tsn")),
                                               "cells": len([c for c in ev if c != "tsn"])}}
    (OUT / "evaluation_report_v3.json").write_text(json.dumps(report, ensure_ascii=False, indent=1, default=str),
                                                   encoding="utf-8")
    meta = {
        "model_version": model_version,
        "data": "backend/data/history/cells_history.db:hourly",
        "data_snapshot": {str(c): [str(r["min"]), str(r["max"]), int(r["size"])] for c, r in cov.iterrows()},
        "split": {"train_end": str(TRAIN_END), "val_es": [str(VAL_ES_START), str(VAL_ES_END)],
                  "val_select": [str(VAL_SEL_START), str(VAL_SEL_END)],
                  "val": [str(VAL_ES_START), str(VAL_ES_END)],
                  "test_start": str(TEST_START), "test_end": str(test_end),
                  "roles": {"train": "fit", "val_es": "early stopping, rain calibration fit, decision thresholds",
                            "val_select": "calibration method choice, per-cell fallback, promotion",
                            "test": "reporting only"},
                  "purge": "7 days between windows; t and t+6h must lie inside a window", "rows": rows},
        "test_cells": test_cells, "late_cells_evaluated_on_test": late_cells, "holdout_cells": hold,
        "unscored_cells": sorted(set(static) - set(ev)),
        "late_cells_note": f"test_kind '{LIMITED_TEST}': fewer than 30 days of final-test targets; "
                           "no validation rows used for test scoring; cells without final-test targets are unscored",
        "rain_threshold_mm": ai_model.RAIN_THRESHOLD_MM, "rain_decision_threshold": thr,
        "rain_decision_threshold_applies_to": "calibrated probability (serving_policy_v3.json)",
        "rain_calibration": {k: v["chosen"] for k, v in calib_report.items()},
        "serving_policy_file": ai_model.POLICY_FILE,
        "fallback_cells": {c: v for c, v in fallback.items()},
        "climatology_rain_decision_threshold": clim_thr, "holdout_climatology_rain_decision_threshold": clim_thr_h,
        "baseline_rules": "climatology rain threshold tuned on val_es like the model; beats_baselines needs, at every "
                          "horizon, MAE < persistence and climatology, F1 > both, Brier < climatology Brier",
        "validation_selection": sel,
        "test_bootstrap_ci_all": ci.get("all"),
        "holdout_rain_decision_threshold": thr_h, "best_iterations": iters, "holdout_best_iterations": iters_h,
        "params_regression": REG_PARAMS, "params_classification": CLF_PARAMS, "max_rounds": MAX_ROUNDS,
        "static_features": STATIC_FEATURES,
        "dist_to_coast_method": "haversine to nearest point of a hand-digitised coastline polyline "
                                "(Can Gio-Vung Tau-Binh Chau + Con Dao ring), ~few km accuracy; coastline_raw was empty",
        "region_method": "majority region of the cell's wards in data/locations/locations.json",
        "holdout_method": "all cells whose majority region is BR-VT (incl. Con Dao) + Thu Dau Mot cell and neighbours "
                          "within 1.5 grid steps; separate model trained without them (raw probabilities)",
        "tsn_v2_vs_v3": v2_cmp,
        "quick": args.quick, "smoke": bool(args.max_cells or args.rounds),
        "trained_at": datetime.now().isoformat(timespec="seconds"),
    }
    # serving parity samples (raw model outputs): last 48h windows at a few test hours for 3 cells
    samples = []
    rng = np.random.default_rng(SEED)
    for cid in [c for c in [TSN_CELL] + [c for c in test_cells if c != TSN_CELL][:2] if c in test_cells]:
        rr = test[test.cell_id == cid]
        for i in rng.choice(len(rr), min(5, len(rr)), replace=False):
            r = rr.iloc[int(i)]
            x = r[feature_columns_v3()].values.astype(np.float32)[None, :]
            samples.append({"cell_id": cid, "issued_at": str(r.timestamp),
                            "temp": {f"{h}h": float(models[f"temp_{h}h"].predict(x)[0]) for h in HORIZONS},
                            "rain": {f"{h}h": float(models[f"rain_{h}h"].predict(x)[0]) for h in HORIZONS}})
    (OUT / "serving_samples.json").write_text(json.dumps(samples, indent=1), encoding="utf-8")
    (OUT / "metadata_v3.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    log(f"done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
