"""Train/evaluate long-range v2.1 (v2 features + validation-fitted serving layers), Colab-ready.

Outer protocol = v2: train 2021-01-01 (or 2017-01-01 if the dev comparison adopts it) .. 2024-06-30,
validation 2024-07-08..2024-12-24, test 2025-01-01..2026-10-16, issue and issue+168h inside a split.
Validation is split into two roles with a 168h purge:
  VAL_FIT  issue >= 2024-07-08, issue+168h <= 2024-10-06 23:00  early stopping, target mode, train start
  VAL_CAL  issue >= 2024-10-14, issue+168h <= 2024-12-24 23:00  taper, V3 blend, rain calibrator,
                                                                  conformal quantiles, serve gates
Climatology, std, Q10/Q90 and damping tables use train labels only; training rows use
leave-one-year-out (LOYO) climatology AND LOYO rho (valid-time year excluded).

  --phase dev     VAL_FIT comparison of modes x kinds (+ train start 2021 vs 2017) -> dev_selection.json
  --phase final   --selection dev_selection.json: boosters + VAL_CAL serving layers -> artifact,
                  test_spec.json, parity_cases.json, spatial_folds.json, MANIFEST.sha256 (no test)
  --phase spatial leave-spatial-blocks-out long boosters (fixed rounds) into --spatial-dir
  --phase test    score TEST exactly once (global write-once ledger + test_spec hash check)
  --phase verify  (or --verify-artifacts DIR) local check of a returned artifact: manifest, ledger,
                  versions, parity against the local DB (read-only) and one predict per cell

--data is either the SQLite DB (opened ?mode=ro) or an exported directory (export_colab_data.py).
No downloads/uploads. Threads 1..4 unless --colab. RSS guard 10 GiB. Outputs never overwritten.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import subprocess
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
import long_range_model_v21 as S  # noqa: E402
import train_long_range_v2 as T2  # noqa: E402
from train_long_range import connect, rss_mib  # noqa: E402

PROGRAM = "long_range_v21"
TRAIN_START = pd.Timestamp("2021-01-01")
TRAIN_START_EXT = pd.Timestamp("2017-01-01")
TRAIN_END = pd.Timestamp("2024-06-30 23:00")
VAL_START = pd.Timestamp("2024-07-08")
VAL_END = pd.Timestamp("2024-12-24 23:00")
VAL_FIT = (pd.Timestamp("2024-07-08"), pd.Timestamp("2024-10-06 23:00"))
VAL_CAL = (pd.Timestamp("2024-10-14"), pd.Timestamp("2024-12-24 23:00"))
TEST_START = pd.Timestamp("2025-01-01")
TEST_END = pd.Timestamp("2026-10-16 23:00")
V3_CLEAN_START = pd.Timestamp("2025-10-01")
V3_KNOWLEDGE_END = S.V3_KNOWLEDGE_END
V3_HORIZONS = S.V3_ANCHORS
V3_TARGETS = T2.V3_TARGETS
DATA_COLUMNS = tuple(M.WEATHER_FEATURES) + tuple(T2.V3_COLUMNS)
WARMUP = pd.Timedelta(hours=M.MIN_HISTORY_HOURS)
RSS_LIMIT_MIB = 10240
CON_DAO = "om-8.6819-106.5892"
BUFFER_DEG = 0.12
BOOT_B, BLOCK_DAYS, SEED = 1000, 7, 42
TAPER_GRID = {"w0": (0.5, 0.75, 1.0), "a": (12, 15, 18, 19, 21, 24), "b": (24, 27, 30, 33, 36)}
V3_GRID = (0.0, 0.25, 0.5, 0.75, 1.0)
ROUGHNESS_SHARE = 0.002  # lambda: typical roughness (J = median J(10..48) of long-only) costs 0.2 % of the metric
CAL_MIN_GAIN = 0.005
INTERVAL_GATE = 0.03
NOMINAL = {name: (0.9 if name in S.UPPER_ONLY else 0.8) for name in S.INTERVAL_TARGETS}
STD_FLOOR = {"temperature": 0.05, "humidity": 0.5, "wind_speed": 0.1, "cloud_cover": 1.0, "precipitation_mm": 0.01}
PRIMARY = T2.PRIMARY
BASELINES = {"climatology": "clim", "persistence": "pers", "diurnal_persistence": "dpers",
             "damped_anomaly": "damped", "diurnal_damped": "ddamped"}
CODE_FILES = ("scripts/train_long_range_v21.py", "long_range_model_v21.py", "long_range_model_v2.py",
              "scripts/train_long_range_v2.py", "long_range_model.py", "scripts/train_long_range.py", "ai_model.py")
LIMITATIONS = [
    "Experimental direct-horizon model; validation-selected, not superior at every horizon/cell.",
    "Labels are historical weather-model output (Open-Meteo), not station observations: emulation skill only.",
    "The DB has no issue-vintage timestamps: temporal hindcast is not an operational skill claim.",
    "Inputs are the last 48 hourly rows of the cell plus train-period climatology; no NWP inputs.",
    "Rain probability is calibrated per horizon band only where the validation gate passed; Brier is not accuracy.",
    "p10/p90 are 80 % split-conformal intervals fitted on Oct-Dec 2024; 80 % coverage is not 80 % accuracy, "
    "dry-season coverage may differ.",
    "Spatial generalisation was tested by leave-blocks-out on the same grid; cells still need their own history.",
    "Rain calibrator and conformal quantiles were fitted on V3-blended 1..9h values (VAL_CAL); test issues up to "
    "2025-09-23 serve v2.1 alone at 1..9h, so test 1..9h calibration/coverage is also reported per V3 window.",
    "V3's own val_select window (2024-10-01..2025-09-23) contains VAL_CAL, so V3's VAL_CAL skill (and the V3 "
    "blend weights) is slightly optimistic.",
]
_START = time.monotonic()


# ----------------------------------------------------------------------------------------- utilities
def log(msg):
    print(f"[{time.monotonic() - _START:7.1f}s RSS={rss_mib():.0f}MiB] {msg}", flush=True)


def guard():
    if rss_mib() > RSS_LIMIT_MIB:
        raise MemoryError(f"RSS exceeded {RSS_LIMIT_MIB} MiB guard")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_json(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_json(path: Path, obj, indent=1):
    path.write_text(json.dumps(obj, indent=indent, allow_nan=False, default=_json_default), encoding="utf-8")


def _json_default(o):
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.bool_,)):
        return bool(o)
    if isinstance(o, (pd.Timestamp,)):
        return str(o)
    raise TypeError(type(o))


def fin(x, nd=6):
    """JSON-safe rounded float (None for NaN/inf)."""
    x = float(x)
    return round(x, nd) if math.isfinite(x) else None


def hours(ts) -> int:
    return int(pd.Timestamp(ts).to_datetime64().astype("datetime64[h]").astype(np.int64))


def code_hashes() -> dict:
    return {rel: sha256_file(BACKEND / rel) for rel in CODE_FILES if (BACKEND / rel).exists()}


def library_versions() -> dict:
    import joblib
    import lightgbm
    import sklearn
    out = {"python": platform.python_version(), "lightgbm": lightgbm.__version__, "numpy": np.__version__,
           "pandas": pd.__version__, "scikit-learn": sklearn.__version__, "joblib": joblib.__version__,
           "platform": platform.platform()}
    try:
        freeze = subprocess.run([sys.executable, "-m", "pip", "freeze"], capture_output=True, text=True,
                                timeout=120).stdout
        out["pip_freeze_sha256"] = hashlib.sha256(freeze.encode()).hexdigest()
    except Exception as exc:  # noqa: BLE001 - provenance only
        out["pip_freeze_sha256"] = f"unavailable: {type(exc).__name__}"
    return out


class Tee:
    """Copy stdout to a log file (train_log.txt)."""

    def __init__(self, path: Path):
        self.file = open(path, "a", encoding="utf-8")
        self.stdout = sys.stdout
        sys.stdout = self

    def write(self, text):
        self.stdout.write(text)
        self.file.write(text)

    def flush(self):
        self.stdout.flush()
        self.file.flush()

    def close(self):
        sys.stdout = self.stdout
        self.file.close()


# ------------------------------------------------------------------------------------------ data I/O
def _frame(ts, columns: dict) -> pd.DataFrame:
    frame = pd.DataFrame({"timestamp": ts})
    for c in DATA_COLUMNS:
        frame[c] = columns[c]
    return frame


def load_sqlite(db: Path, lo, hi, cell_ids):
    with connect(db) as con:
        static = {r[0]: dict(zip(M.STATIC_FEATURES, r[1:])) for r in
                  con.execute("SELECT cell_id,lat,lon,elevation FROM cells")}
        sources = dict(con.execute("SELECT cell_id,source FROM cells"))
        coverage = pd.read_sql_query("SELECT cell_id, MIN(timestamp) AS first_hour, MAX(timestamp) AS last_hour, "
                                     "COUNT(*) AS rows FROM hourly GROUP BY cell_id", con)
        ids = cell_ids(sorted(coverage.cell_id))
        columns = ",".join(f'"{c}"' for c in DATA_COLUMNS)
        frames = {}
        index = pd.date_range(lo, hi, freq="h")
        for cid in ids:
            raw = pd.read_sql_query(f"SELECT timestamp,{columns} FROM hourly WHERE cell_id=? AND timestamp>=? "
                                    "AND timestamp<=? ORDER BY timestamp", con, params=(cid, str(lo), str(hi)))
            raw["timestamp"] = M.timestamps(raw.timestamp).to_numpy()
            if raw.timestamp.duplicated().any():
                raise ValueError(f"duplicate timestamps: {cid}")
            raw = raw.set_index("timestamp").reindex(index)
            frames[cid] = _frame(index, {c: raw[c].to_numpy(dtype=float) for c in DATA_COLUMNS})
    snapshot = {r.cell_id: {"first_hour": r.first_hour, "last_hour": r.last_hour, "rows": int(r.rows),
                            "source": sources[r.cell_id]} for r in coverage.itertuples() if r.cell_id in frames}
    return frames, {c: static[c] for c in frames}, snapshot, {"kind": "sqlite", "path": str(db.resolve())}


def decode_npz(npz) -> dict:
    """{column: float64 array} from an exported npz (int16 x10 with -32768 = NaN, or float64 fallback)."""
    out = {}
    for c in DATA_COLUMNS:
        a = npz[c]
        if a.dtype == np.int16:
            v = a.astype(np.float64)
            v[a == np.iinfo(np.int16).min] = np.nan
            out[c] = v / 10.0
        else:
            out[c] = a.astype(np.float64)
    return out


def load_npz_dir(data: Path, lo, hi, cell_ids):
    manifest_path = data / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    cells = json.loads((data / "cells.json").read_text(encoding="utf-8"))
    ids = cell_ids(sorted(c["cell_id"] for c in cells))
    index = pd.date_range(lo, hi, freq="h")
    frames = {}
    for cid in ids:
        entry = manifest["files"][f"hourly_{cid}.npz"]
        path = data / f"hourly_{cid}.npz"
        if sha256_file(path) != entry["sha256"]:
            raise ValueError(f"sha256 mismatch for {path.name}; re-upload the export")
        with np.load(path, allow_pickle=False) as npz:
            start = pd.Timestamp(str(npz["start"]))
            cols = decode_npz(npz)
        n = len(cols[DATA_COLUMNS[0]])
        offset = int((lo - start) / pd.Timedelta(hours=1))
        out = {}
        for c, v in cols.items():
            full = np.full(len(index), np.nan)
            src_lo, src_hi = max(offset, 0), min(offset + len(index), n)
            if src_hi > src_lo:
                full[src_lo - offset:src_hi - offset] = v[src_lo:src_hi]
            out[c] = full
        frames[cid] = _frame(index, out)
    by_id = {c["cell_id"]: c for c in cells}
    static = {cid: {k: float(by_id[cid][k]) for k in M.STATIC_FEATURES} for cid in frames}
    snapshot = {cid: {k: by_id[cid][k] for k in ("first_hour", "last_hour", "rows", "source")} for cid in frames}
    return frames, static, snapshot, {"kind": "npz", "path": str(data.resolve()),
                                      "manifest_sha256": sha256_file(manifest_path)}


def load_frames(data: Path, lo, hi, cells: int = 0, cell_ids: str = ""):
    """Contiguous hourly frames [lo, hi] per cell (NaN where the DB has no row); identical for both sources."""
    wanted = [c for c in cell_ids.split(",") if c]

    def pick(ids):
        if wanted:
            missing = set(wanted) - set(ids)
            if missing:
                raise ValueError(f"unknown cells: {sorted(missing)}")
            return sorted(wanted)
        return ids[:cells] if cells else ids

    loader = load_npz_dir if data.is_dir() else load_sqlite
    frames, static, snapshot, info = loader(data, lo, hi, pick)
    info["canonical_sha256"] = canonical_sha(frames)
    log(f"loaded {len(frames)} cells from {info['kind']} [{lo}..{hi}]")
    return frames, static, snapshot, info


def canonical_sha(frames: dict) -> str:
    h = hashlib.sha256()
    for cid in sorted(frames):
        f = frames[cid]
        h.update(cid.encode())
        h.update(f.timestamp.to_numpy().astype("datetime64[s]").astype(np.int64).tobytes())
        for c in DATA_COLUMNS:
            v = f[c].to_numpy(dtype=np.float64)
            nan = np.isnan(v)
            h.update(np.where(nan, 0.0, v).tobytes())
            h.update(np.packbits(nan).tobytes())
    return h.hexdigest()


def year_audit(frames: dict, lo, hi) -> dict:
    """Pooled per-year mean/std/NaN of every variable and leave-one-year-out shift z-scores."""
    rows = {}
    for c in DATA_COLUMNS:
        parts = []
        for f in frames.values():
            m = ((f.timestamp >= lo) & (f.timestamp <= hi)).to_numpy()
            parts.append(pd.DataFrame({"y": f.timestamp.dt.year.to_numpy()[m], "v": f[c].to_numpy()[m]}))
        d = pd.concat(parts)
        g = d.groupby("y").v
        stats = pd.DataFrame({"mean": g.mean(), "std": g.std(), "nan": g.apply(lambda s: int(s.isna().sum()))})
        z = {}
        for y in stats.index:
            others = stats["mean"].drop(y)
            sd = others.std()
            z[int(y)] = fin(abs(stats.loc[y, "mean"] - others.mean()) / sd if sd > 0 else 0.0, 3)
        rows[c] = {int(y): {"mean": fin(r["mean"], 4), "std": fin(r["std"], 4), "nan": int(r["nan"]),
                            "loo_shift_z": z[int(y)]} for y, r in stats.iterrows()}
    return rows


# --------------------------------------------------------------------------------- tables and damping
def train_mask(ts: pd.Series, lo, hi=TRAIN_END) -> np.ndarray:
    return ((ts >= lo) & (ts <= hi)).to_numpy()


def std_tables(raw: pd.DataFrame, clim: dict, mask: np.ndarray) -> dict:
    """Train-period std of the target anomaly per (month, hour), floored (conformal scale)."""
    y = T2.labels(raw)
    ts = raw.timestamp[mask]
    out = {}
    for name in S.INTERVAL_TARGETS:
        a = y[name][mask] - M.clim_values(clim[M.TARGET_CLIM[name]], ts)
        frame = pd.DataFrame({"m": ts.dt.month.to_numpy(), "h": ts.dt.hour.to_numpy(), "a": a})
        table = frame.groupby(["m", "h"]).a.std().reindex(
            pd.MultiIndex.from_product([range(1, 13), range(24)])).to_numpy()
        table = np.where(np.isfinite(table), np.maximum(table, STD_FLOOR[name]), STD_FLOOR[name])
        out[name] = [round(float(v), 6) for v in table]
    return out


def quantile_tables(raw: pd.DataFrame, mask: np.ndarray) -> dict:
    """Climatological Q10/Q90 of each interval target per (month, hour) from train labels (baseline interval)."""
    y = T2.labels(raw)
    ts = raw.timestamp[mask]
    out = {}
    for name in S.INTERVAL_TARGETS:
        frame = pd.DataFrame({"m": ts.dt.month.to_numpy(), "h": ts.dt.hour.to_numpy(), "y": y[name][mask]})
        g = frame.groupby(["m", "h"]).y
        idx = pd.MultiIndex.from_product([range(1, 13), range(24)])
        out[name] = (g.quantile(0.1).reindex(idx).to_numpy(), g.quantile(0.9).reindex(idx).to_numpy())
    return out


def damping_core(frames: dict, climate: dict, lo, hi=TRAIN_END, exclude_year=None) -> dict:
    """rho(h) = sum a_t a_{t+h} / sum a_t^2 over train anomalies pooled over cells (v2 damping()).
    exclude_year: labels of that year count as missing (anomaly 0), i.e. pairs need t, t+h outside it."""
    num = {n: np.zeros(M.MAX_HORIZON) for n in M.TARGETS}
    den = {n: np.zeros(M.MAX_HORIZON) for n in M.TARGETS}
    for cid, raw in frames.items():
        mask = train_mask(raw.timestamp, lo, hi)
        ts = raw.timestamp[mask]
        y = T2.labels(raw)
        drop = (ts.dt.year == exclude_year).to_numpy() if exclude_year is not None else None
        for name in M.TARGETS:
            a = y[name][mask] - M.clim_values(climate[cid][M.TARGET_CLIM[name]], ts)
            if drop is not None:
                a[drop] = np.nan
            a = np.nan_to_num(a)
            for h in range(1, M.MAX_HORIZON + 1):
                num[name][h - 1] += float(a[:-h] @ a[h:])
                den[name][h - 1] += float(a[:-h] @ a[:-h])
    return {n: [round(float(v), 6) for v in np.clip(num[n] / den[n], 0, 1)] for n in M.TARGETS}


def build_tables(frames: dict, lo, with_loyo=True):
    """Train-window climatology, std and Q10/Q90 tables, full-train rho and LOYO climatology + rho."""
    clim, std, qtab, loyo_clim = {}, {}, {}, {}
    years = None
    for cid, raw in frames.items():
        mask = train_mask(raw.timestamp, lo)
        clim[cid] = T2.climatology_tables(raw, mask)
        std[cid] = std_tables(raw, clim[cid], mask)
        qtab[cid] = quantile_tables(raw, mask)
        yrs = raw.timestamp.dt.year.to_numpy()
        years = sorted(set(yrs[mask].tolist()))
        if with_loyo:
            loyo_clim[cid] = {y: T2.climatology_tables(raw, mask & (yrs != y)) for y in years}
    rho = damping_core(frames, clim, lo)
    loyo_rho = {}
    if with_loyo:
        for y in years:
            loyo_rho[y] = damping_core(frames, {cid: loyo_clim[cid][y] for cid in frames}, lo, exclude_year=y)
    summary = {n: fin(max((np.max(np.abs(np.asarray(loyo_rho[y][n]) - np.asarray(rho[n]))) for y in loyo_rho),
                          default=0.0)) for n in M.TARGETS}
    log(f"tables ready (train from {lo}); rho(1,24,168)=" +
        str({n: (r[0], r[23], r[167]) for n, r in rho.items()}))
    return {"clim": clim, "std": std, "qtab": qtab, "rho": rho, "loyo_clim": loyo_clim, "loyo_rho": loyo_rho,
            "rho_loyo_max_abs_diff": summary, "train_years": years}


class CellData21:
    """Per-cell features on the full series (past-only, full-train tables); LOYO rows for training."""

    def __init__(self, cid, raw, static, tables, lo):
        self.cid, self.raw, self.static, self.lo = cid, raw, static, lo
        self.clim, self.rho = tables["clim"][cid], tables["rho"]
        self.std, self.qtab = tables["std"][cid], tables["qtab"][cid]
        self.loyo_clim = tables["loyo_clim"].get(cid, {})
        self.loyo_rho = tables["loyo_rho"]
        self.features = S.stable_issue_features(raw, static, self.clim)
        self.state = M.issue_state(raw, self.clim)
        self.y = T2.labels(raw)
        complete = raw[list(M.WEATHER_FEATURES)].notna().all(axis=1).rolling(M.MIN_HISTORY_HOURS).sum()
        self.complete = complete.eq(M.MIN_HISTORY_HOURS).to_numpy()

    def rows(self, issues, horizons):
        x, bases = M.horizon_rows(self.features.iloc[issues].reset_index(drop=True),
                                  self.state.iloc[issues].reset_index(drop=True),
                                  self.raw.timestamp.iloc[issues].to_numpy(), horizons, self.clim, self.rho)
        return x, bases, {n: self.y[n][issues + horizons] for n in M.TARGETS}

    def rows_oof(self, issues, horizons):
        """Training rows: a row whose valid time is in train year Y uses climatology AND rho built
        without year Y, so neither clim_valid_*, *_anom nor base_* contain the row's own label."""
        ts = self.raw.timestamp
        valid_year = ts.dt.year.to_numpy()[issues + horizons]
        x = np.empty((len(issues), len(M.feature_columns())), dtype=np.float32)
        bases = {n: {m: np.empty(len(issues)) for m in M.TARGET_MODES} for n in M.TARGETS}
        for year in np.unique(valid_year):
            clim, rho = self.loyo_clim[int(year)], self.loyo_rho[int(year)]
            features = S.stable_issue_features(self.raw, self.static, clim)
            state = M.issue_state(self.raw, clim)
            sel = np.flatnonzero(valid_year == year)
            xi, bi = M.horizon_rows(features.iloc[issues[sel]].reset_index(drop=True),
                                    state.iloc[issues[sel]].reset_index(drop=True),
                                    ts.iloc[issues[sel]].to_numpy(), horizons[sel], clim, rho)
            x[sel] = xi.to_numpy(dtype=np.float32)
            for n in M.TARGETS:
                for m in M.TARGET_MODES:
                    bases[n][m][sel] = bi[n][m]
        return x, bases, {n: self.y[n][issues + horizons] for n in M.TARGETS}


def fold_damping(cdata, tables, cells, lo) -> tuple[dict, dict]:
    """rho(h) and LOYO rho(h) pooled over `cells` only (spatial folds: held-out/buffer labels excluded)."""
    cells = sorted(cells)
    frames = {c: cdata[c].raw for c in cells}
    rho = damping_core(frames, {c: tables["clim"][c] for c in cells}, lo)
    loyo = {y: damping_core(frames, {c: tables["loyo_clim"][c][y] for c in cells}, lo, exclude_year=y)
            for y in tables["loyo_rho"]}
    return rho, loyo


def set_rho(cdata, rho, loyo_rho):
    for cd in cdata.values():
        cd.rho, cd.loyo_rho = rho, loyo_rho


SPATIAL_SELECTION_NOTE = ("fold boosters: training rows, rho(h) and LOYO rho(h) from the fold's train cells only; "
                          "each held-out cell keeps its own train-period climatology (needs its own history); "
                          "boosting rounds (final best_iteration, early-stopped on VAL_FIT of ALL cells) and "
                          "target modes (selected in dev on ALL cells) are reused, i.e. selected on all cells")


def make_cdata(frames, statics, tables, lo):
    out = {cid: CellData21(cid, raw, statics[cid], tables, lo) for cid, raw in frames.items()}
    log("features ready")
    return out


# ---------------------------------------------------------------------------------- splits/sampling
def issue_window(ts: pd.Series, lo, hi) -> np.ndarray:
    return T2.split_issue_mask(ts, lo, hi)


def build_training(cdata, args, modes, kind, train_lo, cells=None, with_es=True):
    """Train rows (LOYO) from train_lo..TRAIN_END and early-stopping rows from VAL_FIT."""
    short = kind == "short"
    hmax = S.SHORT_MAX_HORIZON if short else M.MAX_HORIZON
    order = {cid: i for i, cid in enumerate(sorted(cdata))}
    use = [cid for cid in cdata if cells is None or cid in cells]
    splits = [("train", train_lo, TRAIN_END, args.short_stride if short else args.train_stride,
               args.short_k if short else args.k)]
    if with_es:
        splits.append(("es", VAL_FIT[0], VAL_FIT[1], args.es_stride, 2))
    sets = {}
    for si, (split, lo, hi, stride, k) in enumerate(splits):
        picks = [T2.sample(cdata[cid], lo, hi, stride, k, np.random.default_rng([args.seed, order[cid], si,
                                                                                 int(short)]), hmax) for cid in use]
        total = sum(len(h) for _, h in picks)
        xs = np.empty((total, len(M.feature_columns())), dtype=np.float32)
        ys = {n: np.empty(total, dtype=np.float32) for n in M.TARGETS}
        bs = {(n, m): np.empty(total, dtype=np.float32) for n in M.TARGETS for m in modes[n]}
        offset = 0
        for cid, (issues, horizons) in zip(use, picks):
            cd = cdata[cid]
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
        log(f"{kind} {split}: {total} rows x {xs.shape[1]} features")
    return sets


def fit_boosters(sets, modes, args, kind, rounds=None):
    """LightGBM text boosters per target x mode; early stopping on VAL_FIT unless fixed `rounds`."""
    import lightgbm as lgb
    params = dict(num_threads=args.threads, learning_rate=args.learning_rate, num_leaves=63,
                  min_data_in_leaf=args.min_data_in_leaf, feature_fraction=0.8, bagging_fraction=0.8,
                  bagging_freq=1, lambda_l2=1.0, max_bin=255, verbosity=-1, seed=args.seed, deterministic=True,
                  force_col_wise=True)
    xt, yt, bt = sets["train"]
    names = M.feature_columns()
    dtrain = lgb.Dataset(xt, feature_name=names, free_raw_data=False, params={"max_bin": 255}).construct()
    models, info = {}, {}
    for name in M.TARGETS:
        for mode in modes[name]:
            binary = name == "rain_probability"

            def label_init(y, b):
                if binary:
                    return y[name], (None if mode == "raw" else M.logit(b[(name, mode)]))
                return y[name] - b[(name, mode)], None
            label_t, init_t = label_init(yt, bt)
            if not np.isfinite(yt[name]).all():
                raise ValueError(f"unexpected missing labels for {name}")
            dtrain.set_label(label_t)
            dtrain.set_init_score(init_t)
            t0 = time.monotonic()
            p = {**params, "objective": T2.OBJECTIVE[name], "metric": T2.METRIC.get(name, "mae")}
            r = rounds[(name, mode)] if rounds else None
            if r is not None:
                model = lgb.train(p, dtrain, num_boost_round=max(int(r), 1), callbacks=[lambda env: guard()])
                best = max(int(r), 1)
            else:
                xe, ye, be = sets["es"]
                if not np.isfinite(ye[name]).all():
                    raise ValueError(f"unexpected missing ES labels for {name}")
                label_e, init_e = label_init(ye, be)
                dval = lgb.Dataset(xe, label=label_e, init_score=init_e, reference=dtrain, feature_name=names)
                model = lgb.train(p, dtrain, num_boost_round=args.max_rounds, valid_sets=[dval],
                                  callbacks=[lgb.early_stopping(args.patience, verbose=False),
                                             lambda env: guard()])
                best = int(model.best_iteration) or args.max_rounds
                del dval
            models[(name, mode, kind)] = model
            info[(name, mode, kind)] = {"best_iteration": best, "seconds": round(time.monotonic() - t0, 1)}
            log(f"{kind} {name}/{mode}: iterations={best} ({info[(name, mode, kind)]['seconds']}s)")
    return models, info, params


# ------------------------------------------------------------------------------------- evaluation grid
class Comparators:
    """Incumbent models scored on identical rows: v1, v2 (served, with its own policy) and V3."""

    def __init__(self, wanted, args):
        self.notes = {}
        self.v1 = self.v2 = None
        self.v3 = False
        self.threads = args.threads
        if "v3" in wanted:
            import ai_model as A
            self.A = A
            self.v3 = bool(A._load_v3())
            if not self.v3:
                if not args.allow_missing_v3:
                    raise RuntimeError(f"V3 unavailable: {A._v3.get('error')} (use --allow-missing-v3 to skip)")
                self.notes["v3"] = f"unavailable: {A._v3.get('error')}"
            else:
                self.cols3 = A.feature_columns_v3()
        if "v1" in wanted:
            try:
                self.v1 = M1._load(*M1.artifact_revision())
            except Exception as exc:  # noqa: BLE001 - comparator only
                self.notes["v1"] = f"unavailable: {exc}"
        if "v2" in wanted:
            try:
                path = M.DEFAULT_MODEL_DIR
                self.v2 = M._load(str(path.resolve()), (path / "metadata.json").stat().st_mtime_ns)
            except Exception as exc:  # noqa: BLE001 - comparator only
                self.notes["v2"] = f"unavailable: {exc}"

    def v3_anchor(self, cd, issues):
        """{target: n_issues x 3 array} of V3 values at 1/3/6h (NaN where V3 cannot answer)."""
        A = self.A
        n = len(issues)
        out = {name: np.full((n, len(V3_HORIZONS)), np.nan) for name in V3_TARGETS}
        cid = A.canonical_cell_id(cd.cid)
        if not self.v3 or cid not in A._v3["static"]:
            return out
        x3 = A.build_features_v3(cd.raw, A._v3["static"][cid])[self.cols3].iloc[issues].to_numpy(dtype=np.float32)
        ok = np.isfinite(x3).all(axis=1)
        if not ok.any():
            return out
        t = self.threads
        for j, h in enumerate(V3_HORIZONS):
            k = f"{h}h"
            temp, prob = A.postprocess_v3([cd.cid] * n, h, A._v3["models"][f"temp_{k}"].predict(x3, num_threads=t),
                                          A._v3["models"][f"rain_{k}"].predict(x3, num_threads=t), x3)
            for name in V3_TARGETS:
                if name == "temperature":
                    val = np.round(temp, 2)
                elif name == "rain_probability":
                    val = np.round(np.clip(prob, 0, 1), 4)
                else:
                    ext = A._v3.get("ext") or {}
                    model = (ext.get("models") or {}).get(f"{name}_{k}")
                    if model is None or name not in ext.get("enabled", []):
                        continue
                    lower, upper = A._EXT_BOUNDS[name]
                    val = np.round(np.clip(model.predict(x3, num_threads=t), lower,
                                           upper if upper is not None else np.inf), V3_TARGETS[name])
                out[name][:, j] = np.where(ok, val, np.nan)
        return out

    def v2_served(self, cd, rep, hs, v3a):
        """Incumbent v2 served values (its own climatology, short blend and V3 policy) on the grid rows."""
        meta, models, climate, policy = self.v2
        if cd.cid not in climate["cells"]:
            return {}
        clim2 = climate["cells"][cd.cid]
        f2 = M.issue_features(cd.raw, meta["cell_static"][cd.cid], clim2)
        s2 = M.issue_state(cd.raw, clim2)
        x2, b2 = M.horizon_rows(f2.iloc[rep].reset_index(drop=True), s2.iloc[rep].reset_index(drop=True),
                                cd.raw.timestamp.iloc[rep].to_numpy(), hs, clim2, climate["rho"])
        out = {}
        for name, pair in models.items():
            mode, model = pair["long"]
            v = M.model_output(name, mode, model, x2, b2[name][mode], num_threads=self.threads)
            rule = policy["targets"].get(name) or {}
            if "short" in pair:
                mode, model = pair["short"]
                m = hs <= M.SHORT_MAX_HORIZON
                short = M.model_output(name, mode, model, x2[m], b2[name][mode][m], num_threads=self.threads)
                w = np.zeros(M.SHORT_MAX_HORIZON + 1)
                for key, weight in rule.get("short_weight", {}).items():
                    w[int(key.rstrip("h"))] = float(weight)
                v[m] = w[hs[m]] * short + (1 - w[hs[m]]) * v[m]
            v = M.bounded(name, v)
            if name in v3a:
                n = len(hs) // M.MAX_HORIZON
                v = v.reshape(n, M.MAX_HORIZON)
                for key, weight in rule.get("v3_weight", {}).items():
                    h = int(key.rstrip("h"))
                    a = v3a[name][:, V3_HORIZONS.index(h)]
                    ok = np.isfinite(a)
                    v[ok, h - 1] = float(weight) * a[ok] + (1 - float(weight)) * v[ok, h - 1]
                v = M.bounded(name, v.ravel())
            out[name] = v
        return out


def eval_grid(cdata, models, stride, lo, hi, args, comparators: Comparators | None = None, fold_models=None):
    """All 168 horizons for strided issues of every cell (rows issue-major, h = 1..168)."""
    store = {}

    def put(key, value):
        store.setdefault(key, []).append(np.asarray(value))

    order = sorted(cdata)
    for ci, cid in enumerate(order):
        cd = cdata[cid]
        candidates = np.flatnonzero(issue_window(cd.raw.timestamp, lo, hi) & cd.complete)
        issues = candidates[::stride]
        n_iss = len(issues)
        if not n_iss:
            continue
        hs = np.tile(np.arange(1, M.MAX_HORIZON + 1, dtype=np.int32), n_iss)
        rep = np.repeat(issues, M.MAX_HORIZON)
        x, bases, y = cd.rows(rep, hs)
        fold_x = fold_bases = None
        if fold_models is not None and cid in fold_models:
            fold_boosters, fold_rho = fold_models[cid]
            fold_x, fold_bases = M.horizon_rows(cd.features.iloc[rep].reset_index(drop=True),
                                                cd.state.iloc[rep].reset_index(drop=True),
                                                cd.raw.timestamp.iloc[rep].to_numpy(), hs, cd.clim, fold_rho)
        ts = cd.raw.timestamp
        valid_ts = pd.DatetimeIndex(ts.iloc[rep + hs].to_numpy())
        dh = hs - 24 * np.ceil(hs / 24).astype(np.int32)  # <= 0: same clock hour, last observed day
        put("h", hs)
        put("cell", np.full(len(hs), ci, dtype=np.int16))
        put("issue_time", ts.iloc[rep].to_numpy().astype("datetime64[h]").astype(np.int64))
        put("month", valid_ts.month.to_numpy().astype(np.int8))
        for name in M.TARGETS:
            key = M.TARGET_CLIM[name]
            clim_valid = M.clim_values(cd.clim[key], valid_ts)
            anom = cd.state[f"anom_{name}"].to_numpy()
            coef = np.asarray(cd.rho[name])[hs - 1]
            put(f"y_{name}", y[name].astype(np.float32))
            put(f"pers_{name}", cd.y[name][rep].astype(np.float32))
            put(f"dpers_{name}", cd.y[name][rep + dh].astype(np.float32))
            put(f"clim_{name}", M.bounded(name, clim_valid).astype(np.float32))
            put(f"damped_{name}", M.bounded(name, bases[name]["damped"]).astype(np.float32))
            put(f"ddamped_{name}", M.bounded(name, clim_valid + coef * anom[rep + dh]).astype(np.float32))
            if name in S.INTERVAL_TARGETS:
                put(f"std_{name}", M.clim_values(cd.std[name], valid_ts))
                q10, q90 = cd.qtab[name]
                idx = (valid_ts.month.to_numpy() - 1) * 24 + valid_ts.hour.to_numpy()
                put(f"cq10_{name}", q10[idx].astype(np.float32))
                put(f"cq90_{name}", q90[idx].astype(np.float32))
            for (target, mode, kind), model in models.items():
                if target != name:
                    continue
                pred = np.full(len(hs), np.nan, dtype=np.float32)
                m = hs <= (S.SHORT_MAX_HORIZON if kind == "short" else M.MAX_HORIZON)
                pred[m] = M.model_output(name, mode, model, x[m], bases[name][mode][m], num_threads=args.threads)
                put(f"v21{kind}{mode}_{name}", pred)
            if fold_models is not None:
                pred = np.full(len(hs), np.nan, dtype=np.float32)
                if fold_x is not None and name in fold_boosters:
                    mode, model = fold_boosters[name]
                    pred[:] = M.model_output(name, mode, model, fold_x, fold_bases[name][mode],
                                             num_threads=args.threads)
                put(f"fold_{name}", pred)
        if comparators is not None:
            v3a = comparators.v3_anchor(cd, issues) if "v3" not in comparators.notes and comparators.v3 else {}
            for name in V3_TARGETS:
                arr = np.full((n_iss, M.MAX_HORIZON), np.nan, dtype=np.float32)
                if name in v3a:
                    for j, h in enumerate(V3_HORIZONS):
                        arr[:, h - 1] = v3a[name][:, j]
                put(f"v3_{name}", arr.ravel())
            if comparators.v1 is not None:
                v1_meta, v1_models = comparators.v1
                ok = cid in v1_meta["cell_static"]
                if ok:
                    f1 = M1.issue_features(cd.raw, v1_meta["cell_static"][cid])
                    x1 = M1.horizon_features(f1.iloc[rep], ts.iloc[rep], hs)
                for name in M.TARGETS:
                    v = (M1.bounded(name, v1_models[name].predict(x1, num_threads=args.threads))
                         if ok and name in v1_models else np.full(len(hs), np.nan))
                    put(f"v1_{name}", np.asarray(v, dtype=np.float32))
            if comparators.v2 is not None:
                inc = comparators.v2_served(cd, rep, hs, v3a)
                for name in M.TARGETS:
                    put(f"v2_{name}", np.asarray(inc.get(name, np.full(len(hs), np.nan)), dtype=np.float32))
        del x, bases
        guard()
        if ci % 10 == 0:
            log(f"eval cell {ci + 1}/{len(cdata)}: {n_iss} issues")
    grid = {k: np.concatenate(v) for k, v in store.items()}
    grid["cell_ids"] = order
    return grid


def n_issues(grid) -> int:
    return len(grid["h"]) // M.MAX_HORIZON


def as2d(grid, key) -> np.ndarray:
    return grid[key].astype(float).reshape(n_issues(grid), M.MAX_HORIZON)


def v3_anchor_2d(grid, name):
    if f"v3_{name}" not in grid:
        return None
    v = as2d(grid, f"v3_{name}")
    return np.stack([v[:, h - 1] for h in V3_HORIZONS], axis=1)


def apply_policy_grid(grid, policy, calibration, use_window: bool, gated: bool = True):
    """Served columns with the SAME functions as serving (long_range_model_v21)."""
    issue = as2d(grid, "issue_time")[:, 0]
    window = issue <= hours(V3_KNOWLEDGE_END) if use_window else np.zeros(len(issue), dtype=bool)
    for name in M.TARGETS:
        rule = policy["targets"].get(name) or {}
        long_ = as2d(grid, f"v21long_{name}")
        short = as2d(grid, f"v21short_{name}") if f"v21short_{name}" in grid else None
        v21, blend = S.serve_values(name, long_, short, v3_anchor_2d(grid, name), rule)
        served = np.where(window[:, None], v21, blend)
        grid[f"v21_{name}"] = v21.ravel().astype(np.float32)
        grid[f"blend_{name}"] = blend.ravel().astype(np.float32)
        grid[f"served_{name}"] = served.ravel().astype(np.float32)
    raw = as2d(grid, "served_rain_probability")
    grid["rawrain_rain_probability"] = raw.ravel().astype(np.float32)
    grid["served_rain_probability"] = S.calibrate_rain(raw, calibration, policy.get("serve_calibrated_rain") or {}
                                                       ).ravel().astype(np.float32)
    seasons = S.season_of(grid["month"])
    for name in S.INTERVAL_TARGETS:
        rule = (policy.get("intervals") or {}).get(name)
        scale = np.ones(len(grid["h"])) if not rule or rule["method"] == "unnormalized" else grid[f"std_{name}"]
        lo, hi = S.interval_bounds(name, grid[f"served_{name}"].astype(float), scale, grid["h"], seasons, rule,
                                   gated=gated)
        grid[f"p10_{name}"], grid[f"p90_{name}"] = lo, hi


def rename_chosen(grid, chosen: dict):
    for kind, modes in chosen.items():
        for name, mode in modes.items():
            key = f"v21{kind}{mode}_{name}"
            if key in grid:
                grid[f"v21{kind}_{name}"] = grid.pop(key)


# ------------------------------------------------------------------------------------- metrics + CIs
def primary_of(name) -> str:
    return PRIMARY.get(name, "mae")


def loss(name, y, p, metric=None):
    """Per-row loss whose mean gives the metric (rmse: squared error, sqrt applied after averaging)."""
    metric = metric or primary_of(name)
    e = np.asarray(p, float) - np.asarray(y, float)
    return np.abs(e) if metric == "mae" else e ** 2


def finish(metric, mean):
    return np.sqrt(mean) if metric == "rmse" else mean


def block_bootstrap(day, columns, B=BOOT_B, block=BLOCK_DAYS, seed=SEED):
    """Moving-block bootstrap over issue days (all cells of a day stay together).
    Returns (point means [k], replicate means [B, k]) of each column; paired across columns."""
    day = np.asarray(day, dtype=np.int64)
    idx = day - day.min()
    D = int(idx.max()) + 1
    N = np.bincount(idx, minlength=D).astype(float)
    sums = [np.bincount(idx, np.asarray(c, float), minlength=D) for c in columns]
    L = min(block, D)
    nb = int(math.ceil(D / L))
    starts = np.random.default_rng(seed).integers(0, D - L + 1, size=(B, nb))

    def totals(v):
        c = np.concatenate([[0.0], np.cumsum(v)])
        return (c[starts + L] - c[starts]).sum(axis=1)
    tn = totals(N)
    tn = np.where(tn > 0, tn, np.nan)
    point = np.array([s.sum() / N.sum() for s in sums])
    reps = np.stack([totals(s) / tn for s in sums], axis=1)
    return point, reps


def delta_ci(day, la, lb, metric, B=BOOT_B, seed=SEED):
    """Paired difference metric(a) - metric(b) with a percentile 95 % CI."""
    point, reps = block_bootstrap(day, [la, lb], B=B, seed=seed)
    d = finish(metric, reps[:, 0]) - finish(metric, reps[:, 1])
    lo, hi = np.nanpercentile(d, [2.5, 97.5])
    return {"delta": fin(finish(metric, point[0]) - finish(metric, point[1])), "ci95": [fin(lo), fin(hi)],
            "significant": bool(hi < 0)}


def metric_block(name, y, p):
    return T2.metric_values(y, p, name == "rain_probability")


def issue_day(grid):
    return grid["issue_time"] // 24


def group21(grid, name, model_col, mask, extra=()):
    """v2-compatible group: model, climatology, persistence (+ extra baselines and comparators)."""
    y = grid[f"y_{name}"].astype(float)
    cols = {"model": model_col, **{label: f"{p}_{name}" for label, p in BASELINES.items()}}
    valid = mask & np.isfinite(y)
    for col in cols.values():
        valid &= np.isfinite(grid[col])
    if not valid.any():
        return {"n": 0}
    extras = {label: col for label, col in extra if col in grid and np.isfinite(grid[col][valid]).all()}
    cols.update(extras)
    primary = primary_of(name)
    scores = {label: metric_block(name, y[valid], grid[col][valid].astype(float)) for label, col in cols.items()}
    best = min(BASELINES, key=lambda b: scores[b][primary])
    return {"n": int(valid.sum()), **scores, "best_baseline": best,
            "beats_both_baselines": bool(scores["model"][primary] < scores[best][primary]),
            "beats_persistence_and_climatology": bool(scores["model"][primary] < min(
                scores["persistence"][primary], scores["climatology"][primary]))}


def band_report(grid, name, model_col, mask, comparators, B=BOOT_B):
    """Per band: n, metrics, delta + CI vs every comparator, skill vs best baseline, significant flag."""
    y = grid[f"y_{name}"].astype(float)
    day = issue_day(grid)
    primary = primary_of(name)
    metrics = [primary] + (["mae"] if name == "precipitation_mm" else [])
    out = {}
    for band, (a, b) in S.BANDS.items():
        rows = mask & (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(y) & np.isfinite(grid[model_col])
        for p in BASELINES.values():
            rows &= np.isfinite(grid[f"{p}_{name}"])
        if not rows.any():
            out[band] = {"n": 0}
            continue
        comps = {label: f"{p}_{name}" for label, p in BASELINES.items()}
        comps.update({label: col for label, col in comparators if col in grid and np.isfinite(grid[col][rows]).all()})
        yy, dd = y[rows], day[rows]
        pm = grid[model_col][rows].astype(float)
        entry = {"n": int(rows.sum()), "model": metric_block(name, yy, pm)}
        for label, col in comps.items():
            pc = grid[col][rows].astype(float)
            entry[label] = metric_block(name, yy, pc)
        best = min(BASELINES, key=lambda k: entry[k][primary])
        entry["best_baseline"] = best
        entry["skill_vs_best_baseline"] = fin(1 - entry["model"][primary] / entry[best][primary]) \
            if entry[best][primary] > 0 else None
        entry["delta"] = {}
        for label, col in {**comps, "best_baseline": comps[best]}.items():
            pc = grid[col][rows].astype(float)
            entry["delta"][label] = {m: delta_ci(dd, loss(name, yy, pm, m), loss(name, yy, pc, m), m, B=B)
                                     for m in metrics}
        entry["significant"] = entry["delta"]["best_baseline"][primary]["significant"]
        entry["beats_both_baselines"] = bool(entry["model"][primary] < entry[best][primary])
        out[band] = entry
    return out


def evaluation_report(grid, model_prefix="served", comparators=(), B=BOOT_B, mask=None):
    report = {}
    cells = grid["cell"]
    h = grid["h"]
    base = np.ones(len(h), dtype=bool) if mask is None else mask
    for name in M.TARGETS:
        col = f"{model_prefix}_{name}"
        extra = [("v21_unblended", f"v21_{name}"), ("v21_long_only", f"v21long_{name}"),
                 ("v1", f"v1_{name}"), ("v2", f"v2_{name}")] + list(comparators)
        if name == "rain_probability":
            extra.append(("uncalibrated", "rawrain_rain_probability"))
        entry = {"primary_metric": primary_of(name),
                 "overall": group21(grid, name, col, base, extra),
                 "by_horizon": {str(i): group21(grid, name, col, base & (h == i), extra)
                                for i in range(1, M.MAX_HORIZON + 1)},
                 "by_day": {str(i): group21(grid, name, col, base & (h > (i - 1) * 24) & (h <= i * 24), extra)
                            for i in range(1, 8)},
                 "by_cell": {cid: group21(grid, name, col, base & (cells == ci), extra)
                             for ci, cid in enumerate(grid["cell_ids"])},
                 "by_band": band_report(grid, name, col, base, [x for x in extra if x[0] in ("v1", "v2")], B=B)}
        if name in V3_TARGETS and f"v3_{name}" in grid:
            entry["v3_horizons"] = {str(i): group21(grid, name, col, base & (h == i) & np.isfinite(grid[f"v3_{name}"]),
                                                    (*extra, ("v3", f"v3_{name}"))) for i in V3_HORIZONS}
        entry["useful_horizon_hours"] = T2.useful_horizon(entry["by_horizon"])
        report[name] = entry
    return report


def per_horizon_metric(name, y2d, p2d) -> np.ndarray:
    """Primary metric per horizon (columns) of n x H arrays; NaN rows ignored."""
    e = p2d - y2d
    ok = np.isfinite(e)
    n = ok.sum(axis=0)
    m = primary_of(name)
    with np.errstate(invalid="ignore", divide="ignore"):
        if m == "mae":
            return np.where(ok, np.abs(e), 0).sum(axis=0) / n
        s = np.where(ok, e ** 2, 0).sum(axis=0) / n
    return np.sqrt(s) if m == "rmse" else s


def jump_curve(v2d) -> np.ndarray:
    """J(h) = mean |y(h) - y(h-1)| over issues, index h-1 (J(1) = NaN)."""
    d = np.abs(np.diff(v2d, axis=1))
    return np.concatenate([[np.nan], np.nanmean(d, axis=0)])


# ----------------------------------------------------------------------- VAL_CAL serving-layer fitting
PURGE_HOURS = 168


def week_fold(grid) -> np.ndarray:
    """Cross-fitting fold of each row: first / second half of the VAL_CAL issue span (contiguous blocks)."""
    issue = np.asarray(grid["issue_time"])
    mid = (int(issue.min()) + int(issue.max())) / 2.0 if len(issue) else 0.0
    return (issue > mid).astype(np.int64)


def purged_train(grid, fold, k) -> np.ndarray:
    """Fit rows for held-out fold k: other fold, minus issues within 168h of any fold-k issue
    (their 168h valid windows would overlap the held-out labels)."""
    issue = np.asarray(grid["issue_time"])
    held = np.unique(issue[fold == k])
    if not len(held):
        return fold != k
    pos = np.clip(np.searchsorted(held, issue), 1, len(held) - 1) if len(held) > 1 else np.zeros(len(issue), int)
    near = np.minimum(np.abs(issue - held[pos]), np.abs(issue - held[np.maximum(pos - 1, 0)]))
    return (fold != k) & (near >= PURGE_HOURS)


def fit_taper(grid, name):
    """3-parameter taper chosen on VAL_CAL: mean primary metric over 1..36 + lambda * mean J(h), h in [a, b]."""
    H = S.SHORT_MAX_HORIZON
    y = as2d(grid, f"y_{name}")[:, :H]
    long_ = as2d(grid, f"v21long_{name}")
    short = as2d(grid, f"v21short_{name}")
    ref_metric = float(np.nanmean(per_horizon_metric(name, y, M.bounded(name, long_[:, :H]))))
    ref_j = float(np.nanmedian(jump_curve(long_)[9:48]))
    lam = ROUGHNESS_SHARE * ref_metric / ref_j if ref_j > 0 else 0.0
    results = []
    for w0 in TAPER_GRID["w0"]:
        for a in TAPER_GRID["a"]:
            for b in TAPER_GRID["b"]:
                if b <= a:
                    continue
                taper = {"w0": w0, "a": a, "b": b}
                v = S.blend_taper(name, long_, short, taper)
                metric = float(np.nanmean(per_horizon_metric(name, y, v[:, :H])))
                j = jump_curve(v)
                rough = float(np.nanmean(j[max(a, 2) - 1:b]))
                results.append((metric + lam * rough, metric, rough, taper))
    best = min(results, key=lambda r: r[0])
    # v2-style per-horizon argmin (w in 0..1 step 0.1 per h) for the +0.5 % diagnostic.
    per_h = []
    for i in range(H):
        scores = [float(per_horizon_metric(name, y[:, [i]], M.bounded(name, w * short[:, [i]] + (1 - w) *
                                                                       long_[:, [i]]))[0])
                  for w in np.round(np.arange(0, 1.01, 0.1), 1)]
        per_h.append(min(scores))
    argmin_metric = float(np.mean(per_h))
    return best[3], {"objective": fin(best[0]), "metric_1_36": fin(best[1]), "roughness": fin(best[2]),
                     "lambda": fin(lam, 9), "long_only_metric_1_36": fin(ref_metric),
                     "per_horizon_argmin_metric_1_36": fin(argmin_metric),
                     "relative_to_argmin": fin(best[1] / argmin_metric - 1) if argmin_metric > 0 else None,
                     "within_0.5pct_of_argmin": bool(best[1] <= argmin_metric * 1.005), "grid_size": len(results)}


def fit_v3(grid, name, taper):
    """V3 anchor weights on VAL_CAL (coarse grid, block-bootstrap 90 % lower bound of relative gain > 0,
    monotone w1 >= w3 >= w6), then stitched vs anchor-only by VAL_CAL metric over 1..9h."""
    y = as2d(grid, f"y_{name}")
    v21 = S.blend_taper(name, as2d(grid, f"v21long_{name}"), as2d(grid, f"v21short_{name}"), taper)
    v3a = v3_anchor_2d(grid, name)
    day = as2d(grid, "issue_time")[:, 0] // 24
    metric = primary_of(name)
    weights, diag = {}, {}
    for j, k in enumerate(V3_HORIZONS):
        ok = np.isfinite(v3a[:, j]) & np.isfinite(y[:, k - 1])
        if ok.sum() < 10:
            weights[f"{k}h"] = 0.0
            diag[f"{k}h"] = {"n": int(ok.sum()), "reason": "too few V3 rows"}
            continue
        yy, base, v3 = y[ok, k - 1], v21[ok, k - 1], v3a[ok, j]
        scores = {w: float(finish(metric, loss(name, yy, M.bounded(name, base + w * (v3 - base)), metric).mean()))
                  for w in V3_GRID}
        w = min(scores, key=scores.get)
        point, reps = block_bootstrap(day[ok], [loss(name, yy, M.bounded(name, base + w * (v3 - base)), metric),
                                                loss(name, yy, base, metric)])
        gains = 1 - finish(metric, reps[:, 0]) / finish(metric, reps[:, 1])
        lb = float(np.nanpercentile(gains, 5))
        diag[f"{k}h"] = {"n": int(ok.sum()), "scores": {str(a): fin(b) for a, b in scores.items()},
                         "best_weight": w, "relative_gain": fin(1 - scores[w] / scores[0.0]) if scores[0.0] else None,
                         "gain_lower_90": fin(lb)}
        weights[f"{k}h"] = float(w) if w > 0 and lb > 0 else 0.0
    w1 = weights.get("1h", 0.0)
    w3 = min(weights.get("3h", 0.0), w1)
    w6 = min(weights.get("6h", 0.0), w3)
    weights = {"1h": w1, "3h": w3, "6h": w6}
    choice = {}
    for stitched in (False, True):
        c = S.v3_correction(v21, v3a, weights, stitched)
        v = M.bounded(name, v21 + c)
        m = float(np.nanmean(per_horizon_metric(name, y[:, :9], v[:, :9])))
        choice[stitched] = m
    stitched = bool(any(weights.values()) and choice[True] <= choice[False])
    return {"weights": weights, "stitched": stitched,
            "metric_1_9": {"anchor_only": fin(choice[False]), "stitched": fin(choice[True])}}, diag


def platt_fit(p, y, iters=50):
    """Logistic regression of y on [logit(p), 1] by Newton steps (no penalty); returns (a, b)."""
    z = M.logit(p)
    X = np.stack([z, np.ones_like(z)], axis=1)
    w = np.array([1.0, 0.0])
    for _ in range(iters):
        q = 1 / (1 + np.exp(-(X @ w)))
        g = X.T @ (q - y)
        Hm = X.T @ (X * (q * (1 - q))[:, None]) + 1e-9 * np.eye(2)
        step = np.linalg.solve(Hm, g)
        w -= step
        if np.max(np.abs(step)) < 1e-10:
            break
    return float(w[0]), float(w[1])


def isotonic_fit(p, y):
    from sklearn.isotonic import IsotonicRegression
    iso = IsotonicRegression(out_of_bounds="clip", y_min=S.CAL_CLIP[0], y_max=S.CAL_CLIP[1], increasing=True)
    iso.fit(np.asarray(p, float), np.asarray(y, float))
    return iso, {"method": "isotonic", "x": [float(v) for v in iso.X_thresholds_],
                 "y": [float(v) for v in iso.y_thresholds_]}


def fit_calibrator(method, p, y) -> dict:
    if method == "none":
        return {"method": "none"}
    if method == "platt":
        a, b = platt_fit(p, y)
        return {"method": "platt", "a": a, "b": b} if a > 0 else {"method": "none", "note": "non-positive slope"}
    return isotonic_fit(p, y)[1]


def ece(p, y, bins=15, equal_frequency=True) -> float:
    p, y = np.asarray(p, float), np.asarray(y, float)
    if not len(p):
        return float("nan")
    if equal_frequency:
        groups = np.array_split(np.argsort(p, kind="stable"), bins)
    else:
        k = np.minimum((p * bins).astype(int), bins - 1)
        groups = [np.flatnonzero(k == i) for i in range(bins)]
    return float(sum(len(g) / len(p) * abs(p[g].mean() - y[g].mean()) for g in groups if len(g)))


def murphy(p, y, bins=10) -> dict:
    p, y = np.asarray(p, float), np.asarray(y, float)
    k = np.minimum((p * bins).astype(int), bins - 1)
    o = y.mean()
    rel = res = 0.0
    for i in range(bins):
        g = k == i
        if g.any():
            w = g.mean()
            rel += w * (p[g].mean() - y[g].mean()) ** 2
            res += w * (y[g].mean() - o) ** 2
    return {"reliability": fin(rel), "resolution": fin(res), "uncertainty": fin(o * (1 - o))}


def fit_rain_calibration(grid, version):
    """Per band: none/Platt/isotonic chosen by purged 2-fold (contiguous halves, 168h purge) cross-fitted Brier (ECE tie-break) on VAL_CAL served
    (blended) probabilities; refit on all VAL_CAL; served only if cross-fitted Brier gain >= 0.5 %."""
    p_all = grid["served_rain_probability"].astype(float)
    y_all = grid["y_rain_probability"].astype(float)
    fold = week_fold(grid)
    bands, flags, diag = {}, {}, {}
    for band, (a, b) in S.BANDS.items():
        rows = (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(p_all) & np.isfinite(y_all)
        p, y, f, iss = p_all[rows], y_all[rows], fold[rows], np.asarray(grid["issue_time"])[rows]
        results = {}
        for method in ("none", "platt", "isotonic"):
            oof = np.empty(len(p))
            feasible = True
            for k in (0, 1):
                tr, te = purged_train({"issue_time": iss}, f, k), f == k
                if tr.sum() < 50 or te.sum() == 0 or len(np.unique(y[tr])) < 2:
                    feasible = feasible and method == "none"
                    oof[te] = p[te]
                    continue
                cal = fit_calibrator(method, p[tr], y[tr])
                if cal["method"] != method:
                    feasible = False
                oof[te] = S.calibrator_apply(p[te], cal)
            if feasible:
                results[method] = {"brier": float(np.mean((oof - y) ** 2)), "ece15": ece(oof, y)}
        order = {"none": 0, "platt": 1, "isotonic": 2}
        best = min(results, key=lambda m: (round(results[m]["brier"], 6), round(results[m]["ece15"], 6), order[m]))
        cal = fit_calibrator(best, p, y)
        gain = 1 - results[best]["brier"] / results["none"]["brier"] if results["none"]["brier"] > 0 else 0.0
        flags[band] = bool(cal["method"] != "none" and gain >= CAL_MIN_GAIN)
        bands[band] = cal
        diag[band] = {"n": int(rows.sum()), "cross_fit": {m: {k: fin(v) for k, v in r.items()}
                                                          for m, r in results.items()},
                      "chosen": cal["method"], "cross_fit_relative_brier_gain": fin(gain), "served": flags[band]}
    return {"model_version": version, "fit_window": [str(VAL_CAL[0]), str(VAL_CAL[1])],
            "rule": "per band: none/platt/isotonic by 2-fold cross-fitted Brier (alternating issue weeks, ECE "
                    "tie-break), refit on all VAL_CAL; JSON parameters evaluated with np.interp / logistic",
            "bands": bands}, flags, diag


def conformal_q(r, nominal, upper_only):
    """Finite-sample split-conformal quantiles of signed scores: q_hi rank ceil((n+1)(1-alpha_hi))."""
    r = np.sort(np.asarray(r, float))
    n = len(r)
    if upper_only:
        lo_alpha, hi_q = 0.0, nominal
    else:
        lo_alpha, hi_q = (1 - nominal) / 2, 1 - (1 - nominal) / 2
    k_hi = min(max(int(math.ceil(round((n + 1) * hi_q, 9))), 1), n)  # round: 0.1 is not exact in binary
    k_lo = min(max(int(math.floor(round((n + 1) * lo_alpha, 9))), 1), n)
    return float(r[k_lo - 1]), float(r[k_hi - 1])


def coverage(name, y, lo, hi):
    if name in S.UPPER_ONLY:
        return float(np.mean(y <= hi))
    return float(np.mean((y >= lo) & (y <= hi)))


def fit_intervals(grid, policy_targets):
    """Per target x band normalized split-conformal quantiles on VAL_CAL served values; alternatives
    (unnormalized, Mondrian by season) compared by purged 2-fold cross-fitted coverage error."""
    fold = week_fold(grid)
    fit_rows = {k: purged_train(grid, fold, k) for k in (0, 1)}
    seasons = S.season_of(grid["month"])
    out, diag = {}, {}
    for name in S.INTERVAL_TARGETS:
        y_all = grid[f"y_{name}"].astype(float)
        pred_all = grid[f"blend_{name}"].astype(float)
        nominal = NOMINAL[name]
        upper = name in S.UPPER_ONLY
        rules = {}
        for method in S.INTERVAL_METHODS:
            scale_all = np.ones(len(y_all)) if method == "unnormalized" else grid[f"std_{name}"]
            rule = {"method": method, "bands": {}}
            cv = {}
            for band, (a, b) in S.BANDS.items():
                rows = (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(y_all) & np.isfinite(pred_all)
                r = (y_all - pred_all) / scale_all
                groups = {"all": rows}
                if method == "mondrian_season":
                    groups.update({s: rows & (seasons == s) for s in ("dry", "wet")})

                def quantiles(sel):
                    q = {}
                    for g, gm in groups.items():
                        m = gm & sel
                        if m.sum() >= 20:
                            q[g] = conformal_q(r[m], nominal, upper)
                    return q
                full = quantiles(np.ones(len(r), dtype=bool))
                entry = {"q_lo": full["all"][0], "q_hi": full["all"][1], "n": int(rows.sum())}
                if method == "mondrian_season":
                    entry["by_season"] = {s: {"q_lo": q[0], "q_hi": q[1]} for s, q in full.items() if s != "all"}
                # cross-fitted coverage: quantiles from the purged other half, coverage on this half
                hits = []
                for k in (0, 1):
                    q = quantiles(fit_rows[k])
                    if "all" not in q:
                        continue
                    tmp = {"method": method, "bands": {band: {"q_lo": q["all"][0], "q_hi": q["all"][1], "served": True,
                                                              "by_season": {s: {"q_lo": v[0], "q_hi": v[1]}
                                                                            for s, v in q.items() if s != "all"}}}}
                    te = rows & (fold == k)
                    lo, hi = S.interval_bounds(name, pred_all[te], scale_all[te], grid["h"][te], seasons[te], tmp)
                    hits.append((coverage(name, y_all[te], lo, hi), int(te.sum())))
                cov = sum(c * n for c, n in hits) / max(sum(n for _, n in hits), 1) if hits else float("nan")
                entry["cv_coverage"] = fin(cov, 4)
                entry["served"] = bool(math.isfinite(cov) and abs(cov - nominal) <= INTERVAL_GATE)
                rule["bands"][band] = entry
                cv[band] = cov
            rules[method] = (rule, float(np.nanmean([abs(c - nominal) for c in cv.values()])))
        base_err = rules["normalized"][1]
        best = min(rules, key=lambda m: rules[m][1])
        chosen = best if rules[best][1] < base_err - 0.01 else "normalized"
        out[name] = rules[chosen][0]
        diag[name] = {"nominal": nominal, "chosen": chosen,
                      "rule": "normalized unless an alternative lowers the mean cross-fitted |coverage error| by > 1pp",
                      "mean_abs_cv_coverage_error": {m: fin(v[1], 4) for m, v in rules.items()},
                      "cv_coverage": {m: {b: e["cv_coverage"] for b, e in v[0]["bands"].items()}
                                      for m, v in rules.items()}}
    return out, diag


# ------------------------------------------------------------------------------------ ledger and spec
GENESIS = "0" * 64


def _entry_digest(entry: dict) -> str:
    body = {k: v for k, v in entry.items() if k != "entry_sha256"}
    return sha256_json(body)


def ledger_verify(path: Path) -> list:
    """Entries of an append-only hash-chained ledger; raises ValueError if any line was edited."""
    if not path.exists():
        return []
    entries, prev = [], GENESIS
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry.get("prev_line_sha256") != prev or entry.get("entry_sha256") != _entry_digest(entry):
            raise ValueError(f"ledger chain broken at line {i + 1}: {path}")
        prev = entry["entry_sha256"]
        entries.append(entry)
    return entries


def ledger_append(path: Path, entry: dict) -> dict:
    entries = ledger_verify(path)
    entry = {**entry, "prev_line_sha256": entries[-1]["entry_sha256"] if entries else GENESIS}
    entry["entry_sha256"] = _entry_digest(entry)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")
    return entry


def ledger_seed(path: Path) -> list:
    """Create the ledger with the earlier uses of the same test window (research-program reuse)."""
    if path.exists():
        return ledger_verify(path)

    def version(rel, fallback):
        try:
            return json.loads((BACKEND / rel).read_text(encoding="utf-8"))["model_version"]
        except Exception:  # noqa: BLE001
            return fallback
    window = [str(TEST_START), str(TEST_END)]
    seeds = [
        {"program": "long_range_v1", "model_version": version("models/long_range/metadata.json",
                                                              "lgbm-direct-168h-20261019"),
         "scored_at": "2026-10-19", "window": window, "note": "v1 test scoring (prior use of this test window)"},
        {"program": "long_range_v2", "model_version": version("models/long_range_v2/metadata.json",
                                                              "lgbm-direct-168h-v2"),
         "scored_at": "2026-10-31T07:27Z", "window": window, "note": "v2 test scoring (prior use of this window)"},
        {"program": "v3_val_select_overlap", "model_version": version("models/v3/metadata_v3.json", "v3"),
         "scored_at": "2026-10-23", "window": ["2025-01-01 00:00:00", "2025-09-23 23:00:00"],
         "note": "V3 val_select (calibration choice, fallback, promotion) overlaps 2025-01..2025-09"},
    ]
    for s in seeds:
        ledger_append(path, {**s, "test_spec_sha256": None, "code_sha256": None, "data_sha256": None,
                             "result_sha256": None, "seed_entry": True})
    return ledger_verify(path)


def ledger_guard(path: Path, program: str = PROGRAM):
    entries = ledger_verify(path)
    used = [e for e in entries if e.get("program") == program]
    if used:
        raise RuntimeError(f"test already scored for program {program} ({used[0].get('model_version')} at "
                           f"{used[0].get('scored_at')}); the test window is scored exactly once")
    return entries


def test_spec(model_version, cell_ids, folds, stride, bootstrap=BOOT_B) -> dict:
    return {"program": PROGRAM, "model_version": model_version,
            "window": [str(TEST_START), str(TEST_END)], "issue_rule": "issue and issue+168h inside the window",
            "issue_stride_hours": stride, "cell_ids": list(cell_ids), "spatial_folds": folds,
            "bands": {k: list(v) for k, v in S.BANDS.items()},
            "metrics": {n: primary_of(n) for n in M.TARGETS} | {"precipitation_mm_secondary": "mae",
                                                               "intervals": "coverage, width, pinball, Winkler"},
            "bootstrap": {"B": bootstrap, "block_days": BLOCK_DAYS, "seed": SEED, "kind": "moving block over issue days",
                          "unit": "all cells of an issue day resampled together", "ci": "percentile 95 %"},
            "baselines": {"climatology": "interpolated train climatology at valid time",
                          "persistence": "y(t)", "diurnal_persistence": "y(t+h-24*ceil(h/24))",
                          "damped_anomaly": "clim(valid) + rho(h) * anom(t), full-train rho",
                          "diurnal_damped": "clim(valid) + rho(h) * anom(t+h-24*ceil(h/24))",
                          "best_baseline": "test-oracle minimum of the five per band (conservative)",
                          "rain": "climatological frequency / damped frequency / persistence of the 0/1 event",
                          "comparators": "v1, v2 incumbent artifacts, V3 at 1/3/6h"},
            "success_criteria": {"rain_ece_cal_B2_B6": 0.02, "rain_brier_delta_ci_upper": 0.0,
                                 "interval_coverage_tolerance": 0.05, "interval_score_beats_clim_bands": ["B1", "B2",
                                                                                                         "B3", "B4"],
                                 "jump_ratio_max": 1.5},
            "v3_clean_start": str(V3_CLEAN_START), "v3_knowledge_end": str(V3_KNOWLEDGE_END), "seed": SEED}


def spatial_folds(statics: dict) -> dict:
    """Con Dao alone + KMeans(k=5) blocks of mainland cells on (lat, lon); buffer = cells within 0.12 deg."""
    from sklearn.cluster import KMeans
    ids = sorted(statics)
    mainland = [c for c in ids if c != CON_DAO]
    folds = {}
    if CON_DAO in ids:
        folds["con_dao"] = {"held_out": [CON_DAO]}
    if mainland:
        k = min(5, len(mainland))
        xy = np.array([[statics[c]["lat"], statics[c]["lon"]] for c in mainland])
        labels = KMeans(n_clusters=k, random_state=SEED, n_init=10).fit_predict(xy) if k > 1 else np.zeros(1, int)
        for f in range(k):
            folds[f"block_{f + 1}"] = {"held_out": [c for c, lab in zip(mainland, labels) if lab == f]}
    for fold in folds.values():
        held = fold["held_out"]
        buffer = [c for c in ids if c not in held and min(
            math.hypot(statics[c]["lat"] - statics[h]["lat"], statics[c]["lon"] - statics[h]["lon"]) for h in held)
                  <= BUFFER_DEG]
        fold["buffer_excluded"] = buffer
        fold["train_cells"] = [c for c in ids if c not in held and c not in buffer]
    return {"method": f"Con Dao ({CON_DAO}) alone; mainland KMeans(k<=5, random_state={SEED}, n_init=10) on "
                      f"(lat, lon); buffer: training excludes cells within {BUFFER_DEG} deg of a held-out cell",
            "selection_note": SPATIAL_SELECTION_NOTE, "folds": folds}


def write_manifest(out: Path):
    lines = []
    for p in sorted(out.rglob("*")):
        if p.is_file() and p.name != "MANIFEST.sha256":
            lines.append(f"{sha256_file(p)}  {p.relative_to(out).as_posix()}")
    (out / "MANIFEST.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")


def check_manifest(out: Path) -> list:
    problems = []
    listed = set()
    for line in (out / "MANIFEST.sha256").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        digest, rel = line.split("  ", 1)
        listed.add(rel)
        p = out / rel
        if not p.exists():
            problems.append(f"missing {rel}")
        elif sha256_file(p) != digest:
            problems.append(f"hash mismatch {rel}")
    extra = [p.relative_to(out).as_posix() for p in out.rglob("*") if p.is_file() and p.name != "MANIFEST.sha256"
             and p.relative_to(out).as_posix() not in listed]
    problems += [f"unlisted {e}" for e in extra]
    return problems


# ------------------------------------------------------------------------------------------- phases
def chosen_modes_table(grid, kinds):
    """Dev table: mean primary metric per target x kind x mode over horizons and per band; argmin."""
    table, argmin = {}, {}
    for kind in kinds:
        hmax = S.SHORT_MAX_HORIZON if kind == "short" else M.MAX_HORIZON
        for name in M.TARGETS:
            entry = {}
            for mode in M.TARGET_MODES:
                key = f"v21{kind}{mode}_{name}"
                if key not in grid:
                    continue
                ph = per_horizon_metric(name, as2d(grid, f"y_{name}"), as2d(grid, key))[:hmax]
                bands = {band: fin(np.nanmean(ph[a - 1:min(b, hmax)])) for band, (a, b) in S.BANDS.items()
                         if a <= hmax}
                entry[mode] = {"mean": fin(np.nanmean(ph)), "bands": bands}
            table.setdefault(name, {})[kind] = entry
            argmin.setdefault(kind, {})[name] = min(entry, key=lambda m: entry[m]["mean"])
    for name in M.TARGETS:
        base = {}
        for label, p in BASELINES.items():
            ph = per_horizon_metric(name, as2d(grid, f"y_{name}"), as2d(grid, f"{p}_{name}"))
            base[label] = fin(np.nanmean(ph))
        table[name]["baselines_mean"] = base
    return table, argmin


def phase_dev(args):
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    if (out / "dev_selection.json").exists():
        raise SystemExit(f"{out / 'dev_selection.json'} exists; dev results are never overwritten")
    tee = Tee(out / "train_log.txt")
    try:
        lo_load = (TRAIN_START_EXT if args.compare_train_start else TRAIN_START) - WARMUP
        frames, statics, snapshot, info = load_frames(args.data, lo_load, TEST_END, args.cells, args.cell_ids)
        audit = year_audit(frames, TRAIN_START_EXT, TRAIN_END)
        tables = build_tables(frames, TRAIN_START)
        cdata = make_cdata(frames, statics, tables, TRAIN_START)
        kinds = tuple(args.dev_kinds.split(","))
        modes = {n: list(M.TARGET_MODES) for n in M.TARGETS}
        models, rows = {}, {}
        for kind in kinds:
            sets = build_training(cdata, args, modes, kind, TRAIN_START)
            rows[kind] = {s: int(len(v[0])) for s, v in sets.items()}
            fitted, fit_info, _ = fit_boosters(sets, modes, args, kind)
            models.update(fitted)
            del sets
        grid = eval_grid(cdata, models, args.val_stride, *VAL_FIT, args)
        table, argmin = chosen_modes_table(grid, kinds)
        log(f"dev argmin: {argmin}")
        base_scores = {n: table[n]["long"][argmin["long"][n]]["mean"] for n in M.TARGETS} if "long" in kinds else {}
        del grid, models, cdata
        start_cmp = {"compared": False}
        if args.compare_train_start and "long" in kinds:
            flagged = sorted({y for col in audit.values() for y, r in col.items()
                              if y < TRAIN_START.year and (r["loo_shift_z"] or 0) > 3})
            candidate = TRAIN_START_EXT if not flagged else pd.Timestamp(f"{max(flagged) + 1}-01-01")
            start_cmp = {"compared": True, "candidate": str(candidate), "flagged_years": flagged,
                         "flag_rule": "yearly mean shift > 3 leave-one-year-out inter-year std (any variable)"}
            if candidate < TRAIN_START:
                ratio = (TRAIN_END - candidate) / (TRAIN_END - TRAIN_START)
                stride = args.train_stride
                est_gib = rows["long"]["train"] * ratio * len(M.feature_columns()) * 4 * 3 / 1024 ** 3
                if est_gib + rss_mib() / 1024 > RSS_LIMIT_MIB / 1024:
                    stride = int(math.ceil(args.train_stride * ratio))
                start_cmp["train_stride"] = stride
                tables2 = build_tables(frames, candidate)
                cdata2 = make_cdata(frames, statics, tables2, candidate)
                args2 = argparse.Namespace(**{**vars(args), "train_stride": stride})
                chosen = {n: [argmin["long"][n]] for n in M.TARGETS}
                sets = build_training(cdata2, args2, chosen, "long", candidate)
                start_cmp["rows"] = int(len(sets["train"][0]))
                fitted, _, _ = fit_boosters(sets, chosen, args2, "long")
                del sets
                grid2 = eval_grid(cdata2, fitted, args.val_stride, *VAL_FIT, args)
                ext = {}
                for n in M.TARGETS:
                    ph = per_horizon_metric(n, as2d(grid2, f"y_{n}"), as2d(grid2, f"v21long{argmin['long'][n]}_{n}"))
                    ext[n] = fin(np.nanmean(ph))
                rel = {n: fin(ext[n] / base_scores[n] - 1) for n in M.TARGETS}
                better = sum(1 for n in M.TARGETS if rel[n] < 0)
                adopt = better >= 4 and all(rel[n] <= 0.005 for n in M.TARGETS)
                start_cmp.update({"val_fit_mean_primary": {"2021": base_scores, str(candidate.year): ext},
                                  "relative_change": rel, "targets_improved": better, "adopt": adopt,
                                  "peak_rss_mib": round(rss_mib(), 1)})
                del grid2, fitted, cdata2
            else:
                start_cmp["adopt"] = False
        decision = start_cmp.get("candidate") if start_cmp.get("adopt") else str(TRAIN_START)
        selection = {"program": PROGRAM, "created_at": datetime.now(timezone.utc).isoformat(),
                     "role": "VAL_FIT (issue >= 2024-07-08, issue+168h <= 2024-10-06 23:00): early stopping, "
                             "target-mode choice, train-start choice",
                     "table": table, "argmin": argmin, "train_start": {**start_cmp, "decision": decision,
                                                                        "rule": ">= 4 of 6 targets better on VAL_FIT "
                                                                                "and none worse by > 0.5 %"},
                     "year_audit": audit, "sample_rows": rows,
                     "args": {k: str(v) for k, v in vars(args).items()}, "cli": sys.argv,
                     "code_sha256": code_hashes(), "data": info, "versions": library_versions(),
                     "peak_rss_mib": round(rss_mib(), 1), "elapsed_seconds": round(time.monotonic() - _START, 1)}
        write_json(out / "dev_selection.json", selection)
        log(f"dev done -> {out / 'dev_selection.json'} (train start decision {decision})")
    finally:
        tee.close()


def parse_modes(spec):
    return dict(item.split("=") for item in spec.split(",") if item)


def resolve_selection(args):
    if not args.selection or not args.selection.exists():
        raise SystemExit("--phase final needs --selection dev_selection.json (run --phase dev first)")
    sel = json.loads(args.selection.read_text(encoding="utf-8"))
    chosen = {kind: dict(sel["argmin"][kind]) for kind in ("long", "short")}
    override = {}
    for kind, spec in (("long", args.modes), ("short", args.short_modes)):
        given = parse_modes(spec)
        if given:
            if set(given) != set(M.TARGETS) or not set(given.values()) <= set(M.TARGET_MODES):
                raise SystemExit(f"--{kind} modes must give one of raw/anomaly/damped for every target")
            if given != chosen[kind]:
                if not args.override_reason:
                    raise SystemExit(f"{kind} modes differ from the dev argmin {chosen[kind]}; "
                                     "give --override-reason to record why")
                override[kind] = {"argmin": chosen[kind], "used": given}
            chosen[kind] = given
    return sel, chosen, override


def phase_final(args):
    out = args.out
    if out.exists():
        raise SystemExit(f"output exists; choose a new --out: {out}")
    if args.ledger:
        ledger_guard(args.ledger)  # refuse before hours of training once v2.1 has touched the test window
    sel, chosen, override = resolve_selection(args)
    train_lo = pd.Timestamp(sel["train_start"]["decision"])
    if train_lo < TRAIN_START and sel["train_start"].get("train_stride"):
        # dev raised the stride for the longer window to stay under the RSS guard: keep the same factor
        factor = int(sel["train_start"]["train_stride"]) / float(sel["args"]["train_stride"])
        args.train_stride = int(math.ceil(args.train_stride * max(factor, 1.0)))
    out.mkdir(parents=True)
    tee = Tee(out / "train_log.txt")
    try:
        _final(args, out, sel, chosen, override, train_lo)
    finally:
        tee.close()
    write_manifest(out)


def _final(args, out, sel, chosen, override, train_lo):
    frames, statics, snapshot, info = load_frames(args.data, train_lo - WARMUP, TEST_END, args.cells, args.cell_ids)
    tables = build_tables(frames, train_lo)
    cdata = make_cdata(frames, statics, tables, train_lo)
    del frames
    kinds = ("long", "short")
    models, info_fit, rows = {}, {}, {}
    params = None
    for kind in kinds:
        modes = {n: [chosen[kind][n]] for n in M.TARGETS}
        sets = build_training(cdata, args, modes, kind, train_lo)
        rows[kind] = {s: int(len(v[0])) for s, v in sets.items()}
        fitted, fi, params = fit_boosters(sets, modes, args, kind)
        models.update(fitted)
        info_fit.update(fi)
        del sets, fitted
    comps = Comparators({"v3"}, args)
    grid = eval_grid(cdata, models, args.val_stride, *VAL_CAL, args, comps)
    rename_chosen(grid, chosen)
    version = f"{S.MODEL_VERSION_PREFIX}{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"
    policy = {"model_version": version, "selected_on": "VAL_CAL", "fit_window": [str(VAL_CAL[0]), str(VAL_CAL[1])],
              "rules": {"taper": "w(h)=w0 for h<=a, linear to 0 at b; grid w0 x a x b; objective mean primary "
                                 "1..36 + lambda * mean J(h) on [a,b]",
                        "v3": "c(k)=w_k(V3_k-v21_k), w in {0,.25,.5,.75,1}, kept if 90 % block-bootstrap lower bound "
                              "of relative gain > 0, w1>=w3>=w6; stitched: linear between anchors, 0 at 9h",
                        "v3_knowledge_window": f"issues <= {V3_KNOWLEDGE_END} serve v2.1 alone at 1..9h"},
              "v3_knowledge_end": M.local_iso(V3_KNOWLEDGE_END), "targets": {},
              "diagnostics": {"v3_val_select_overlap": {
                  "v3_val_select": ["2024-10-01 00:00:00", str(V3_KNOWLEDGE_END)],
                  "val_cal": [str(VAL_CAL[0]), str(VAL_CAL[1])], "val_cal_inside_v3_val_select": True,
                  "note": "V3's calibration choice/fallback/promotion used VAL_CAL: V3 VAL_CAL skill and the V3 "
                          "blend weights are slightly optimistic; rain calibrator and conformal quantiles are "
                          "fitted on V3-blended 1..9h values"}},
              "horizon_bands": {k: list(v) for k, v in S.BANDS.items()}}
    for name in M.TARGETS:
        taper, tdiag = fit_taper(grid, name)
        rule = {"taper": taper}
        policy["diagnostics"][f"{name}_taper"] = tdiag
        if name in V3_TARGETS and comps.v3:
            v3rule, vdiag = fit_v3(grid, name, taper)
            rule["v3"] = v3rule
            policy["diagnostics"][f"{name}_v3"] = vdiag
        policy["targets"][name] = rule
        log(f"policy {name}: {rule}")
    identity_cal = {"model_version": version, "bands": {b: {"method": "none"} for b in S.BANDS}}
    apply_policy_grid(grid, {**policy, "serve_calibrated_rain": {}}, identity_cal, use_window=False)
    calibration, flags, cdiag = fit_rain_calibration(grid, version)
    policy["serve_calibrated_rain"] = flags
    policy["diagnostics"]["rain_calibration"] = cdiag
    interval_rules, idiag = fit_intervals(grid, policy["targets"])
    policy["intervals"] = interval_rules
    policy["diagnostics"]["intervals"] = idiag
    apply_policy_grid(grid, policy, calibration, use_window=False)
    val_report = evaluation_report(grid, "served", B=args.bootstrap)
    log("validation (VAL_CAL) report ready")
    folds = spatial_folds(statics)
    cell_ids = sorted(cdata)
    capabilities = {n: {"status": "available", "horizons": [1, 168],
                        "rows": {k: rows[k]["train"] for k in kinds},
                        "best_iteration": {k: info_fit[(n, chosen[k][n], k)]["best_iteration"] for k in kinds},
                        "target_mode": {k: chosen[k][n] for k in kinds}} for n in M.TARGETS}
    for name in M.TARGETS:
        models[(name, chosen["long"][name], "long")].save_model(str(out / f"{name}.txt"))
        models[(name, chosen["short"][name], "short")].save_model(str(out / f"{name}_short.txt"))
    write_json(out / "climatology.json", {"model_version": version, "source": f"train period {train_lo}..{TRAIN_END}",
                                          "cells": tables["clim"], "rho": tables["rho"], "std": tables["std"],
                                          "rho_loyo_max_abs_diff": tables["rho_loyo_max_abs_diff"]}, indent=None)
    write_json(out / "serving_policy.json", policy)
    write_json(out / "calibration.json", calibration)
    write_json(out / "spatial_folds.json", {"model_version": version, **folds})
    write_json(out / "dev_selection.json", sel)
    spec = test_spec(version, cell_ids, folds, args.test_stride, args.bootstrap)
    write_json(out / "test_spec.json", spec)
    spec_sha = sha256_file(out / "test_spec.json")
    ledger_src = args.ledger
    if ledger_src:
        ledger_seed(ledger_src)
        ledger_guard(ledger_src)
        (out / "test_ledger.jsonl").write_bytes(ledger_src.read_bytes())
    else:
        ledger_seed(out / "test_ledger.jsonl")
    val_rows = {name: int(sum(issue_window(cd.raw.timestamp, lo, hi).sum() for cd in cdata.values()))
                for name, (lo, hi) in (("val_fit", VAL_FIT), ("val_cal", VAL_CAL))}
    meta = {"schema_version": S.SCHEMA_VERSION, "model_version": version, "source": "ai", "program": PROGRAM,
            "trained_at": datetime.now(timezone.utc).isoformat(), "trained_through": M.local_iso(VAL_END),
            "fit_labels_through": M.local_iso(TRAIN_END), "selection_labels_through": M.local_iso(VAL_END),
            "max_horizon_hours": M.MAX_HORIZON, "min_history_hours": M.MIN_HISTORY_HOURS,
            "feature_columns": M.feature_columns(), "cell_static": statics, "target_mode": chosen["long"],
            "capabilities": capabilities,
            "short_range": {"max_horizon_hours": S.SHORT_MAX_HORIZON, "target_mode": chosen["short"]},
            "data_snapshot": snapshot, "data": info, "data_timezone": M.TIMEZONE,
            "units": {"temperature": "celsius", "humidity": "%", "precipitation_mm": "mm/hour",
                      "wind_speed": "km/h", "cloud_cover": "%", "rain_probability": "0..1"},
            "rain_threshold_mm": M.RAIN_THRESHOLD_MM, "limitations": LIMITATIONS,
            "split": {"train": [str(train_lo), str(TRAIN_END)], "validation": [str(VAL_START), str(VAL_END)],
                      "val_fit": {"window": [str(VAL_FIT[0]), str(VAL_FIT[1])],
                                  "roles": "early stopping, target mode, train start",
                                  "eligible_issue_hours": val_rows["val_fit"], "es_rows": {k: rows[k]["es"]
                                                                                           for k in kinds}},
                      "val_cal": {"window": [str(VAL_CAL[0]), str(VAL_CAL[1])],
                                  "roles": "taper, V3 blend, rain calibrator, conformal quantiles, serve gates",
                                  "eligible_issue_hours": val_rows["val_cal"], "grid_rows": int(len(grid["h"]))},
                      "purge_hours": 168, "test": [str(TEST_START), str(TEST_END)], "gap_hours": 168,
                      "rule": "issue and issue+168h inside split; tables from train only (LOYO clim+rho for train "
                              "rows); test scored once (ledger)", "sample_rows": rows},
            "sampling": {"train_long": f"every {args.train_stride}h issue, {args.k} horizons (one 1..24)",
                         "train_short": f"every {args.short_stride}h issue, {args.short_k} horizons from 1..36",
                         "early_stopping": f"VAL_FIT issues every {args.es_stride}h, 2 horizons per issue",
                         "val_cal_eval": f"VAL_CAL issues every {args.val_stride}h, all 168 horizons",
                         "test_eval": f"test issues every {args.test_stride}h, all 168 horizons", "seed": args.seed},
            "sampling_args": {"train_stride": int(args.train_stride), "k": int(args.k)},
            "params": params, "max_rounds": args.max_rounds, "early_stopping_rounds": args.patience,
            "fit_seconds": {f"{n}_{k}": info_fit[(n, chosen[k][n], k)]["seconds"] for n in M.TARGETS for k in kinds},
            "selection": {"file": "dev_selection.json", "sha256": sha256_file(out / "dev_selection.json"),
                          "override": override, "override_reason": args.override_reason or None},
            "rho_loyo": {"years": tables["train_years"], "max_abs_diff_vs_full": tables["rho_loyo_max_abs_diff"]},
            "test_spec_sha256": spec_sha, "code_sha256": code_hashes(), "versions": library_versions(),
            "cli": sys.argv, "seed": args.seed, "v3_component": comps.notes.get("v3") or "models/v3",
            "serving_inputs": "last 48 contiguous hourly rows of the cell (temperature, humidity, precipitation, "
                              "wind_speed, cloud_cover, pressure_msl); V3 needs its input columns and models/v3"}
    write_json(out / "metadata.json", meta, indent=2)
    parity = make_parity_cases(out, cdata, grid, version, args)
    meta["parity"] = parity
    report = {n: {"validation": val_report[n]} for n in M.TARGETS}
    write_json(out / "evaluation.json", report)
    meta["resources"] = {"elapsed_seconds": round(time.monotonic() - _START, 1), "peak_rss_mib": round(rss_mib(), 1),
                         "num_threads": args.threads}
    write_json(out / "metadata.json", meta, indent=2)
    log(f"artifact ready: {out} (parity max diff {parity['max_abs_diff_overall']})")


PARITY_KEYS = tuple(M.TARGETS) + S.EXTRA_RECORD_KEYS


def grid_case(grid, row) -> dict:
    sl = slice(row, row + M.MAX_HORIZON)
    out = {name: grid[f"served_{name}"][sl].astype(float) for name in M.TARGETS}
    out["rain_probability_raw"] = grid["rawrain_rain_probability"][sl].astype(float)
    for name in S.INTERVAL_TARGETS:
        out[f"{name}_p90"] = grid[f"p90_{name}"][sl].astype(float)
        if name not in S.UPPER_ONLY:
            out[f"{name}_p10"] = grid[f"p10_{name}"][sl].astype(float)
    return out


def compare_case(expected: dict, got: dict) -> dict:
    diffs = {}
    for key in PARITY_KEYS:
        e = np.asarray([np.nan if v is None else v for v in expected[key]], float)
        g = np.asarray(got.get(key, np.full(len(e), np.nan)), float)
        if (np.isfinite(e) != np.isfinite(g)).any():
            diffs[key] = float("inf")
        else:
            ok = np.isfinite(e)
            diffs[key] = float(np.max(np.abs(e[ok] - g[ok]))) if ok.any() else 0.0
    return diffs


def make_parity_cases(out, cdata, grid, version, args, n=24):
    """24 VAL_CAL (cell, issue) pairs with the trainer's served arrays; recomputed via the serving module."""
    meta, models, climate, policy, calibration = S._load(str(out.resolve()), -1)
    rng = np.random.default_rng(args.seed)
    starts = np.flatnonzero(grid["h"] == 1)
    cases, worst = [], {}
    for row in sorted(rng.choice(starts, min(n, len(starts)), replace=False)):
        cid = grid["cell_ids"][int(grid["cell"][row])]
        issue = pd.Timestamp(np.datetime64(int(grid["issue_time"][row]), "h"))
        expected = grid_case(grid, row)
        cd = cdata[cid]
        idx = int(np.flatnonzero(cd.raw.timestamp.to_numpy() == issue.to_datetime64())[0])
        hist = S._prepare(cd.raw.iloc[idx - M.MIN_HISTORY_HOURS + 1: idx + 1], cid)
        got, _ = S.forecast_arrays(hist, cid, meta, models, climate, policy, calibration, use_v3=True)
        for k, v in compare_case(expected, got).items():
            worst[k] = max(worst.get(k, 0.0), v)
        cases.append({"cell_id": cid, "issue_time": str(issue),
                      "expected": {k: [fin(x, 9) for x in v] for k, v in expected.items()}})
    write_json(out / "parity_cases.json", {"model_version": version, "use_v3": True, "tolerance": 1e-4,
                                           "source": "VAL_CAL grid (trainer)", "cases": cases})
    overall = max(worst.values()) if worst else 0.0
    if not overall <= 1e-4:
        raise RuntimeError(f"serving parity failed in final: {worst}")
    return {"samples": len(cases), "max_abs_diff": {k: fin(v, 9) for k, v in worst.items()},
            "max_abs_diff_overall": fin(overall, 9)}


def load_artifact(out: Path):
    return S._load(str(out.resolve()), -2)


def phase_spatial(args):
    out = args.out
    meta = json.loads((out / "metadata.json").read_text(encoding="utf-8"))
    folds = json.loads((out / "spatial_folds.json").read_text(encoding="utf-8"))["folds"]
    sdir = args.spatial_dir or out.parent / f"{out.name}_spatial"
    sdir.mkdir(parents=True, exist_ok=True)
    tee = Tee(sdir / "train_log.txt")
    try:
        train_lo = pd.Timestamp(meta["split"]["train"][0])
        ids = ",".join(sorted(meta["cell_static"]))
        frames, statics, _, info = load_frames(args.data, train_lo - WARMUP, TEST_END, 0, ids)
        if info["canonical_sha256"] != meta["data"]["canonical_sha256"]:
            raise SystemExit("data differ from the final phase (canonical sha256)")
        tables = build_tables(frames, train_lo)
        cdata = make_cdata(frames, statics, tables, train_lo)
        del frames
        modes = {n: [meta["target_mode"][n]] for n in M.TARGETS}
        rounds = {(n, meta["target_mode"][n]): meta["capabilities"][n]["best_iteration"]["long"] for n in M.TARGETS}
        apply_sampling_args(args, meta)
        cfg = {k: getattr(args, k) for k in ("train_stride", "k", "learning_rate", "min_data_in_leaf", "seed")}
        for fold, spec in folds.items():
            fdir = sdir / fold
            if (fdir / "fold_meta.json").exists():
                log(f"fold {fold} already done (resume)")
                continue
            train_cells = set(spec["train_cells"])
            if not train_cells:
                log(f"fold {fold}: no training cells after buffer; skipped")
                continue
            rho, loyo_rho = fold_damping(cdata, tables, train_cells, train_lo)
            set_rho(cdata, rho, loyo_rho)
            try:
                sets = build_training(cdata, args, modes, "long", train_lo, cells=train_cells, with_es=False)
            finally:
                set_rho(cdata, tables["rho"], tables["loyo_rho"])
            fitted, fi, _ = fit_boosters(sets, modes, args, "long", rounds=rounds)
            del sets
            fdir.mkdir(parents=True, exist_ok=True)
            for (name, mode, _), model in fitted.items():
                model.save_model(str(fdir / f"{name}.txt"))
            write_json(fdir / "fold_meta.json", {"model_version": meta["model_version"], "fold": fold, **spec,
                                                  "rounds": {n: rounds[(n, meta["target_mode"][n])] for n in M.TARGETS},
                                                  "rho": rho, "selection_note": SPATIAL_SELECTION_NOTE,
                                                  "config": cfg, "completed_at": datetime.now(timezone.utc).isoformat()})
            log(f"fold {fold} done ({len(train_cells)} training cells)")
    finally:
        tee.close()


def apply_sampling_args(args, meta):
    """Spatial folds use the effective train stride / k of the final booster (dev may have raised the stride)."""
    sampling = meta.get("sampling_args")
    if not sampling:
        raise SystemExit("metadata.json has no sampling_args (artifact from an older trainer); rerun final")
    for key, value in sampling.items():
        if int(getattr(args, key)) != int(value):
            log(f"spatial: {key} {getattr(args, key)} -> {value} (as in final)")
        setattr(args, key, int(value))


def load_fold_models(sdir: Path, meta: dict, folds: dict):
    import lightgbm as lgb
    out, done = {}, {}
    if sdir is None or not sdir.exists():
        return None, {}
    for fold, spec in folds.items():
        fm = sdir / fold / "fold_meta.json"
        if not fm.exists():
            continue
        info = json.loads(fm.read_text(encoding="utf-8"))
        if info["model_version"] != meta["model_version"]:
            raise SystemExit(f"spatial fold {fold} belongs to another model_version")
        sampling = meta.get("sampling_args") or {}
        if any(int(info["config"].get(k, -1)) != int(v) for k, v in sampling.items()) or "rho" not in info:
            raise SystemExit(f"spatial fold {fold} was trained with other sampling args / without fold rho; "
                             f"delete {sdir / fold} and rerun --phase spatial")
        boosters = {n: (meta["target_mode"][n], lgb.Booster(model_file=str(sdir / fold / f"{n}.txt")))
                    for n in M.TARGETS}
        for cid in spec["held_out"]:
            out[cid] = (boosters, info["rho"])
        done[fold] = spec
    return out, done


# ---------------------------------------------------------------------------------------- test phase
def v3_window_split(grid, ungated, hmax=9) -> dict:
    """Point summary (no bootstrap) of 1..9h rain calibration and interval coverage per V3 window: issues
    <= V3_KNOWLEDGE_END serve v2.1 alone at 1..9h, while VAL_CAL fits used V3-blended values."""
    window = grid["issue_time"] <= hours(V3_KNOWLEDGE_END)
    short = grid["h"] <= hmax
    out = {"hours": [1, hmax], "rule": f"v21_alone: issue <= {V3_KNOWLEDGE_END}; v3_blended: later issues"}
    for label, part in (("v21_alone", window), ("v3_blended", ~window)):
        y = grid["y_rain_probability"].astype(float)
        p = grid["served_rain_probability"].astype(float)
        rows = part & short & np.isfinite(y) & np.isfinite(p)
        entry = {"n": int(rows.sum())}
        if rows.any():
            entry["rain_brier"] = fin(np.mean((p[rows] - y[rows]) ** 2))
            entry["rain_ece15"] = fin(ece(p[rows], y[rows]))
        cov = {}
        for name in S.INTERVAL_TARGETS:
            lo, hi = ungated[name]
            yy = grid[f"y_{name}"].astype(float)
            r = part & short & np.isfinite(yy) & np.isfinite(hi)
            if r.any():
                cov[name] = {"n": int(r.sum()), "nominal": NOMINAL[name],
                             "coverage": fin(coverage(name, yy[r], lo[r], hi[r]), 4)}
        entry["interval_coverage"] = cov
        out[label] = entry
    return out


def calibration_report(grid, policy, mask, figures: Path | None):
    y_all = grid["y_rain_probability"].astype(float)
    raw_all = grid["rawrain_rain_probability"].astype(float)
    cal_all = grid["served_rain_probability"].astype(float)
    clim_all = grid["clim_rain_probability"].astype(float)
    day = issue_day(grid)
    seasons = S.season_of(grid["month"])
    out = {}
    for band, (a, b) in S.BANDS.items():
        rows = mask & (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(y_all) & np.isfinite(raw_all)
        y, raw, cal, clim = y_all[rows], raw_all[rows], cal_all[rows], clim_all[rows]
        entry = {"n": int(rows.sum()), "served_calibrated": bool((policy.get("serve_calibrated_rain") or {}).get(band)),
                 "ece15_raw": fin(ece(raw, y)), "ece15_cal": fin(ece(cal, y)),
                 "ece10_fixed_raw": fin(ece(raw, y, 10, False)), "ece10_fixed_cal": fin(ece(cal, y, 10, False)),
                 "brier_raw": fin(np.mean((raw - y) ** 2)), "brier_cal": fin(np.mean((cal - y) ** 2)),
                 "brier_clim": fin(np.mean((clim - y) ** 2)),
                 "murphy_cal": murphy(cal, y), "murphy_raw": murphy(raw, y),
                 "brier_cal_minus_raw": delta_ci(day[rows], (cal - y) ** 2, (raw - y) ** 2, "brier"),
                 "brier_cal_minus_clim": delta_ci(day[rows], (cal - y) ** 2, (clim - y) ** 2, "brier")}
        point, reps = block_bootstrap(day[rows], [(cal - y) ** 2, (clim - y) ** 2])
        bss = 1 - reps[:, 0] / reps[:, 1]
        entry["brier_skill_vs_clim"] = {"value": fin(1 - point[0] / point[1]),
                                        "ci95": [fin(v) for v in np.nanpercentile(bss, [2.5, 97.5])]}
        entry["by_season"] = {s: {"n": int((seasons[rows] == s).sum()),
                                  "ece15_cal": fin(ece(cal[seasons[rows] == s], y[seasons[rows] == s])),
                                  "brier_cal": fin(np.mean((cal[seasons[rows] == s] - y[seasons[rows] == s]) ** 2))}
                              for s in ("dry", "wet") if (seasons[rows] == s).any()}
        if entry["served_calibrated"] and band != "B1":
            entry["criterion_met"] = bool(entry["ece15_cal"] is not None and entry["ece15_cal"] <= 0.02 and
                                          entry["brier_cal_minus_raw"]["ci95"][1] is not None and
                                          entry["brier_cal_minus_raw"]["ci95"][1] <= 0)
        out[band] = entry
        if figures is not None:
            reliability_figure(figures / f"rain_reliability_{band.lower()}.png", band, raw, cal, y)
    return out


def interval_report(grid, mask, ungated):
    day = issue_day(grid)
    seasons = S.season_of(grid["month"])
    out = {}
    alpha = 0.2
    for name in S.INTERVAL_TARGETS:
        y_all = grid[f"y_{name}"].astype(float)
        upper = name in S.UPPER_ONLY
        entry = {}
        for band, (a, b) in S.BANDS.items():
            base = mask & (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(y_all)
            lo_all, hi_all = ungated[name]
            rows = base & np.isfinite(hi_all)
            if not rows.any():
                entry[band] = {"n": 0}
                continue
            y, hi, lo = y_all[rows], hi_all[rows], lo_all[rows]
            cq10, cq90 = grid[f"cq10_{name}"][rows].astype(float), grid[f"cq90_{name}"][rows].astype(float)
            served = bool(np.isfinite(grid[f"p90_{name}"][rows]).all())

            def scores(lo_, hi_):
                pin_hi = np.maximum(0.9 * (y - hi_), (0.9 - 1) * (y - hi_))
                if upper:
                    return (y <= hi_).astype(float), pin_hi, pin_hi
                pin_lo = np.maximum(0.1 * (y - lo_), (0.1 - 1) * (y - lo_))
                wink = (hi_ - lo_) + 2 / alpha * np.maximum(lo_ - y, 0) + 2 / alpha * np.maximum(y - hi_, 0)
                return ((y >= lo_) & (y <= hi_)).astype(float), (pin_lo + pin_hi) / 2, wink
            cov_m, pin_m, score_m = scores(lo, hi)
            cov_c, pin_c, score_c = scores(cq10, cq90)
            point, reps = block_bootstrap(day[rows], [cov_m])
            nominal = NOMINAL[name]
            cov = float(point[0])
            e = {"n": int(rows.sum()), "served": served, "nominal": nominal, "coverage": fin(cov, 4),
                 "coverage_ci95": [fin(v, 4) for v in np.nanpercentile(reps[:, 0], [2.5, 97.5])],
                 "coverage_within_0.05": bool(abs(cov - nominal) <= 0.05),
                 "mean_width": None if upper else fin(np.mean(hi - lo)),
                 "pinball": fin(np.mean(pin_m)), "pinball_clim": fin(np.mean(pin_c)),
                 "coverage_clim_interval": fin(np.mean(cov_c), 4),
                 "score_name": "pinball_0.9" if upper else "winkler_80",
                 "score": fin(np.mean(score_m)), "score_clim": fin(np.mean(score_c)),
                 "score_minus_clim": delta_ci(day[rows], score_m, score_c, "mae")}
            e["beats_clim_interval"] = bool(e["score_minus_clim"]["significant"])
            e["by_season"] = {s: {"n": int((seasons[rows] == s).sum()),
                                  "coverage": fin(cov_m[seasons[rows] == s].mean(), 4)}
                              for s in ("dry", "wet") if (seasons[rows] == s).any()}
            entry[band] = e
        cells = grid["cell"]
        entry["by_cell_coverage"] = {}
        lo_all, hi_all = ungated[name]
        for ci, cid in enumerate(grid["cell_ids"]):
            rows = mask & (cells == ci) & np.isfinite(y_all) & np.isfinite(hi_all)
            if rows.any():
                c = (y_all[rows] <= hi_all[rows]) if upper else ((y_all[rows] >= lo_all[rows]) &
                                                                 (y_all[rows] <= hi_all[rows]))
                entry["by_cell_coverage"][cid] = fin(c.mean(), 4)
        out[name] = entry
    return out


def jump_report(grid, mask_issue=None):
    out = {}
    for name in M.TARGETS:
        entry = {}
        for label, prefix in (("served", "served"), ("v2", "v2")):
            key = f"{prefix}_{name}"
            if key not in grid:
                continue
            v = as2d(grid, key)
            if mask_issue is not None:
                v = v[mask_issue]
            j = jump_curve(v)
            m1020 = float(np.nanmedian(j[9:20]))
            m1048 = float(np.nanmedian(j[9:48]))
            stitch = {str(h): fin(j[h - 1] / m1020, 3) for h in range(2, 10)}
            taper = {str(h): fin(j[h - 1] / m1048, 3) for h in range(19, 38)}
            entry[label] = {"J": [fin(x, 5) for x in j[1:]], "ratio_2_9_vs_median_10_20": stitch,
                            "ratio_19_37_vs_median_10_48": taper,
                            "max_ratio_2_9": fin(max(x for x in stitch.values() if x is not None), 3),
                            "max_ratio_19_37": fin(max(x for x in taper.values() if x is not None), 3)}
        if "served" in entry:
            entry["criterion_met"] = bool(entry["served"]["max_ratio_2_9"] <= 1.5 and
                                          entry["served"]["max_ratio_19_37"] <= 1.5)
        out[name] = entry
    return out


def blend_report(grid, clean):
    """V3 blend (1..9h) vs v2.1 alone: primary on issues >= 2025-10-01 (V3's own test), secondary full test."""
    out = {}
    issue_ok = {"clean_since_2025_10_01": clean,
                "full_test_v3_selection_window_contaminated_before_2025_10_01": np.ones(len(clean), dtype=bool)}
    for name in V3_TARGETS:
        if f"blend_{name}" not in grid:
            continue
        entry = {}
        y = grid[f"y_{name}"].astype(float)
        for label, m in issue_ok.items():
            rows_all = m & (grid["h"] <= S.V3_STITCH_END) & np.isfinite(y)
            res = {}
            for h in range(1, S.V3_STITCH_END + 1):
                rows = rows_all & (grid["h"] == h)
                if not rows.any():
                    continue
                a, b = grid[f"blend_{name}"][rows].astype(float), grid[f"v21_{name}"][rows].astype(float)
                metric = primary_of(name)
                res[str(h)] = {"n": int(rows.sum()), "blend": metric_block(name, y[rows], a),
                               "v21_alone": metric_block(name, y[rows], b),
                               "delta": delta_ci(issue_day(grid)[rows], loss(name, y[rows], a), loss(name, y[rows], b),
                                                 metric)}
            entry[label] = res
        out[name] = entry
    return out


def spatial_report(grid, done_folds, mask):
    out = {}
    if not done_folds:
        return {"status": "not run (no fold boosters found)", "selection_note": SPATIAL_SELECTION_NOTE}
    pools = {fold: spec["held_out"] for fold, spec in done_folds.items()}
    mainland = [c for f, cells in pools.items() if f != "con_dao" for c in cells]
    if mainland:
        pools["pooled_mainland"] = mainland
    cell_index = {cid: i for i, cid in enumerate(grid["cell_ids"])}
    day = issue_day(grid)
    for fold, cells in pools.items():
        sel = mask & np.isin(grid["cell"], [cell_index[c] for c in cells if c in cell_index])
        entry = {}
        for name in M.TARGETS:
            y = grid[f"y_{name}"].astype(float)
            primary = primary_of(name)
            bands = {}
            for band, (a, b) in S.BANDS.items():
                rows = sel & (grid["h"] >= a) & (grid["h"] <= b) & np.isfinite(y) & np.isfinite(grid[f"fold_{name}"])
                if not rows.any():
                    continue
                yy = y[rows]
                fold_p = grid[f"fold_{name}"][rows].astype(float)
                final_p = grid[f"v21long_{name}"][rows].astype(float)
                base_scores = {lab: metric_block(name, yy, grid[f"{p}_{name}"][rows].astype(float))[primary]
                               for lab, p in BASELINES.items()}
                best = min(base_scores, key=base_scores.get)
                best_p = grid[f"{BASELINES[best]}_{name}"][rows].astype(float)
                mf, mfin = metric_block(name, yy, fold_p)[primary], metric_block(name, yy, final_p)[primary]
                d = delta_ci(day[rows], loss(name, yy, fold_p), loss(name, yy, best_p), primary)
                bands[band] = {"n": int(rows.sum()), "fold_model": fin(mf), "final_model_in_sample": fin(mfin),
                               "best_baseline": best, "best_baseline_metric": fin(base_scores[best]),
                               "degradation_ratio_fold_over_final": fin(mf / mfin) if mfin > 0 else None,
                               "fold_minus_best_baseline": d, "generalizes": bool(d["significant"])}
            entry[name] = bands
        out[fold] = {"held_out": cells, "selection_note": SPATIAL_SELECTION_NOTE, "targets": entry}
    return out


def reliability_figure(path, band, raw, cal, y):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:  # noqa: BLE001 - figures are optional
        return
    fig, ax = plt.subplots(figsize=(4, 4))
    for label, p, style in (("uncalibrated", raw, "o--"), ("served", cal, "s-")):
        groups = np.array_split(np.argsort(p, kind="stable"), 15)
        ax.plot([p[g].mean() for g in groups if len(g)], [y[g].mean() for g in groups if len(g)], style,
                label=label, markersize=3)
    ax.plot([0, 1], [0, 1], color="grey", linewidth=0.8)
    ax.set_xlabel("forecast probability")
    ax.set_ylabel("observed frequency")
    ax.set_title(f"Rain reliability {band} (TEST)")
    ax.legend(fontsize=8)
    fig.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110)
    plt.close(fig)


def summary_figures(figures: Path, report: dict, intervals_rep: dict, jumps: dict, skill_h: dict):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:  # noqa: BLE001
        return
    figures.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(2, 3, figsize=(12, 6), sharex=True)
    for ax, name in zip(axes.ravel(), M.TARGETS):
        s = skill_h[name]
        h = np.arange(1, M.MAX_HORIZON + 1)
        ax.plot(h, s["skill"], label="skill vs best baseline")
        ax.fill_between(h, s["lo"], s["hi"], alpha=0.3)
        ax.axhline(0, color="grey", linewidth=0.8)
        ax.set_title(name)
    axes[0, 0].legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(figures / "skill_by_horizon.png", dpi=110)
    plt.close(fig)
    fig, ax = plt.subplots(figsize=(7, 4))
    for name, entry in intervals_rep.items():
        bands = [b for b in S.BANDS if entry.get(b, {}).get("n")]
        ax.plot(bands, [entry[b]["coverage"] for b in bands], "o-", label=name)
    ax.axhline(0.8, color="grey", linewidth=0.8)
    ax.axhline(0.9, color="grey", linewidth=0.8, linestyle=":")
    ax.set_ylabel("TEST coverage")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(figures / "interval_coverage.png", dpi=110)
    plt.close(fig)
    fig, axes = plt.subplots(2, 3, figsize=(12, 6), sharex=True)
    for ax, name in zip(axes.ravel(), M.TARGETS):
        for label in ("served", "v2"):
            if label in jumps[name]:
                ax.plot(range(2, 49), jumps[name][label]["J"][:47], label=label)
        ax.set_title(f"{name}: mean |y(h)-y(h-1)|")
    axes[0, 0].legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(figures / "jump_curve.png", dpi=110)
    plt.close(fig)


def skill_by_horizon(grid, mask, B):
    out = {}
    day = issue_day(grid)
    for name in M.TARGETS:
        y = grid[f"y_{name}"].astype(float)
        metric = primary_of(name)
        skill, lo, hi = [], [], []
        for h in range(1, M.MAX_HORIZON + 1):
            rows = mask & (grid["h"] == h) & np.isfinite(y)
            if not rows.any():
                skill.append(np.nan)
                lo.append(np.nan)
                hi.append(np.nan)
                continue
            scores = {p: metric_block(name, y[rows], grid[f"{p}_{name}"][rows].astype(float))[metric]
                      for p in BASELINES.values()}
            best = min(scores, key=scores.get)
            point, reps = block_bootstrap(day[rows], [loss(name, y[rows], grid[f"served_{name}"][rows]),
                                                      loss(name, y[rows], grid[f"{best}_{name}"][rows])], B=B)
            s = 1 - finish(metric, reps[:, 0]) / finish(metric, reps[:, 1])
            skill.append(1 - finish(metric, point[0]) / finish(metric, point[1]))
            a, b = np.nanpercentile(s, [2.5, 97.5])
            lo.append(a)
            hi.append(b)
        out[name] = {"skill": skill, "lo": lo, "hi": hi}
    return out


def phase_test(args):
    out = args.out
    if not args.ledger:
        raise SystemExit("--phase test needs --ledger (global write-once ledger, e.g. Drive/sky_weather_colab/"
                         "ledger/test_ledger.jsonl)")
    meta = json.loads((out / "metadata.json").read_text(encoding="utf-8"))
    spec_path = out / "test_spec.json"
    if not spec_path.exists() or sha256_file(spec_path) != meta.get("test_spec_sha256"):
        raise SystemExit("test_spec.json is missing or its sha256 differs from metadata.json; refusing to score")
    ledger_seed(args.ledger)
    ledger_guard(args.ledger)
    ledger_guard(out / "test_ledger.jsonl")
    report = json.loads((out / "evaluation.json").read_text(encoding="utf-8"))
    if any("test" in entry for entry in report.values()):
        raise SystemExit("test was already scored for this artifact; it is scored exactly once")
    for leftover in ("test_report.json", "figures"):
        if (out / leftover).exists():
            raise SystemExit(f"{out / leftover} exists: test scoring already started for this artifact; "
                             "it is scored exactly once")
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    tee = Tee(out / "train_log.txt")
    try:
        _test(args, out, meta, spec, report)
    finally:
        tee.close()
    write_manifest(out)


def _test(args, out, meta, spec, report):
    # 'started' entry BEFORE any test label is read: a crash/OOM later still consumes the test window
    started = ledger_append(args.ledger, {"program": PROGRAM, "status": "started",
                                          "model_version": meta["model_version"],
                                          "test_spec_sha256": meta["test_spec_sha256"],
                                          "scored_at": datetime.now(timezone.utc).isoformat(),
                                          "window": spec["window"]})
    (out / "test_ledger.jsonl").write_bytes(args.ledger.read_bytes())
    log(f"ledger: test scoring started ({started['entry_sha256'][:12]})")
    train_lo = pd.Timestamp(meta["split"]["train"][0])
    frames, statics, _, info = load_frames(args.data, train_lo - WARMUP, TEST_END, 0, ",".join(spec["cell_ids"]))
    if info["canonical_sha256"] != meta["data"]["canonical_sha256"]:
        raise SystemExit("data differ from the final phase (canonical sha256); refusing to score test")
    tables = build_tables(frames, train_lo, with_loyo=False)
    cdata = make_cdata(frames, statics, tables, train_lo)
    del frames
    smeta, loaded, climate, policy, calibration = load_artifact(out)
    for cid in spec["cell_ids"]:
        if any(not np.allclose(climate["cells"][cid][k], tables["clim"][cid][k], atol=1e-5) for k in M.CLIM_KEYS):
            raise SystemExit(f"train-period climatology changed for {cid}; refusing to score test")
    models = {(name, mode, kind): booster for name, pair in loaded.items() for kind, (mode, booster) in pair.items()}
    chosen = {kind: {name: pair[kind][0] for name, pair in loaded.items()} for kind in ("long", "short")}
    folds = json.loads((out / "spatial_folds.json").read_text(encoding="utf-8"))["folds"]
    fold_models, done_folds = load_fold_models(args.spatial_dir or out.parent / f"{out.name}_spatial", meta, folds)
    comps = Comparators({"v1", "v2", "v3"}, args)
    grid = eval_grid(cdata, models, int(spec["issue_stride_hours"]), TEST_START, TEST_END, args, comps,
                     fold_models=fold_models)
    rename_chosen(grid, chosen)
    apply_policy_grid(grid, policy, calibration, use_window=True)
    ungated = {}
    seasons = S.season_of(grid["month"])
    for name in S.INTERVAL_TARGETS:
        rule = (policy.get("intervals") or {}).get(name)
        scale = np.ones(len(grid["h"])) if not rule or rule["method"] == "unnormalized" else grid[f"std_{name}"]
        ungated[name] = S.interval_bounds(name, grid[f"served_{name}"].astype(float), scale, grid["h"], seasons, rule,
                                          gated=False)
    everything = np.ones(len(grid["h"]), dtype=bool)
    clean = grid["issue_time"] >= hours(V3_CLEAN_START)
    B = int(spec["bootstrap"]["B"])  # pre-committed in test_spec.json
    test_eval = evaluation_report(grid, "served", B=B)
    figures = out / "figures"
    cal_rep = calibration_report(grid, policy, everything, figures)
    int_rep = interval_report(grid, everything, ungated)
    jumps = jump_report(grid)
    blend = blend_report(grid, clean)
    spatial = spatial_report(grid, done_folds, everything)
    by_v3_window = v3_window_split(grid, ungated)
    skill_h = skill_by_horizon(grid, everything, B)
    summary_figures(figures, test_eval, int_rep, jumps, skill_h)
    criteria = {
        "rain_calibration": {b: e.get("criterion_met") for b, e in cal_rep.items() if "criterion_met" in e},
        "interval_coverage_within_0.05": {n: {b: e[b].get("coverage_within_0.05") for b in S.BANDS
                                              if e.get(b, {}).get("n")} for n, e in int_rep.items()},
        "interval_beats_clim_B1_B4": {n: {b: e[b].get("beats_clim_interval") for b in ("B1", "B2", "B3", "B4")
                                          if e.get(b, {}).get("n")} for n, e in int_rep.items()},
        "jump_ratio_le_1.5": {n: e.get("criterion_met") for n, e in jumps.items()},
        "significant_vs_best_baseline": {n: {b: e["by_band"][b].get("significant") for b in S.BANDS}
                                         for n, e in test_eval.items()}}
    test_report = {"program": PROGRAM, "model_version": meta["model_version"], "test_spec_sha256":
                   meta["test_spec_sha256"], "window": spec["window"], "issue_stride_hours": spec["issue_stride_hours"],
                   "rows": int(len(grid["h"])), "by_band": {n: e["by_band"] for n, e in test_eval.items()},
                   "calibration": cal_rep, "intervals": int_rep, "jumps": jumps, "v3_blend": blend,
                   "calibration_intervals_by_v3_window": by_v3_window,
                   "spatial": spatial, "skill_by_horizon": {n: {k: [fin(v) for v in s[k]] for k in s}
                                                            for n, s in skill_h.items()},
                   "criteria": criteria, "comparator_notes": comps.notes,
                   "claims_rule": "'better than X' only where significant=true (95 % CI upper < 0); otherwise "
                                  "'not distinguishable'"}
    write_json(out / "test_report.json", test_report)
    for name in M.TARGETS:
        report[name]["test"] = test_eval[name]
        report[name]["test"]["baselines_extra"] = {"definitions": spec["baselines"]}
        report[name]["test"]["bootstrap_ci"] = {"by_band": "see by_band[band].delta", **spec["bootstrap"]}
        if name == "rain_probability":
            report[name]["test"]["calibration"] = cal_rep
        if name in int_rep:
            report[name]["test"]["intervals"] = int_rep[name]
        report[name]["test"]["spatial_holdout"] = {f: v["targets"].get(name) for f, v in spatial.items()
                                                   if isinstance(v, dict)}
    write_json(out / "evaluation.json", report)
    result_sha = sha256_file(out / "test_report.json")
    entry = ledger_append(args.ledger, {"program": PROGRAM, "status": "completed",
                                        "started_entry_sha256": started["entry_sha256"],
                                        "model_version": meta["model_version"],
                                        "test_spec_sha256": meta["test_spec_sha256"],
                                        "code_sha256": sha256_json(code_hashes()),
                                        "data_sha256": info["canonical_sha256"],
                                        "scored_at": datetime.now(timezone.utc).isoformat(),
                                        "result_sha256": result_sha, "window": spec["window"]})
    (out / "test_ledger.jsonl").write_bytes(args.ledger.read_bytes())
    meta["test_scoring"] = {"scored_at": entry["scored_at"], "issue_stride_hours": spec["issue_stride_hours"],
                            "elapsed_seconds": round(time.monotonic() - _START, 1),
                            "peak_rss_mib": round(rss_mib(), 1), "num_threads": args.threads,
                            "ledger_entry_sha256": entry["entry_sha256"], "result_sha256": result_sha,
                            "spatial_folds_scored": sorted(done_folds)}
    write_json(out / "metadata.json", meta, indent=2)
    log(f"test scored once; ledger entry {entry['entry_sha256'][:12]}")


# -------------------------------------------------------------------------------------- verify phase
def phase_verify(args):
    out = args.out
    problems, warnings = [], []
    if (out / "MANIFEST.sha256").exists():
        problems += check_manifest(out)
    else:
        problems.append("MANIFEST.sha256 missing")
    meta = json.loads((out / "metadata.json").read_text(encoding="utf-8"))
    version = meta["model_version"]
    for file in ("climatology.json", "serving_policy.json", "calibration.json", "test_spec.json",
                 "parity_cases.json", "spatial_folds.json", "test_report.json"):
        p = out / file
        if not p.exists():
            problems.append(f"missing {file}")
        elif json.loads(p.read_text(encoding="utf-8")).get("model_version") != version:
            problems.append(f"model_version mismatch in {file}")
    if sha256_file(out / "test_spec.json") != meta.get("test_spec_sha256"):
        problems.append("test_spec.json sha256 differs from metadata.json")
    try:
        entries = ledger_verify(out / "test_ledger.jsonl")
        mine = [e for e in entries if e.get("program") == PROGRAM]
        started = [e for e in mine if e.get("status") == "started"]
        done = [e for e in mine if e.get("status") == "completed"]
        if len(started) != 1 or len(done) > 1 or len(mine) != len(started) + len(done):
            problems.append(f"ledger must hold one 'started' and one 'completed' {PROGRAM} entry "
                            f"(found {len(started)} started, {len(done)} completed, {len(mine)} total)")
        elif not done:
            problems.append("test scoring was started but never completed (interrupted run); the test window is "
                            "consumed for this program and cannot be re-scored")
        elif any(e["model_version"] != version or e["test_spec_sha256"] != meta.get("test_spec_sha256")
                 for e in mine) or done[0].get("started_entry_sha256") != started[0]["entry_sha256"]:
            problems.append("ledger entry does not match this artifact")
        elif not (out / "test_report.json").exists() or done[0]["result_sha256"] != sha256_file(
                out / "test_report.json"):
            problems.append("test_report.json missing or differs from the ledger result hash")
    except ValueError as exc:
        problems.append(str(exc))
    local = library_versions()
    for lib, v in meta.get("versions", {}).items():
        if lib in ("platform", "pip_freeze_sha256"):
            continue
        if local.get(lib) != v:
            warnings.append(f"{lib}: trained {v}, local {local.get(lib)}")
    lgb_t = ".".join(str(meta.get("versions", {}).get("lightgbm", "")).split(".")[:2])
    lgb_l = ".".join(local["lightgbm"].split(".")[:2])
    if lgb_t != lgb_l:
        problems.append(f"LightGBM major.minor differs (trained {lgb_t}, local {lgb_l})")
    parity = {}
    e2e = {}
    try:
        smeta, models, climate, policy, calibration = load_artifact(out)
        cases = json.loads((out / "parity_cases.json").read_text(encoding="utf-8"))
        worst = {}
        db_frames = load_window_frames(args.data, cases)
        for case in cases["cases"]:
            cid, issue = case["cell_id"], pd.Timestamp(case["issue_time"])
            raw = db_frames[cid]
            idx = int(np.flatnonzero(raw.timestamp.to_numpy() == issue.to_datetime64())[0])
            hist = S._prepare(raw.iloc[idx - M.MIN_HISTORY_HOURS + 1: idx + 1], cid)
            got, _ = S.forecast_arrays(hist, cid, smeta, models, climate, policy, calibration, use_v3=True)
            for k, v in compare_case(case["expected"], got).items():
                worst[k] = max(worst.get(k, 0.0), v)
        overall = max(worst.values()) if worst else float("inf")
        parity = {"cases": len(cases["cases"]), "max_abs_diff": {k: fin(v, 9) for k, v in worst.items()},
                  "max_abs_diff_overall": fin(overall, 9), "passed": bool(overall <= 1e-4)}
        if not parity["passed"]:
            problems.append(f"parity failed: max |diff| {overall}")
        os.environ["LONG_RANGE_V21_MODEL_DIR"] = str(out.resolve())
        S._load.cache_clear()
        latest = load_latest_frames(args.data, sorted(meta["cell_static"]))
        ok = fails = 0
        fallbacks = {}
        for cid, hist in latest.items():
            try:
                res = S.predict(hist, cid)
                ok += 1
                for f in res["policy_fallbacks"]:
                    fallbacks[f] = fallbacks.get(f, 0) + 1
            except ValueError as exc:
                fails += 1
                fallbacks[f"error: {str(exc)[:60]}"] = fallbacks.get(f"error: {str(exc)[:60]}", 0) + 1
        e2e = {"cells_ok": ok, "cells_failed": fails, "fallbacks": fallbacks}
        if fails:
            problems.append(f"end-to-end predict failed for {fails} cells")
    except Exception as exc:  # noqa: BLE001 - verify reports every failure
        problems.append(f"verify error: {type(exc).__name__}: {exc}")
    result = {"artifact": str(out), "model_version": version, "passed": not problems, "problems": problems,
              "warnings": warnings, "parity": parity, "end_to_end": e2e}
    print(json.dumps(result, indent=1))
    if problems:
        raise SystemExit(1)


def load_window_frames(data: Path, cases):
    """Contiguous frames covering every parity issue's 48h history (read-only)."""
    times = [pd.Timestamp(c["issue_time"]) for c in cases["cases"]]
    lo, hi = min(times) - pd.Timedelta(hours=M.MIN_HISTORY_HOURS + 1), max(times)
    wanted = sorted({c["cell_id"] for c in cases["cases"]})
    frames, _, _, _ = load_frames(data, lo, hi, 0, ",".join(wanted))
    return frames


def load_latest_frames(data: Path, ids):
    """Last 48 complete hours (common latest hour of the cells) for the end-to-end predict check."""
    if data.is_dir():
        manifest = json.loads((data / "manifest.json").read_text(encoding="utf-8"))
        last = pd.Timestamp(manifest["last_hour"])
    else:
        with connect(data) as con:
            last = pd.Timestamp(con.execute("SELECT MAX(timestamp) FROM hourly").fetchone()[0])
    frames, _, _, _ = load_frames(data, last - pd.Timedelta(hours=24 * 7), last, 0, ",".join(ids))
    out = {}
    for cid, raw in frames.items():
        ok = raw[list(M.WEATHER_FEATURES)].notna().all(axis=1).to_numpy()
        end = int(np.flatnonzero(ok)[-1]) if ok.any() else -1
        out[cid] = raw.iloc[max(end - M.MIN_HISTORY_HOURS + 1, 0): end + 1]
    return out


# ---------------------------------------------------------------------------------------------- main
def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data", type=Path, default=BACKEND / "data/history/cells_history.db",
                   help="SQLite DB (read-only) or exported data directory")
    p.add_argument("--out", type=Path, help="dev: output dir; final/test/spatial/verify: artifact dir")
    p.add_argument("--phase", choices=("dev", "final", "spatial", "test", "verify"))
    p.add_argument("--verify-artifacts", type=Path, help="alias of --phase verify --out DIR")
    p.add_argument("--selection", type=Path, help="final: dev_selection.json")
    p.add_argument("--modes", default="", help="final override: name=mode,... (needs --override-reason)")
    p.add_argument("--short-modes", default="", help="final override for the 1..36h booster")
    p.add_argument("--override-reason", default="")
    p.add_argument("--ledger", type=Path, help="global write-once test ledger (jsonl)")
    p.add_argument("--spatial-dir", type=Path, help="fold boosters (Drive); default <out>_spatial")
    p.add_argument("--dev-kinds", default="long,short")
    p.add_argument("--no-compare-train-start", dest="compare_train_start", action="store_false")
    p.add_argument("--short-stride", type=int, default=3)
    p.add_argument("--short-k", type=int, default=3)
    p.add_argument("--train-stride", type=int, default=3)
    p.add_argument("--k", type=int, default=4)
    p.add_argument("--es-stride", type=int, default=5)
    p.add_argument("--val-stride", type=int, default=7)
    p.add_argument("--test-stride", type=int, default=23)
    p.add_argument("--learning-rate", type=float, default=0.05)
    p.add_argument("--min-data-in-leaf", type=int, default=200)
    p.add_argument("--max-rounds", type=int, default=4000)
    p.add_argument("--patience", type=int, default=100)
    p.add_argument("--bootstrap", type=int, default=BOOT_B)
    p.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 1))
    p.add_argument("--colab", action="store_true", help="allow more than 4 threads")
    p.add_argument("--cells", type=int, default=0, help="debug: first N cells only")
    p.add_argument("--cell-ids", default="", help="debug: explicit comma-separated cells")
    p.add_argument("--smoke", action="store_true", help="tiny strides/rounds for a quick end-to-end check")
    p.add_argument("--allow-missing-v3", action="store_true")
    p.add_argument("--seed", type=int, default=SEED)
    return p


SMOKE = {"train_stride": 211, "k": 2, "short_stride": 211, "short_k": 2, "es_stride": 97, "val_stride": 61,
         "max_rounds": 25, "patience": 5, "min_data_in_leaf": 20}


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.verify_artifacts:
        args.phase, args.out = "verify", args.verify_artifacts
    if not args.phase or not args.out:
        parser.error("--phase and --out are required")
    if args.smoke:
        for k, v in SMOKE.items():
            setattr(args, k, v)
    limit = (os.cpu_count() or 1) if args.colab else 4
    if not 1 <= args.threads <= limit:
        parser.error(f"--threads must be 1..{limit}" + ("" if args.colab else " (use --colab on Colab)"))
    if args.seed != SEED:
        parser.error("the protocol fixes seed 42")
    {"dev": phase_dev, "final": phase_final, "spatial": phase_spatial, "test": phase_test,
     "verify": phase_verify}[args.phase](args)


if __name__ == "__main__":
    main()
