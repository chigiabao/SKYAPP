"""Direct 1..168h models v2.1: v2 features and boosters + validation-fitted serving layers.

Same public interface as long_range_model_v2 (predict, status, artifact_revision, MAX_HORIZON,
MIN_HISTORY_HOURS, RAIN_THRESHOLD_MM, TARGETS). The feature set is unchanged (v2 helpers are
reused), so the boosters see exactly what v2 sees: the last 48 hourly rows of the cell plus
train-period climatology. No external forecasts.

Differences to v2 (all serving parameters are fitted on VAL_CAL = 2024-10-14..2024-12-24 only):
  * short booster covers 1..36h and is handed over to the long booster by a 3-parameter taper
    w(h) = w0 (h <= a), linear to 0 at b, 0 after (serving_policy.json targets[name].taper);
  * V3 (1/3/6h) is added as a correction c(h) = w_k (V3_k - v21_k) at the anchors, linear between
    anchors and tapered to 0 at 9h ("stitched") or applied at the anchors only;
  * V3 is skipped for issues inside V3's own selection window (<= 2025-09-23 23:00): fallback
    "v3_knowledge_window";
  * served rain probability is calibrated per horizon band (Platt / isotonic breakpoints stored in
    calibration.json, evaluated with np.interp; no pickles) where the validation gate passed;
  * p10/p90 (precipitation: p90) from normalized split-conformal quantiles, exposed only for
    target x band pairs whose cross-fitted validation coverage passed the gate.
An 80 % interval that covers ~80 % of outcomes is a calibration statement, not 80 % accuracy.
Naive timestamps mean Asia/Ho_Chi_Minh. Text boosters only, never unpickled here.
"""
from __future__ import annotations

import json
import logging
import os
from functools import lru_cache
from pathlib import Path

import numpy as np
import pandas as pd

import long_range_model_v2 as V2
from long_range_model_v2 import (  # noqa: F401 - re-exported helpers keep the v2 meaning
    CLIM_KEYS, MAX_HORIZON, MIN_HISTORY_HOURS, RAIN_THRESHOLD_MM, STATIC_FEATURES, TARGET_CLIM,
    TARGET_MODES, TARGETS, TIMEZONE, WEATHER_FEATURES, _prepare, bounded, clim_values, feature_columns,
    horizon_rows, issue_features, issue_state, local_iso, logit, model_output, timestamps, v3_component,
    v3_values)

logger = logging.getLogger(__name__)

SCHEMA_VERSION = 3
SHORT_MAX_HORIZON = 36
DEFAULT_MODEL_DIR = Path(__file__).resolve().parent / "models" / "long_range_v21"
MODEL_VERSION_PREFIX = "lgbm-direct-168h-v21-"
V3_ANCHORS = (1, 3, 6)
V3_STITCH_END = 9  # correction tapers linearly to 0 at this horizon
V3_KNOWLEDGE_END = pd.Timestamp("2025-09-23 23:00")  # end of V3 val_select (metadata_v3.json)
BANDS = {"B1": (1, 6), "B2": (7, 24), "B3": (25, 48), "B4": (49, 72), "B5": (73, 120), "B6": (121, 168)}
INTERVAL_TARGETS = ("temperature", "humidity", "wind_speed", "cloud_cover", "precipitation_mm")
UPPER_ONLY = ("precipitation_mm",)
INTERVAL_LEVEL = 0.8
CAL_CLIP = (0.001, 0.999)
INTERVAL_METHODS = ("unnormalized", "normalized", "mondrian_season")


def _window_stat(values: np.ndarray, size: int, stat: str) -> np.ndarray:
    """Mean/std over each trailing window, computed from that window alone (NaN until it is full)."""
    out = np.full(len(values), np.nan)
    if len(values) >= size:
        windows = np.lib.stride_tricks.sliding_window_view(values, size)
        with np.errstate(invalid="ignore"):
            out[size - 1:] = windows.mean(axis=1) if stat == "mean" else windows.std(axis=1, ddof=1)
    return out


def stable_issue_features(history: pd.DataFrame, static: dict, clim: dict) -> pd.DataFrame:
    """v2 issue_features with window-local rolling mean/std.

    pandas' rolling sums carry rounding error from every earlier row, so the trainer (full multi-year
    series) and serving (48 rows) could round a value like x.xxxxx5 differently and flip a tree split.
    Computing each window on its own makes the feature identical for any history length.
    """
    frame = issue_features(history, static, clim)
    for name in WEATHER_FEATURES:
        s = (pd.to_numeric(history[name], errors="coerce") if name in history
             else pd.Series(np.nan, index=history.index)).astype(float).replace([np.inf, -np.inf], np.nan)
        values = s.to_numpy()
        for col, size, stat in ((f"{name}_mean_6", 6, "mean"), (f"{name}_mean_24", 24, "mean"),
                                (f"{name}_std_24", 24, "std")):
            frame[col] = np.round(_window_stat(values, size, stat), 5).astype(np.float32)
    return frame


def band_index(horizons) -> np.ndarray:
    """0-based band index (B1..B6) of each horizon."""
    h = np.asarray(horizons)
    edges = np.array([hi for _, hi in BANDS.values()])
    return np.searchsorted(edges, h, side="left")


def band_of(h: int) -> str:
    return list(BANDS)[int(band_index([h])[0])]


def season_of(months) -> np.ndarray:
    """'dry' for Dec-Apr, 'wet' for May-Nov (HCMC)."""
    m = np.asarray(months)
    return np.where((m >= 5) & (m <= 11), "wet", "dry")


def taper_weights(taper: dict, hmax: int = SHORT_MAX_HORIZON) -> np.ndarray:
    """Per-hour short-booster weights for h = 1..hmax: w0 up to a, linear to 0 at b, 0 after."""
    w0, a, b = float(taper["w0"]), int(taper["a"]), int(taper["b"])
    if not (0 <= w0 <= 1 and 1 <= a < b <= hmax):
        raise ValueError(f"invalid taper {taper}")
    h = np.arange(1, hmax + 1, dtype=float)
    return np.where(h <= a, w0, np.where(h >= b, 0.0, w0 * (b - h) / (b - a)))


def blend_taper(name: str, long_values, short_values, taper: dict | None) -> np.ndarray:
    """v2.1 value (n x 168): long booster, blended with the short booster (n x >=36) by the taper."""
    out = np.array(long_values, dtype=float, ndmin=2, copy=True)
    if short_values is None or not taper:
        return bounded(name, out)
    short = np.array(short_values, dtype=float, ndmin=2)[:, :SHORT_MAX_HORIZON]
    w = taper_weights(taper)
    out[:, :SHORT_MAX_HORIZON] = w * short + (1 - w) * out[:, :SHORT_MAX_HORIZON]
    return bounded(name, out)


def v3_correction(v21, v3_anchor, weights: dict, stitched: bool) -> np.ndarray:
    """Additive correction c (n x 168). v3_anchor: n x 3 V3 values at 1/3/6h (NaN = not answered,
    c = 0 at that anchor). c(k) = w_k (V3_k - v21_k); stitched: linear between anchors, linear to 0 at 9h."""
    v21 = np.array(v21, dtype=float, ndmin=2)
    v3a = np.array(v3_anchor, dtype=float, ndmin=2)
    c = np.zeros_like(v21)
    anchors = np.zeros((len(v21), len(V3_ANCHORS)))
    for j, k in enumerate(V3_ANCHORS):
        w = float(weights.get(f"{k}h", 0.0))
        d = v3a[:, j] - v21[:, k - 1]
        anchors[:, j] = np.where(np.isfinite(d), w * d, 0.0)
    if not stitched:
        for j, k in enumerate(V3_ANCHORS):
            c[:, k - 1] = anchors[:, j]
        return c
    xs = np.array([*V3_ANCHORS, V3_STITCH_END], dtype=float)
    for i in range(len(v21)):
        ys = np.append(anchors[i], 0.0)
        c[i, :V3_STITCH_END] = np.interp(np.arange(1, V3_STITCH_END + 1), xs, ys)
    return c


def serve_values(name: str, long_values, short_values, v3_anchor, rule: dict, use_v3: bool = True):
    """(v2.1 value, served value before rain calibration), both n x 168 and bounded."""
    v21 = blend_taper(name, long_values, short_values, rule.get("taper"))
    v3 = (rule.get("v3") or {})
    if not use_v3 or not v3.get("weights") or v3_anchor is None:
        return v21, v21.copy()
    c = v3_correction(v21, v3_anchor, v3["weights"], bool(v3.get("stitched")))
    return v21, bounded(name, v21 + c)


def calibrator_apply(p, cal: dict) -> np.ndarray:
    """Calibrated probability of one band calibrator (JSON parameters), clipped to CAL_CLIP."""
    p = np.asarray(p, dtype=float)
    method = cal.get("method", "none")
    if method == "none":
        return p.copy()
    if method == "platt":
        z = float(cal["a"]) * logit(p) + float(cal["b"])
        out = 1.0 / (1.0 + np.exp(-z))
    elif method == "isotonic":
        out = np.interp(p, np.asarray(cal["x"], float), np.asarray(cal["y"], float))
    else:
        raise ValueError(f"unknown calibration method {method}")
    return np.clip(out, *CAL_CLIP)


def calibrate_rain(p, calibration: dict, serve_flags: dict, horizons=None) -> np.ndarray:
    """Served rain probability (n x 168 or 1-D over horizons): calibrated where serve_flags[band]."""
    p = np.array(p, dtype=float, ndmin=2)
    h = np.arange(1, p.shape[1] + 1) if horizons is None else np.asarray(horizons)
    out = p.copy()
    bands = band_index(h)
    for b, band in enumerate(BANDS):
        if not serve_flags.get(band):
            continue
        cols = bands == b
        out[:, cols] = calibrator_apply(p[:, cols], calibration["bands"][band])
    return np.clip(out, 0.0, 1.0)


def interval_scale(std_table, valid_times, method: str) -> np.ndarray:
    """Conformal scale at valid times: train-period anomaly std (normalized methods) or 1."""
    if method == "unnormalized":
        return np.ones(len(pd.DatetimeIndex(valid_times)))
    return clim_values(std_table, valid_times)


def interval_bounds(name: str, values, scale, horizons, seasons, rule: dict | None, gated: bool = True):
    """Vectorised (p10, p90) for aligned 1-D arrays (value, conformal scale, horizon, season of valid time).
    NaN where the band gate failed (gated=False ignores the gate, for diagnostics only).
    p10 <= value <= p90 and target bounds are enforced; precipitation has no p10 (NaN)."""
    values = np.asarray(values, dtype=float)
    scale = np.asarray(scale, dtype=float)
    seasons = np.asarray(seasons)
    lo = np.full(len(values), np.nan)
    hi = np.full(len(values), np.nan)
    if not rule:
        return lo, hi
    bands = band_index(horizons)
    for b, band in enumerate(BANDS):
        entry = rule["bands"].get(band)
        if not entry or (gated and not entry.get("served")):
            continue
        groups = [(bands == b, entry)]
        if rule["method"] == "mondrian_season":
            groups = [((bands == b) & (seasons == s), (entry.get("by_season") or {}).get(s, entry))
                      for s in ("dry", "wet")]
        for cols, q in groups:
            if not cols.any():
                continue
            v, s = values[cols], scale[cols]
            hi[cols] = np.maximum(v, bounded(name, v + float(q["q_hi"]) * s))
            if name not in UPPER_ONLY:
                lo[cols] = np.minimum(v, bounded(name, v + float(q["q_lo"]) * s))
    return lo, hi


def intervals(name: str, values, valid_times, std_table, rule: dict | None):
    """(p10, p90) over the 168 horizons of one issue (see interval_bounds)."""
    values = np.asarray(values, dtype=float)
    if not rule:
        return np.full(len(values), np.nan), np.full(len(values), np.nan)
    valid = pd.DatetimeIndex(valid_times)
    return interval_bounds(name, values, interval_scale(std_table, valid, rule["method"]),
                           np.arange(1, len(values) + 1), season_of(valid.month), rule)


def _directory() -> Path:
    return Path(os.environ.get("LONG_RANGE_V21_MODEL_DIR", DEFAULT_MODEL_DIR))


REVISION_FILES = ("metadata.json", "serving_policy.json", "climatology.json", "calibration.json")


def artifact_revision() -> tuple[str, int]:
    """(artifact path, combined mtime stamp) incl. models/v3/metadata_v3.json so V3 changes invalidate caches."""
    path = _directory().resolve()
    stamp = 0
    files = [path / f for f in REVISION_FILES] + [Path(__file__).resolve().parent / "models" / "v3" /
                                                   "metadata_v3.json"]
    for i, file in enumerate(files):
        try:
            stamp = (stamp * 1_000_003 + file.stat().st_mtime_ns + i) % (1 << 62)
        except (FileNotFoundError, NotADirectoryError):
            continue
    try:
        (path / "metadata.json").stat()
    except (FileNotFoundError, NotADirectoryError):
        return str(path), 0
    return str(path), stamp


def _check_policy(policy: dict, meta: dict) -> None:
    if policy.get("model_version") != meta["model_version"] or not isinstance(policy.get("targets"), dict):
        raise ValueError("serving_policy.json does not match model_version")
    for name, rule in policy["targets"].items():
        if name not in TARGETS or not isinstance(rule, dict):
            raise ValueError(f"invalid policy target {name}")
        if rule.get("taper"):
            taper_weights(rule["taper"])
        v3 = rule.get("v3") or {}
        weights = v3.get("weights", {})
        for key, w in weights.items():
            if key not in ("1h", "3h", "6h") or not 0 <= float(w) <= 1:
                raise ValueError(f"invalid V3 weight for {name} {key}")
        ws = [float(weights.get(f"{k}h", 0.0)) for k in V3_ANCHORS]
        if not ws[0] >= ws[1] >= ws[2]:
            raise ValueError(f"V3 weights must satisfy w(1) >= w(3) >= w(6) for {name}")
    for name, rule in (policy.get("intervals") or {}).items():
        if name not in INTERVAL_TARGETS or rule.get("method") not in INTERVAL_METHODS:
            raise ValueError(f"invalid interval rule for {name}")
        for band, entry in rule["bands"].items():
            if band not in BANDS or not np.isfinite([float(entry["q_lo"]), float(entry["q_hi"])]).all():
                raise ValueError(f"invalid interval quantiles for {name} {band}")
    flags = policy.get("serve_calibrated_rain") or {}
    if set(flags) - set(BANDS):
        raise ValueError("invalid rain calibration bands")


def _check_calibration(calibration: dict, meta: dict, flags: dict) -> None:
    if calibration.get("model_version") != meta["model_version"]:
        raise ValueError("calibration.json does not match model_version")
    for band in BANDS:
        cal = (calibration.get("bands") or {}).get(band)
        if cal is None:
            raise ValueError(f"missing calibrator for {band}")
        if cal.get("method") == "isotonic":
            x, y = np.asarray(cal["x"], float), np.asarray(cal["y"], float)
            if x.shape != y.shape or len(x) < 2 or (np.diff(x) < 0).any() or (np.diff(y) < 0).any():
                raise ValueError(f"isotonic calibrator for {band} must be monotone")
        elif cal.get("method") == "platt":
            if not float(cal["a"]) > 0:
                raise ValueError(f"Platt slope for {band} must be positive (monotone)")
        elif cal.get("method") != "none":
            raise ValueError(f"unknown calibrator for {band}")
        if flags.get(band) and cal.get("method") == "none":
            raise ValueError(f"band {band} served calibrated without a calibrator")


@lru_cache(maxsize=2)
def _load(directory: str, modified: int):
    import lightgbm as lgb
    path = Path(directory)
    meta = json.loads((path / "metadata.json").read_text(encoding="utf-8"))
    if (meta["schema_version"] != SCHEMA_VERSION or meta["feature_columns"] != feature_columns()
            or meta["max_horizon_hours"] != MAX_HORIZON or not meta["cell_static"]):
        raise ValueError("incompatible artifact schema")
    if not str(meta.get("model_version", "")).startswith(MODEL_VERSION_PREFIX):
        raise ValueError("missing or foreign model_version")
    cutoff = pd.Timestamp(meta["trained_through"])
    if pd.isna(cutoff) or cutoff.tzinfo is None:
        raise ValueError("trained_through must have an explicit timezone")
    for key in ("fit_labels_through", "selection_labels_through"):
        if key in meta and pd.Timestamp(meta[key]) > cutoff:
            raise ValueError(f"trained_through precedes {key}")
    climate = json.loads((path / "climatology.json").read_text(encoding="utf-8"))
    if climate.get("model_version") != meta["model_version"]:
        raise ValueError("climatology.json does not match model_version")
    for cid, cell in meta["cell_static"].items():
        if not all(np.isfinite(float(cell[k])) for k in STATIC_FEATURES):
            raise ValueError("non-finite cell coordinates/elevation")
        tables = climate["cells"].get(cid, {})
        if set(tables) != set(CLIM_KEYS) or any(np.asarray(t, float).shape != (288,) or not
                                                np.isfinite(np.asarray(t, float)).all() for t in tables.values()):
            raise ValueError(f"invalid climatology for {cid}")
        std = climate.get("std", {}).get(cid, {})
        if set(std) != set(INTERVAL_TARGETS) or any(np.asarray(t, float).shape != (288,) or not
                                                    (np.asarray(t, float) > 0).all() for t in std.values()):
            raise ValueError(f"invalid std tables for {cid}")
    for name in TARGETS:
        rho = np.asarray(climate["rho"][name], dtype=float)
        if rho.shape != (MAX_HORIZON,) or not np.isfinite(rho).all():
            raise ValueError(f"invalid damping coefficients for {name}")
    policy = json.loads((path / "serving_policy.json").read_text(encoding="utf-8"))
    _check_policy(policy, meta)
    calibration = json.loads((path / "calibration.json").read_text(encoding="utf-8"))
    _check_calibration(calibration, meta, policy.get("serve_calibrated_rain") or {})
    short = meta.get("short_range") or {}
    short_modes = short.get("target_mode", {})
    if short_modes and short.get("max_horizon_hours") != SHORT_MAX_HORIZON:
        raise ValueError("incompatible short-range horizon")
    models = {}
    for name in TARGETS:
        cap = meta["capabilities"][name]
        if cap["status"] == "available":
            pair = {}
            for kind, mode, file in (("long", meta["target_mode"][name], f"{name}.txt"),
                                     ("short", short_modes.get(name), f"{name}_short.txt")):
                if kind == "short" and mode is None:
                    continue
                if mode not in TARGET_MODES:
                    raise ValueError(f"invalid {kind} target mode for {name}")
                model = lgb.Booster(model_file=str(path / file))
                if model.feature_name() != feature_columns():
                    raise ValueError(f"feature mismatch for {name} ({kind})")
                pair[kind] = (mode, model)
            models[name] = pair
        elif cap["status"] != "unsupported":
            raise ValueError(f"invalid capability for {name}")
    if not models:
        raise ValueError("artifact contains no trained targets")
    return meta, models, climate, policy, calibration


def _loaded():
    path = _directory()
    return _load(str(path.resolve()), artifact_revision()[1])


def status() -> dict:
    """Distinguish absent/broken artifacts from unsupported training targets."""
    path = _directory()
    manifest = path / "metadata.json"
    try:
        state = "untrained" if not path.exists() or (path.is_dir() and not any(path.iterdir())) else "unavailable"
        if not manifest.exists():
            return {"status": state, "reason": "missing metadata.json", "source": "ai",
                    "cell_ids": [], "capabilities": {n: {"status": state} for n in TARGETS}}
        meta = _loaded()[0]
        return {"status": "available", "source": "ai", "model_version": meta["model_version"],
                "trained_through": meta["trained_through"], "cell_ids": sorted(meta["cell_static"]),
                "capabilities": meta["capabilities"], "max_horizon_hours": MAX_HORIZON,
                "limitations": meta.get("limitations", [])}
    except Exception as exc:
        return {"status": "unavailable", "source": "ai", "reason": str(exc), "cell_ids": [],
                "capabilities": {n: {"status": "unavailable"} for n in TARGETS}}


def booster_arrays(hist: pd.DataFrame, cell_id: str, meta, models, climate) -> dict:
    """{target: (long 168 values, short 36 values or None)} for one prepared 48h history."""
    clim = climate["cells"][cell_id]
    base = stable_issue_features(hist, meta["cell_static"][cell_id], clim).iloc[[-1]]
    state = issue_state(hist, clim).iloc[[-1]]
    horizons = np.arange(1, MAX_HORIZON + 1)
    x, bases = horizon_rows(pd.concat([base] * MAX_HORIZON, ignore_index=True),
                            pd.concat([state] * MAX_HORIZON, ignore_index=True),
                            [hist.timestamp.iloc[-1]] * MAX_HORIZON, horizons, clim, climate["rho"])
    out = {}
    short = slice(0, SHORT_MAX_HORIZON)
    for name, pair in models.items():
        mode, model = pair["long"]
        long_values = model_output(name, mode, model, x, bases[name][mode])
        short_values = None
        if "short" in pair:
            mode, model = pair["short"]
            short_values = model_output(name, mode, model, x.iloc[short], bases[name][mode][short])
        out[name] = (long_values, short_values)
    return out


def forecast_arrays(hist: pd.DataFrame, cell_id: str, meta, models, climate, policy, calibration,
                    v3_lookup=v3_component, use_v3: bool = True, info: dict | None = None) -> tuple[dict, list]:
    """Served arrays (index = horizon-1) for one prepared 48h history; no replay guard here.

    Keys: every available target, rain_probability_raw, {target}_p10/_p90 (NaN where gated off).
    use_v3=False serves v2.1 alone at 1..9h and reports 'v3_knowledge_window'.
    info (optional dict) receives 'v3_applied': targets where a V3 anchor with weight > 0 was used."""
    raw = booster_arrays(hist, cell_id, meta, models, climate)
    rules = policy["targets"]
    fallbacks = []
    needs_v3 = [n for n in raw if any(float(w) > 0 for w in
                                      ((rules.get(n) or {}).get("v3") or {}).get("weights", {}).values())]
    v3 = None
    if needs_v3 and not use_v3:
        fallbacks.append("v3_knowledge_window")
    elif needs_v3:
        try:
            v3 = v3_lookup(hist, cell_id)
        except Exception as exc:  # noqa: BLE001 - V3 is optional; v2.1 alone stays a valid own forecast
            fallbacks.append(f"v3_unavailable: {type(exc).__name__}")
    values = {}
    applied = []
    for name, (long_values, short_values) in raw.items():
        rule = rules.get(name) or {}
        anchor = None
        if name in needs_v3 and v3 is not None:
            anchor = np.full((1, len(V3_ANCHORS)), np.nan)
            missing = []
            for j, k in enumerate(V3_ANCHORS):
                value = (v3.get(k) or {}).get(name)
                if value is not None and np.isfinite(float(value)):
                    anchor[0, j] = float(value)
                elif float(rule["v3"]["weights"].get(f"{k}h", 0)) > 0:
                    missing.append(f"{k}h")
            if missing:
                fallbacks.append(f"v3_missing_{name}: {','.join(missing)}")
            if any(np.isfinite(anchor[0, j]) and float(rule["v3"]["weights"].get(f"{k}h", 0)) > 0
                   for j, k in enumerate(V3_ANCHORS)):
                applied.append(name)
        _, served = serve_values(name, long_values, short_values, anchor, rule, use_v3=anchor is not None)
        values[name] = served[0]
    if info is not None:
        info["v3_applied"] = applied
    issue = hist.timestamp.iloc[-1]
    valid = pd.DatetimeIndex([issue + pd.Timedelta(hours=h) for h in range(1, MAX_HORIZON + 1)])
    if "rain_probability" in values:
        values["rain_probability_raw"] = values["rain_probability"].copy()
        values["rain_probability"] = calibrate_rain(values["rain_probability"], calibration,
                                                    policy.get("serve_calibrated_rain") or {})[0]
    for name in INTERVAL_TARGETS:
        if name not in values:
            continue
        lo, hi = intervals(name, values[name], valid, climate["std"][cell_id][name],
                           (policy.get("intervals") or {}).get(name))
        values[f"{name}_p90"] = hi
        if name not in UPPER_ONLY:
            values[f"{name}_p10"] = lo
    return values, fallbacks


EXTRA_RECORD_KEYS = ("rain_probability_raw", "temperature_p10", "temperature_p90", "humidity_p10", "humidity_p90",
                     "wind_speed_p10", "wind_speed_p90", "cloud_cover_p10", "cloud_cover_p90",
                     "precipitation_mm_p90")


def _num(values: dict, key: str, i: int):
    arr = values.get(key)
    if arr is None or not np.isfinite(arr[i]):
        return None
    return round(float(arr[i]), 4)


def predict(history: pd.DataFrame, cell_id: str, v3_result: dict | None = None) -> dict:
    """Return predictions['1h'..'168h']; failures raise prefixed ValueError (as v2).

    v3_result: optional V3 output already computed by the caller for this exact history and cell.
    Reject issue <= trained_through (validation labels are model knowledge). Issues inside V3's own
    selection window (<= 2025-09-23 23:00) are served without V3 ('v3_knowledge_window').
    """
    info = status()
    if info["status"] != "available":
        raise ValueError(f"{info['status']}: {info.get('reason', 'artifact not ready')}")
    try:
        meta, models, climate, policy, calibration = _loaded()
    except Exception as exc:
        raise ValueError(f"unavailable: {exc}") from exc
    if cell_id not in meta["cell_static"] or cell_id not in climate["cells"]:
        raise ValueError(f"unsupported_cell: {cell_id}")
    try:
        hist = _prepare(history, cell_id)
    except Exception as exc:
        raise ValueError(f"invalid_history: {exc}") from exc
    issue = hist.timestamp.iloc[-1]
    if issue.tz_localize(TIMEZONE) <= pd.Timestamp(meta["trained_through"]):
        raise ValueError(f"replay_leakage: issue must be after {meta['trained_through']}")
    use_v3 = issue > V3_KNOWLEDGE_END
    lookup = v3_component if v3_result is None else (lambda *_: v3_values(v3_result))
    info = {}
    try:
        values, fallbacks = forecast_arrays(hist, cell_id, meta, models, climate, policy, calibration,
                                            lookup, use_v3=use_v3, info=info)
    except Exception as exc:
        raise ValueError(f"unavailable: {exc}") from exc
    if any(not np.isfinite(values[n]).all() for n in TARGETS if n in values):
        raise ValueError("unavailable: model returned non-finite predictions")
    for name in INTERVAL_TARGETS:
        if name in values:
            lo, hi, v = values.get(f"{name}_p10"), values[f"{name}_p90"], values[name]
            ok = ~np.isfinite(hi) | (hi >= v - 1e-9)
            if lo is not None:
                ok &= ~np.isfinite(lo) | (lo <= v + 1e-9)
            if not ok.all():
                raise ValueError(f"unavailable: interval ordering violated for {name}")
    if fallbacks:
        logger.warning("long_range_v21 policy fallbacks for %s at %s: %s", cell_id, issue, fallbacks)
    issued_at = local_iso(issue)
    records = {}
    for i, horizon in enumerate(range(1, MAX_HORIZON + 1)):
        records[f"{horizon}h"] = {
            "horizon_hours": horizon, "valid_at": local_iso(issue + pd.Timedelta(hours=horizon)),
            "issued_at": issued_at, "model_version": meta["model_version"], "source": "ai",
            **{name: round(float(values[name][i]), 4) if name in values else None for name in TARGETS},
            **{key: _num(values, key, i) for key in EXTRA_RECORD_KEYS},
        }
    return {"issued_at": issued_at, "model_version": meta["model_version"], "source": "ai",
            "trained_through": meta["trained_through"], "cell_id": cell_id,
            "capabilities": meta["capabilities"], "predictions": records,
            "hourly": list(records.values()), "limitations": meta.get("limitations", []),
            "policy_fallbacks": fallbacks, "interval_level": INTERVAL_LEVEL,
            "interval_method": _interval_method(policy),
            "rain_calibration": {band: (calibration["bands"][band]["method"]
                                        if (policy.get("serve_calibrated_rain") or {}).get(band) else "none")
                                 for band in BANDS},
            "horizon_bands": {band: list(r) for band, r in BANDS.items()},
            "components": {"v3_model_version": ((v3_result or {}).get("model_version") or _v3_version())
                           if info.get("v3_applied") else None,
                           "v3_applied_targets": list(info.get("v3_applied") or [])}}


def _interval_method(policy: dict) -> str:
    methods = sorted({r["method"] for r in (policy.get("intervals") or {}).values()}) or ["normalized"]
    return f"{'/'.join(methods)} split-conformal (VAL_CAL)"


def _v3_version():
    try:
        import ai_model
        return (ai_model._v3.get("meta") or {}).get("model_version")
    except Exception:  # noqa: BLE001
        return None


__all__ = ["MAX_HORIZON", "MIN_HISTORY_HOURS", "RAIN_THRESHOLD_MM", "TARGETS", "SCHEMA_VERSION",
           "SHORT_MAX_HORIZON", "DEFAULT_MODEL_DIR", "BANDS", "predict", "status", "artifact_revision",
           "forecast_arrays", "V2"]
