"""Train/evaluate long-range v2 (direct 1..168h LightGBM, past-only inputs).

Same splits as v1 (train 2021-01-01..2024-06-30, validation 2024-07-08..2024-12-24,
test 2025-01-01..2026-10-16, issue and issue+168h inside a split). Climatology
tables and damping coefficients use train-period labels only; training rows use
leave-one-year-out tables (valid-time year excluded) so features never contain their own label.

  --phase dev    compare target modes (raw/anomaly/damped) on validation; no artifacts, no test.
  --phase final  train chosen modes (long 1..168h + short 1..24h boosters), fit the blend policy
                 on validation, write artifacts and check serving parity. No test.
  --phase test   load the saved artifacts and score TEST exactly once (refuses a second run).

Every model/mode/policy choice uses validation only. Reads SQLite read-only,
no downloads, num_threads <= 4, RSS guard. Existing output directories are never overwritten.
Example: python scripts/train_long_range_v2.py --phase final --modes ... --short-modes ...
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
import long_range_model as M1  # noqa: E402
import long_range_model_v2 as M  # noqa: E402
from train_long_range import connect, rss_mib  # noqa: E402

TRAIN_START = pd.Timestamp("2021-01-01")
TRAIN_END = pd.Timestamp("2024-06-30 23:00")
VAL_START = pd.Timestamp("2024-07-08")
VAL_END = pd.Timestamp("2024-12-24 23:00")
TEST_START = pd.Timestamp("2025-01-01")
TEST_END = pd.Timestamp("2026-10-16 23:00")
V3_CLEAN_START = pd.Timestamp("2025-10-01")  # V3 used 2023-10..2025-09-23 for early stopping/selection
V3_HORIZONS = (1, 3, 6)
V3_TARGETS = {"temperature": 2, "rain_probability": 4, "humidity": 1, "wind_speed": 1, "precipitation_mm": 2}
KEY_HORIZONS = (1, 2, 3, 6, 12, 24, 48, 72, 96, 120, 144, 168)
WARMUP = pd.Timedelta(hours=M.MIN_HISTORY_HOURS)
RSS_LIMIT_MIB = 6000
POLICY_MIN_GAIN = 0.01  # a V3 blend is kept only if it improves the validation metric by >= 1 %
LIMITATIONS = [
    "Experimental direct-horizon model; validation-selected, not superior at every horizon/cell.",
    "Labels are historical weather-model output (Open-Meteo), not station observations.",
    "The DB has no issue-vintage timestamps: temporal hindcast is not an operational skill claim.",
    "Inputs are the last 48 hourly rows of the cell plus train-period climatology; no NWP inputs.",
    "Rain probability is uncalibrated; Brier/log-loss are held-out scores, not accuracy percentages.",
    "Spatial scope is the trained cells only; no independent spatial holdout.",
]
OBJECTIVE = {"temperature": "regression_l1", "humidity": "regression_l1", "wind_speed": "regression_l1",
             "cloud_cover": "regression_l1", "precipitation_mm": "regression", "rain_probability": "binary"}
METRIC = {"rain_probability": "binary_logloss", "precipitation_mm": "rmse"}
PRIMARY = {"rain_probability": "brier", "precipitation_mm": "rmse"}
V3_COLUMNS = ("dew_point", "apparent_temperature", "weather_code", "surface_pressure", "wind_gusts",
              "wind_direction")


def log(msg, start):
    print(f"[{time.monotonic() - start:7.1f}s RSS={rss_mib():.0f}MiB] {msg}", flush=True)


def guard():
    if rss_mib() > RSS_LIMIT_MIB:
        raise MemoryError(f"RSS exceeded {RSS_LIMIT_MIB} MiB guard")


def labels(raw: pd.DataFrame) -> dict:
    """Target arrays in target units (rain_probability = 0/1 event > 0.1 mm), NaN when invalid."""
    out = {}
    for name, (src, lower, upper) in M.TARGETS.items():
        v = pd.to_numeric(raw[src], errors="coerce").to_numpy(dtype=float, copy=True)
        v[~np.isfinite(v)] = np.nan
        if name == "rain_probability":
            out[name] = np.where(np.isfinite(v) & (v >= 0), (v > M.RAIN_THRESHOLD_MM).astype(float), np.nan)
            continue
        if lower is not None:
            v[v < lower] = np.nan
        if upper is not None:
            v[v > upper] = np.nan
        out[name] = v
    return out


def climatology_tables(raw: pd.DataFrame, train_mask: np.ndarray) -> dict:
    """Month x hour means of train-period values (flat 288 list per key)."""
    ts = raw.timestamp[train_mask]
    tables = {}
    for key in M.CLIM_KEYS:
        values = M.rain_flag(raw.precipitation) if key == "rain" else raw[key].to_numpy(dtype=float)
        frame = pd.DataFrame({"m": ts.dt.month.to_numpy(), "h": ts.dt.hour.to_numpy(), "y": values[train_mask]})
        table = frame.groupby(["m", "h"]).y.mean().reindex(
            pd.MultiIndex.from_product([range(1, 13), range(24)])).to_numpy()
        if not np.isfinite(table).all():
            raise ValueError(f"incomplete train climatology for {key}")
        tables[key] = [round(float(v), 6) for v in table]
    return tables


def clim_step(table, ts) -> np.ndarray:
    """v1 climatology baseline: per-cell (month, hour) train mean, no interpolation."""
    ts = pd.DatetimeIndex(ts)
    return np.asarray(table, dtype=float).reshape(12, 24)[ts.month - 1, ts.hour]


def load_cells(args, start):
    cells = {}
    with connect(args.db) as con:
        static = {r[0]: dict(zip(M.STATIC_FEATURES, r[1:])) for r in
                  con.execute("SELECT cell_id,lat,lon,elevation FROM cells")}
        sources = dict(con.execute("SELECT cell_id,source FROM cells"))
        coverage = pd.read_sql_query("SELECT cell_id, MIN(timestamp) AS first_hour, MAX(timestamp) AS last_hour, "
                                     "COUNT(*) AS rows FROM hourly GROUP BY cell_id", con)
        columns = ",".join(f'"{c}"' for c in M.WEATHER_FEATURES + V3_COLUMNS)
        ids = sorted(coverage.cell_id) if not args.cells else sorted(coverage.cell_id)[:args.cells]
        for cid in ids:
            raw = pd.read_sql_query(f"SELECT timestamp,{columns} FROM hourly WHERE cell_id=? AND timestamp>=? "
                                    "AND timestamp<=? ORDER BY timestamp", con,
                                    params=(cid, str(TRAIN_START - WARMUP), str(TEST_END)))
            raw["timestamp"] = M.timestamps(raw.timestamp).to_numpy()
            if raw.timestamp.duplicated().any():
                raise ValueError(f"duplicate timestamps: {cid}")
            raw = raw.set_index("timestamp").reindex(
                pd.date_range(raw.timestamp.min(), raw.timestamp.max(), freq="h")).rename_axis("timestamp")
            cells[cid] = raw.reset_index()
    snapshot = {r.cell_id: {"first_hour": r.first_hour, "last_hour": r.last_hour, "rows": int(r.rows),
                            "source": sources[r.cell_id]} for r in coverage.itertuples() if r.cell_id in cells}
    log(f"loaded {len(cells)} cells", start)
    return cells, {c: static[c] for c in cells}, snapshot


def damping(cells, climate) -> dict:
    """rho(h) = sum a_t a_{t+h} / sum a_t^2 of train-period anomalies, pooled over cells."""
    num = {n: np.zeros(M.MAX_HORIZON) for n in M.TARGETS}
    den = {n: np.zeros(M.MAX_HORIZON) for n in M.TARGETS}
    for cid, raw in cells.items():
        mask = ((raw.timestamp >= TRAIN_START) & (raw.timestamp <= TRAIN_END)).to_numpy()
        ts = raw.timestamp[mask]
        y = labels(raw)
        for name in M.TARGETS:
            a = y[name][mask] - M.clim_values(climate[cid][M.TARGET_CLIM[name]], ts)
            a = np.nan_to_num(a)
            for h in range(1, M.MAX_HORIZON + 1):
                num[name][h - 1] += float(a[:-h] @ a[h:])
                den[name][h - 1] += float(a[:-h] @ a[:-h])
    return {n: [round(float(v), 6) for v in np.clip(num[n] / den[n], 0, 1)] for n in M.TARGETS}


def split_issue_mask(times: pd.Series, lo, hi) -> np.ndarray:
    return ((times >= lo) & (times + pd.Timedelta(hours=M.MAX_HORIZON) <= hi)).to_numpy()


class CellData:
    """Per-cell features computed once on the full series (past-only)."""

    def __init__(self, cid, raw, static, clim, rho):
        self.cid, self.raw, self.clim, self.rho, self.static = cid, raw, clim, rho, static
        self.features = M.issue_features(raw, static, clim)
        self.state = M.issue_state(raw, clim)
        self.y = labels(raw)
        complete = raw[list(M.WEATHER_FEATURES)].notna().all(axis=1).rolling(M.MIN_HISTORY_HOURS).sum()
        self.complete = complete.eq(M.MIN_HISTORY_HOURS).to_numpy()

    def rows(self, issues, horizons):
        x, bases = M.horizon_rows(self.features.iloc[issues].reset_index(drop=True),
                                  self.state.iloc[issues].reset_index(drop=True),
                                  self.raw.timestamp.iloc[issues].to_numpy(), horizons, self.clim, self.rho)
        return x, bases, {n: self.y[n][issues + horizons] for n in M.TARGETS}

    def rows_oof(self, issues, horizons):
        """Training rows with leave-one-year-out climatology: a row whose valid time is in train year Y
        uses tables built from the other train years, so no climatology feature contains its own label."""
        ts = self.raw.timestamp
        train = ((ts >= TRAIN_START) & (ts <= TRAIN_END)).to_numpy()
        years = ts.dt.year.to_numpy()
        valid_year = years[issues + horizons]
        x = np.empty((len(issues), len(M.feature_columns())), dtype=np.float32)
        bases = {n: {m: np.empty(len(issues)) for m in M.TARGET_MODES} for n in M.TARGETS}
        for year in np.unique(valid_year):
            clim = climatology_tables(self.raw, train & (years != year))
            features = M.issue_features(self.raw, self.static, clim)
            state = M.issue_state(self.raw, clim)
            sel = np.flatnonzero(valid_year == year)
            xi, bi = M.horizon_rows(features.iloc[issues[sel]].reset_index(drop=True),
                                    state.iloc[issues[sel]].reset_index(drop=True),
                                    ts.iloc[issues[sel]].to_numpy(), horizons[sel], clim, self.rho)
            x[sel] = xi.to_numpy(dtype=np.float32)
            for n in M.TARGETS:
                for m in M.TARGET_MODES:
                    bases[n][m][sel] = bi[n][m]
        return x, bases, {n: self.y[n][issues + horizons] for n in M.TARGETS}


def sample(cd: CellData, lo, hi, stride, k, rng, hmax=M.MAX_HORIZON):
    """k horizons per strided issue. Long (hmax=168): one from 1..24, k-1 from 1..168; short: all 1..hmax."""
    candidates = np.flatnonzero(split_issue_mask(cd.raw.timestamp, lo, hi) & cd.complete)
    issues = candidates[int(rng.integers(stride))::stride]
    if hmax < M.MAX_HORIZON:
        horizons = [rng.integers(1, hmax + 1, len(issues)) for _ in range(k)]
    else:
        horizons = [rng.integers(1, 25, len(issues))] + [rng.integers(1, M.MAX_HORIZON + 1, len(issues))
                                                         for _ in range(k - 1)]
    return np.repeat(issues, k), np.stack(horizons, axis=1).ravel().astype(np.int32)


def build_training(cdata, args, modes, start, kind):
    sets = {}
    short = kind == "short"
    hmax = M.SHORT_MAX_HORIZON if short else M.MAX_HORIZON
    for split, lo, hi, stride, k in (
            ("train", TRAIN_START, TRAIN_END, args.short_stride if short else args.train_stride,
             args.short_k if short else args.k),
            ("es", VAL_START, VAL_END, args.es_stride, 2)):
        picks = [sample(cd, lo, hi, stride, k, np.random.default_rng(
            [args.seed, i, 0 if split == "train" else 1, int(short)]), hmax) for i, cd in enumerate(cdata.values())]
        total = sum(len(h) for _, h in picks)
        # Preallocated float32 matrix: no list + concatenate copy of the largest array.
        xs = np.empty((total, len(M.feature_columns())), dtype=np.float32)
        ys = {n: np.empty(total, dtype=np.float32) for n in M.TARGETS}
        bs = {(n, m): np.empty(total, dtype=np.float32) for n in M.TARGETS for m in modes[n]}
        offset = 0
        for cd, (issues, horizons) in zip(cdata.values(), picks):
            x, bases, y = (cd.rows_oof if split == "train" else cd.rows)(issues, horizons)
            part = slice(offset, offset + len(horizons))
            xs[part] = np.asarray(x, dtype=np.float32)
            for n in M.TARGETS:
                ys[n][part] = y[n]
                for m in modes[n]:
                    bs[(n, m)][part] = bases[n][m]
            offset += len(horizons)
            del x, bases, y
            guard()
        sets[split] = (xs, ys, bs)
        log(f"{kind} {split}: {len(sets[split][0])} rows x {sets[split][0].shape[1]} features", start)
    return sets


def fit_models(sets, modes, args, start, kind):
    import lightgbm as lgb
    params = dict(num_threads=args.threads, learning_rate=args.learning_rate, num_leaves=63,
                  min_data_in_leaf=200, feature_fraction=0.8, bagging_fraction=0.8, bagging_freq=1,
                  lambda_l2=1.0, max_bin=255, verbosity=-1, seed=args.seed, deterministic=True,
                  force_col_wise=True)
    xt, yt, bt = sets["train"]
    xe, ye, be = sets["es"]
    names = M.feature_columns()
    dtrain = lgb.Dataset(xt, feature_name=names, free_raw_data=False, params={"max_bin": 255}).construct()
    models, info = {}, {}
    for name in M.TARGETS:
        for mode in modes[name]:
            binary = name == "rain_probability"
            mt, me = np.isfinite(yt[name]), np.isfinite(ye[name])
            if not mt.all() or not me.all():
                raise ValueError(f"unexpected missing labels for {name}")
            if binary:
                label_t, label_e = yt[name], ye[name]
                init_t = None if mode == "raw" else M.logit(bt[(name, mode)])
                init_e = None if mode == "raw" else M.logit(be[(name, mode)])
            else:
                label_t, label_e = yt[name] - bt[(name, mode)], ye[name] - be[(name, mode)]
                init_t = init_e = None
            dtrain.set_label(label_t)
            dtrain.set_init_score(init_t)
            dval = lgb.Dataset(xe, label=label_e, init_score=init_e, reference=dtrain, feature_name=names)
            t0 = time.monotonic()
            model = lgb.train({**params, "objective": OBJECTIVE[name], "metric": METRIC.get(name, "mae")},
                              dtrain, num_boost_round=args.max_rounds, valid_sets=[dval],
                              callbacks=[lgb.early_stopping(args.patience, verbose=False),
                                         lambda env: guard()])
            models[(name, mode, kind)] = model
            info[(name, mode, kind)] = {"best_iteration": int(model.best_iteration),
                                        "seconds": round(time.monotonic() - t0, 1)}
            log(f"{kind} {name}/{mode}: best_iteration={model.best_iteration} "
                f"({info[(name, mode, kind)]['seconds']}s)", start)
            del dval
    return models, info, params


def eval_grid(cdata, models, stride, lo, hi, args, start, v3=True):
    """All 168 horizons for strided issues of every cell; returns column arrays."""
    import ai_model as A
    if v3 and not A._load_v3():
        raise RuntimeError(f"V3 unavailable: {A._v3.get('error')}")
    v1_meta, v1_models = M1._load(*M1.artifact_revision())
    cols3 = A.feature_columns_v3() if v3 else None
    store = {}

    def put(key, value):
        store.setdefault(key, []).append(np.asarray(value))

    for ci, cd in enumerate(cdata.values()):
        candidates = np.flatnonzero(split_issue_mask(cd.raw.timestamp, lo, hi) & cd.complete)
        issues = candidates[::stride]
        n_iss = len(issues)
        hs = np.tile(np.arange(1, M.MAX_HORIZON + 1, dtype=np.int32), n_iss)
        rep = np.repeat(issues, M.MAX_HORIZON)
        x, bases, y = cd.rows(rep, hs)
        valid_ts = cd.raw.timestamp.iloc[rep + hs]
        put("h", hs)
        put("cell", np.full(len(hs), ci, dtype=np.int16))
        put("issue_time", cd.raw.timestamp.iloc[rep].to_numpy().astype("datetime64[h]").astype(np.int64))
        for name in M.TARGETS:
            put(f"y_{name}", y[name].astype(np.float32))
            put(f"pers_{name}", cd.y[name][rep].astype(np.float32))
            put(f"clim_{name}", clim_step(cd.clim[M.TARGET_CLIM[name]], valid_ts).astype(np.float32))
            put(f"damped_{name}", M.bounded(name, bases[name]["damped"]).astype(np.float32))
            for (target, mode, kind), model in models.items():
                if target != name:
                    continue
                pred = np.full(len(hs), np.nan, dtype=np.float32)
                m = hs <= (M.SHORT_MAX_HORIZON if kind == "short" else M.MAX_HORIZON)
                pred[m] = M.model_output(name, mode, model, x[m], bases[name][mode][m], num_threads=args.threads)
                put(f"v2{kind}{mode}_{name}", pred)
        # v1 on identical rows (its own feature code on the same reindexed series).
        f1 = M1.issue_features(cd.raw, v1_meta["cell_static"][cd.cid])
        x1 = M1.horizon_features(f1.iloc[rep], cd.raw.timestamp.iloc[rep], hs)
        for name, model in v1_models.items():
            put(f"v1_{name}", M1.bounded(name, model.predict(x1, num_threads=args.threads)).astype(np.float32))
        if v3:
            x3 = A.build_features_v3(cd.raw, A._v3["static"][A.canonical_cell_id(cd.cid)])[cols3]
            x3 = x3.iloc[issues].to_numpy(dtype=np.float32)
            ok = np.isfinite(x3).all(axis=1)
            for name in V3_TARGETS:
                arr = np.full(len(hs), np.nan, dtype=np.float32)
                for h in V3_HORIZONS:
                    k = f"{h}h"
                    if name == "temperature" or name == "rain_probability":
                        t, p = A.postprocess_v3([cd.cid] * n_iss, h, A._v3["models"][f"temp_{k}"].predict(x3, num_threads=args.threads),
                                                A._v3["models"][f"rain_{k}"].predict(x3, num_threads=args.threads), x3)
                        val = np.round(t, 2) if name == "temperature" else np.round(np.clip(p, 0, 1), 4)
                    else:
                        lower, upper = A._EXT_BOUNDS[name]
                        val = np.clip(A._v3["ext"]["models"][f"{name}_{k}"].predict(x3, num_threads=args.threads), lower,
                                      upper if upper is not None else np.inf)
                        val = np.round(val, V3_TARGETS[name])
                    arr[np.arange(n_iss) * M.MAX_HORIZON + h - 1] = np.where(ok, val, np.nan)
                put(f"v3_{name}", arr)
        guard()
        if ci % 10 == 0:
            log(f"eval cell {ci + 1}/{len(cdata)}: {n_iss} issues", start)
    return {k: np.concatenate(v) for k, v in store.items()}


def metric_values(y, p, binary):
    e = p - y
    if binary:
        q = np.clip(p, 1e-7, 1 - 1e-7)
        return {"brier": float(np.mean(e ** 2)),
                "log_loss": float(-np.mean(y * np.log(q) + (1 - y) * np.log(1 - q)))}
    return {"mae": float(np.mean(np.abs(e))), "rmse": float(np.sqrt(np.mean(e ** 2)))}


def group(grid, name, model_key, mask, extra=()):
    binary = name == "rain_probability"
    primary = PRIMARY.get(name, "mae")
    y = grid[f"y_{name}"].astype(float)
    cols = {"model": model_key, "persistence": f"pers_{name}", "climatology": f"clim_{name}", **dict(extra)}
    valid = mask & np.isfinite(y)
    for col in cols.values():
        valid &= np.isfinite(grid[col])
    if not valid.any():
        return {"n": 0}
    scores = {label: metric_values(y[valid], grid[col][valid].astype(float), binary) for label, col in cols.items()}
    return {"n": int(valid.sum()), **scores,
            "beats_both_baselines": scores["model"][primary] < min(scores["persistence"][primary],
                                                                    scores["climatology"][primary])}


def per_horizon_primary(grid, name, key, mask=None):
    """Primary metric per horizon 1..168 (vectorised)."""
    y = grid[f"y_{name}"].astype(float)
    p = grid[key].astype(float)
    ok = np.isfinite(y) & np.isfinite(p) & (True if mask is None else mask)
    h = grid["h"][ok]
    e = p[ok] - y[ok]
    n = np.bincount(h, minlength=M.MAX_HORIZON + 1)[1:]
    with np.errstate(invalid="ignore", divide="ignore"):
        if PRIMARY.get(name, "mae") == "mae":
            return np.bincount(h, np.abs(e), minlength=M.MAX_HORIZON + 1)[1:] / np.where(n > 0, n, np.nan)
        s = np.bincount(h, e ** 2, minlength=M.MAX_HORIZON + 1)[1:] / np.where(n > 0, n, np.nan)
    return np.sqrt(s) if PRIMARY[name] == "rmse" else s


def primary_score(name, y, p):
    e = M.bounded(name, p) - y
    primary = PRIMARY.get(name, "mae")
    return (float(np.mean(np.abs(e))) if primary == "mae" else
            float(np.sqrt(np.mean(e ** 2))) if primary == "rmse" else float(np.mean(e ** 2)))


def weight_scores(name, y, a, b):
    """Primary metric of w*b + (1-w)*a for w in 0, 0.1, ..., 1."""
    return {float(w): primary_score(name, y, w * b + (1 - w) * a) for w in np.round(np.arange(0, 1.01, 0.1), 1)}


def fit_policy(grid, model_version):
    """Validation-only blend policy. Step 1: weight of the short booster vs the long booster for
    h=1..24 (argmin). Step 2: weight of V3 at 1/3/6h on top, kept only if gain >= POLICY_MIN_GAIN."""
    policy = {"model_version": model_version, "selected_on": "validation",
              "rule": {"short_weight": "w*short + (1-w)*long for h<=24, w in 0..1 step 0.1, argmin primary metric",
                       "v3_weight": f"w*V3 + (1-w)*v2 at 1/3/6h, w in 0..1 step 0.1, kept only if gain >= "
                                    f"{POLICY_MIN_GAIN:.0%} vs v2 at that horizon; V3 failure serves v2"},
              "targets": {}, "diagnostics": {}}
    h = grid["h"]
    for name in M.TARGETS:
        rule = policy["targets"][name] = {"short_weight": {}, "v3_weight": {}}
        y = grid[f"y_{name}"].astype(float)
        long_, short = grid[f"v2long_{name}"].astype(float), grid[f"v2short_{name}"].astype(float)
        for i in range(1, M.SHORT_MAX_HORIZON + 1):
            m = h == i
            scores = weight_scores(name, y[m], long_[m], short[m])
            best = min(scores, key=scores.get)
            rule["short_weight"][f"{i}h"] = best
            policy["diagnostics"][f"{name}_short_{i}h"] = {"long": scores[0.0], "short": scores[1.0],
                                                          "best_weight": best, "best": scores[best]}
        blended(grid, name, rule)
        if name not in V3_TARGETS:
            continue
        v2, v3 = grid[f"v2_{name}"].astype(float), grid[f"v3_{name}"].astype(float)
        for i in V3_HORIZONS:
            m = (h == i) & np.isfinite(v3)
            scores = weight_scores(name, y[m], v2[m], v3[m])
            best = min(scores, key=scores.get)
            gain = 1 - scores[best] / scores[0.0]
            policy["diagnostics"][f"{name}_v3_{i}h"] = {"n": int(m.sum()), "v2": scores[0.0], "v3": scores[1.0],
                                                       "best_weight": best, "best": scores[best],
                                                       "relative_gain": round(gain, 5)}
            if best > 0 and gain >= POLICY_MIN_GAIN:
                rule["v3_weight"][f"{i}h"] = best
    return policy


def blended(grid, name, rule):
    """v2 output = long booster, blended with the short booster at h<=24."""
    out = grid[f"v2long_{name}"].astype(float).copy()
    for key, w in rule["short_weight"].items():
        m = grid["h"] == int(key.rstrip("h"))
        out[m] = w * grid[f"v2short_{name}"][m] + (1 - w) * out[m]
    grid[f"v2_{name}"] = M.bounded(name, out).astype(np.float32)


def served(grid, policy):
    for name in M.TARGETS:
        rule = policy["targets"][name]
        blended(grid, name, rule)
        out = grid[f"v2_{name}"].astype(float).copy()
        for key, w in rule["v3_weight"].items():
            m = (grid["h"] == int(key.rstrip("h"))) & np.isfinite(grid[f"v3_{name}"])
            out[m] = w * grid[f"v3_{name}"][m] + (1 - w) * out[m]
        grid[f"served_{name}"] = M.bounded(name, out).astype(np.float32)


def evaluation_report(grid, cell_ids, mask_name=None):
    report = {}
    cells = grid["cell"]
    for name in M.TARGETS:
        extra = (("v2_unblended", f"v2_{name}"), ("v1", f"v1_{name}"))
        h = grid["h"]
        everything = np.ones(len(h), dtype=bool)
        entry = {"primary_metric": PRIMARY.get(name, "mae"),
                 "overall": group(grid, name, f"served_{name}", everything, extra),
                 "by_horizon": {str(i): group(grid, name, f"served_{name}", h == i, extra)
                                for i in range(1, M.MAX_HORIZON + 1)},
                 "by_day": {str(i): group(grid, name, f"served_{name}", (h > (i - 1) * 24) & (h <= i * 24), extra)
                            for i in range(1, 8)},
                 "by_cell": {cid: group(grid, name, f"served_{name}", cells == ci, extra)
                             for ci, cid in enumerate(cell_ids)}}
        if name in V3_TARGETS:
            entry["v3_horizons"] = {str(i): group(grid, name, f"served_{name}", (h == i) & np.isfinite(
                grid[f"v3_{name}"]), (*extra, ("v3", f"v3_{name}"))) for i in V3_HORIZONS}
        entry["useful_horizon_hours"] = useful_horizon(entry["by_horizon"])
        report[name] = entry
    return report


def useful_horizon(by_horizon):
    beats = [int(h) for h, g in by_horizon.items() if g.get("beats_both_baselines")]
    first_fail = next((int(h) for h, g in by_horizon.items() if g.get("n") and not g["beats_both_baselines"]), None)
    return {"last_beating_both": max(beats) if beats else 0, "horizons_beating_both": len(beats),
            "first_not_beating": first_fail}


def summary_table(grid, label, keys):
    rows = []
    for name in M.TARGETS:
        cols = {k: per_horizon_primary(grid, name, f"{k}_{name}") for k in keys if f"{k}_{name}" in grid}
        for h in KEY_HORIZONS:
            rows.append({"target": name, "h": h, **{k: round(float(v[h - 1]), 4) for k, v in cols.items()}})
        rows.append({"target": name, "h": "mean", **{k: round(float(np.nanmean(v)), 4) for k, v in cols.items()}})
    table = pd.DataFrame(rows)
    print(f"\n== {label} (primary metric: MAE; precip RMSE; rain Brier) ==")
    print(table.to_string(index=False), flush=True)
    return table


def code_hashes():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (Path(__file__).resolve(), BACKEND / "long_range_model_v2.py")}


def parity_check(out, cdata, grid, cell_ids, n_samples, seed):
    """Saved artifacts + serving code reproduce the trainer's served validation values."""
    meta, models, climate, policy = M._load(str(out.resolve()), (out / "metadata.json").stat().st_mtime_ns)
    rng = np.random.default_rng(seed)
    starts = np.flatnonzero(grid["h"] == 1)
    worst = {}
    fallbacks = 0
    for row in rng.choice(starts, n_samples, replace=False):
        cid = cell_ids[int(grid["cell"][row])]
        cd = cdata[cid]
        issue = pd.Timestamp(np.datetime64(int(grid["issue_time"][row]), "h"))
        idx = int(np.flatnonzero(cd.raw.timestamp.to_numpy() == issue.to_datetime64())[0])
        hist = M._prepare(cd.raw.iloc[idx - M.MIN_HISTORY_HOURS + 1: idx + 1], cid)
        values, fb = M.forecast_arrays(hist, cid, meta, models, climate, policy)
        fallbacks += bool(fb)
        for name, v in values.items():
            diff = float(np.max(np.abs(v - grid[f"served_{name}"][row:row + M.MAX_HORIZON])))
            worst[name] = max(worst.get(name, 0.0), diff)
    return {"samples": n_samples, "max_abs_diff": worst, "issues_with_v3_fallback": fallbacks}


def score_test(args, cdata, cell_ids, start):
    """Score TEST once with the saved artifacts (no refit, no selection) and add it to evaluation.json."""
    out = args.out
    meta, loaded, climate, policy = M._load(str(out.resolve()), (out / "metadata.json").stat().st_mtime_ns)
    for cid in cell_ids:  # the DB snapshot must reproduce the saved train-period climatology
        saved, now = climate["cells"][cid], cdata[cid].clim
        if any(not np.allclose(saved[k], now[k], atol=1e-5) for k in M.CLIM_KEYS) or not all(
                np.allclose(climate["rho"][n], cdata[cid].rho[n], atol=1e-5) for n in M.TARGETS):
            raise ValueError(f"train-period data changed since training (cell {cid}); refusing to score test")
    models = {(name, mode, kind): booster for name, pair in loaded.items() for kind, (mode, booster) in pair.items()}
    chosen = {kind: {name: pair[kind][0] for name, pair in loaded.items()} for kind in ("long", "short")}
    test = eval_grid(cdata, models, args.test_stride, TEST_START, TEST_END, args, start)
    for name in M.TARGETS:
        for kind in ("long", "short"):
            test[f"v2{kind}_{name}"] = test.pop(f"v2{kind}{chosen[kind][name]}_{name}")
    served(test, policy)
    test_report = evaluation_report(test, cell_ids)
    clean = test["issue_time"] >= V3_CLEAN_START.to_datetime64().astype("datetime64[h]").astype(np.int64)
    for name in V3_TARGETS:
        test_report[name]["v3_horizons_clean_since_2025_10_01"] = {
            str(i): group(test, name, f"served_{name}", clean & (test["h"] == i) & np.isfinite(test[f"v3_{name}"]),
                          (("v2_unblended", f"v2_{name}"), ("v3", f"v3_{name}"))) for i in V3_HORIZONS}
    summary_table(test, "TEST (scored once)", ["pers", "clim", "damped", "v1", "v3", "v2long", "v2short",
                                               "v2", "served"])
    report = json.loads((out / "evaluation.json").read_text(encoding="utf-8"))
    for name in M.TARGETS:
        report[name]["test"] = test_report[name]
    (out / "evaluation.json").write_text(json.dumps(report, indent=1, allow_nan=False), encoding="utf-8")
    meta = json.loads((out / "metadata.json").read_text(encoding="utf-8"))
    meta["test_scoring"] = {"scored_at": datetime.now(timezone.utc).isoformat(),
                            "issue_stride_hours": args.test_stride,
                            "elapsed_seconds": round(time.monotonic() - start, 1),
                            "peak_rss_mib": round(rss_mib(), 1), "num_threads": args.threads}
    (out / "metadata.json").write_text(json.dumps(meta, indent=2, allow_nan=False), encoding="utf-8")
    log(f"test scored once and added to {out / 'evaluation.json'}", start)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=BACKEND / "data/history/cells_history.db")
    parser.add_argument("--out", type=Path, default=M.DEFAULT_MODEL_DIR)
    parser.add_argument("--phase", choices=("dev", "final", "test"), required=True)
    parser.add_argument("--modes", default="", help="final: name=mode,... (chosen in dev)")
    parser.add_argument("--short-modes", default="", help="final: name=mode,... for the 1..24h booster")
    parser.add_argument("--dev-kinds", default="long,short", help="dev: boosters to compare")
    parser.add_argument("--short-stride", type=int, default=3)
    parser.add_argument("--short-k", type=int, default=3)
    parser.add_argument("--train-stride", type=int, default=3)
    parser.add_argument("--k", type=int, default=4)
    parser.add_argument("--es-stride", type=int, default=5)
    parser.add_argument("--val-stride", type=int, default=13)
    parser.add_argument("--test-stride", type=int, default=23)
    parser.add_argument("--learning-rate", type=float, default=0.05)
    parser.add_argument("--max-rounds", type=int, default=4000)
    parser.add_argument("--patience", type=int, default=100)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--cells", type=int, default=0, help="debug: first N cells only")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    if not 1 <= args.threads <= 4:
        parser.error("num_threads must be 1..4")
    if args.phase == "final" and args.out.exists():
        parser.error(f"output exists; choose a new --out: {args.out}")
    if args.phase == "test":
        report = json.loads((args.out / "evaluation.json").read_text(encoding="utf-8"))
        if any("test" in entry for entry in report.values()):
            parser.error("test was already scored for this artifact; it is scored exactly once")
    start = time.monotonic()
    cells, statics, snapshot = load_cells(args, start)
    climate = {cid: climatology_tables(raw, ((raw.timestamp >= TRAIN_START) & (raw.timestamp <= TRAIN_END))
                                       .to_numpy()) for cid, raw in cells.items()}
    rho = damping(cells, climate)
    log("climatology + damping ready: rho(1,24,168)=" + str({n: (r[0], r[23], r[167]) for n, r in rho.items()}),
        start)
    cdata = {cid: CellData(cid, raw, statics[cid], climate[cid], rho) for cid, raw in cells.items()}
    del cells
    cell_ids = list(cdata)
    log("features ready", start)
    if args.phase == "test":
        score_test(args, cdata, cell_ids, start)
        return
    kinds = ("long", "short") if args.phase == "final" else tuple(args.dev_kinds.split(","))
    modes = {}
    for kind, spec in (("long", args.modes), ("short", args.short_modes)):
        if args.phase == "dev":
            modes[kind] = {n: list(M.TARGET_MODES) for n in M.TARGETS}
            continue
        chosen = dict(item.split("=") for item in spec.split(",") if item)
        if set(chosen) != set(M.TARGETS) or not set(chosen.values()) <= set(M.TARGET_MODES):
            parser.error(f"--{kind} modes must give one of raw/anomaly/damped for every target")
        modes[kind] = {n: [chosen[n]] for n in M.TARGETS}
    models, info, sample_rows = {}, {}, {}
    for kind in kinds:
        sets = build_training(cdata, args, modes[kind], start, kind)
        sample_rows[kind] = {s: int(len(v[0])) for s, v in sets.items()}
        fitted, fit_info, params = fit_models(sets, modes[kind], args, start, kind)
        models.update(fitted)
        info.update(fit_info)
        del sets, fitted
    grid = eval_grid(cdata, models, args.val_stride, VAL_START, VAL_END, args, start)
    if args.phase == "dev":
        keys = ["pers", "clim", "damped", "v1", "v3"] + [f"v2{k}{m}" for k in kinds for m in M.TARGET_MODES]
        summary_table(grid, "VALIDATION dev comparison", keys)
        log("dev done (no artifacts, no test)", start)
        return
    chosen = {kind: {n: modes[kind][n][0] for n in M.TARGETS} for kind in kinds}

    def rename(g):
        for name in M.TARGETS:
            for kind in kinds:
                g[f"v2{kind}_{name}"] = g.pop(f"v2{kind}{chosen[kind][name]}_{name}")

    rename(grid)
    version = f"lgbm-direct-168h-v2-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"
    policy = fit_policy(grid, version)
    served(grid, policy)
    val_report = evaluation_report(grid, cell_ids)
    summary_table(grid, "VALIDATION final", ["pers", "clim", "damped", "v1", "v3", "v2long", "v2short", "v2",
                                             "served"])
    capabilities = {n: {"status": "available", "horizons": [1, 168],
                        "rows": {k: sample_rows[k]["train"] for k in kinds},
                        "best_iteration": {k: info[(n, chosen[k][n], k)]["best_iteration"] for k in kinds},
                        "target_mode": {k: chosen[k][n] for k in kinds}} for n in M.TARGETS}
    fit_through = TRAIN_END
    known = VAL_END
    meta = {"schema_version": M.SCHEMA_VERSION, "model_version": version, "source": "ai",
            "trained_at": datetime.now(timezone.utc).isoformat(), "trained_through": M.local_iso(known),
            "fit_labels_through": M.local_iso(fit_through), "selection_labels_through": M.local_iso(known),
            "max_horizon_hours": M.MAX_HORIZON, "min_history_hours": M.MIN_HISTORY_HOURS,
            "feature_columns": M.feature_columns(), "cell_static": statics,
            "target_mode": chosen["long"], "capabilities": capabilities,
            "short_range": {"max_horizon_hours": M.SHORT_MAX_HORIZON, "target_mode": chosen["short"]},
            "data_snapshot": snapshot, "data": str(args.db.resolve()), "data_timezone": M.TIMEZONE,
            "units": {"temperature": "celsius", "humidity": "%", "precipitation_mm": "mm/hour",
                      "wind_speed": "km/h", "cloud_cover": "%", "rain_probability": "0..1"},
            "rain_threshold_mm": M.RAIN_THRESHOLD_MM, "limitations": LIMITATIONS,
            "split": {"train": [str(TRAIN_START), str(TRAIN_END)], "validation": [str(VAL_START), str(VAL_END)],
                      "test": [str(TEST_START), str(TEST_END)], "gap_hours": 168,
                      "rule": "issue and issue+168h inside split; climatology/damping from train only; "
                              "early stopping, mode and policy selection on validation; test scored once",
                      "sample_rows": sample_rows},
            "sampling": {"train_long": f"every {args.train_stride}h issue (random offset per cell), {args.k} "
                                       "horizons per issue: one from 1..24, the rest from 1..168",
                         "train_short": f"every {args.short_stride}h issue, {args.short_k} horizons from 1..24",
                         "early_stopping": f"validation issues every {args.es_stride}h, 2 horizons per issue "
                                           "(1..168 long, 1..24 short)",
                         "validation_eval": f"validation issues every {args.val_stride}h, all 168 horizons",
                         "test_eval": f"test issues every {args.test_stride}h, all 168 horizons",
                         "seed": args.seed},
            "params": params, "max_rounds": args.max_rounds, "early_stopping_rounds": args.patience,
            "fit_seconds": {f"{n}_{k}": info[(n, chosen[k][n], k)]["seconds"] for n in M.TARGETS for k in kinds},
            "serving_policy_file": "serving_policy.json", "climatology_file": "climatology.json",
            "serving_inputs": "last 48 contiguous hourly rows of the cell (temperature, humidity, precipitation, "
                              "wind_speed, cloud_cover, pressure_msl); V3 blend horizons also need the V3 input "
                              "columns and models/v3, otherwise v2 alone is served for those hours",
            "code_sha256": code_hashes()}
    out = args.out
    out.mkdir(parents=True)
    for name in M.TARGETS:
        models[(name, chosen["long"][name], "long")].save_model(str(out / f"{name}.txt"))
        models[(name, chosen["short"][name], "short")].save_model(str(out / f"{name}_short.txt"))
    (out / "climatology.json").write_text(json.dumps({"model_version": version, "source": "train period "
                                                      f"{TRAIN_START}..{TRAIN_END}", "cells": climate, "rho": rho}),
                                          encoding="utf-8")
    (out / "serving_policy.json").write_text(json.dumps(policy, indent=2), encoding="utf-8")
    (out / "metadata.json").write_text(json.dumps(meta, indent=2, allow_nan=False), encoding="utf-8")
    parity = parity_check(out, cdata, grid, cell_ids, 24, args.seed)
    log(f"parity: {parity}", start)
    report = {n: {"validation": val_report[n]} for n in M.TARGETS}
    del grid
    meta["parity"] = parity
    meta["resources"] = {"elapsed_seconds": round(time.monotonic() - start, 1), "peak_rss_mib": round(rss_mib(), 1),
                         "num_threads": args.threads}
    (out / "evaluation.json").write_text(json.dumps(report, indent=1, allow_nan=False), encoding="utf-8")
    (out / "metadata.json").write_text(json.dumps(meta, indent=2, allow_nan=False), encoding="utf-8")
    log(f"artifact ready: {out}", start)


if __name__ == "__main__":
    main()
