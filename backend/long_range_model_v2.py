"""Direct 1..168h models v2: past-only weather + train-period climatology.

Same public interface as long_range_model (predict, status, artifact_revision,
MAX_HORIZON, MIN_HISTORY_HOURS). Inputs are ONLY the last 48 hourly rows of the
cell; no external forecasts. Climatology tables and damping coefficients are
computed from the training period only and shipped in climatology.json.

Each target has a 1..168h booster and optionally a 1..24h booster (blended per
horizon by the policy). Each booster predicts a residual against a per-target base value
(metadata "target_mode"): "raw" (base 0, as v1), "anomaly" (base = climatology
at the valid time) or "damped" (base = climatology at valid time + rho(h) x
current anomaly). Rain probability adds the base as a logit init score.
serving_policy.json (chosen on validation only) may blend v2 with the
short-range V3 model at its exact horizons (1/3/6h); if V3 cannot answer, the
v2 value is served for that horizon and the fallback is reported.
Optional interval layer (models/long_range_v2_intervals, scripts/fit_long_range_v2_intervals.py):
80 % p10/p90 (precipitation: p90) from normalized split-conformal quantiles of v2's own served
residuals on VAL_CAL, served only for target x band pairs that passed the coverage gate. Points are
never changed by it; a missing/invalid interval artifact only omits the intervals.
Naive timestamps mean Asia/Ho_Chi_Minh. Text boosters only, never unpickled here.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from functools import lru_cache
from pathlib import Path

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

MAX_HORIZON = 168
MIN_HISTORY_HOURS = 48
SCHEMA_VERSION = 2
TIMEZONE = "Asia/Ho_Chi_Minh"
DEFAULT_MODEL_DIR = Path(__file__).resolve().parent / "models" / "long_range_v2"
DEFAULT_INTERVAL_DIR = Path(__file__).resolve().parent / "models" / "long_range_v2_intervals"
INTERVAL_SCHEMA_VERSION = 1
# Same record keys as long_range_model_v21.EXTRA_RECORD_KEYS (interval part).
INTERVAL_KEYS = ("temperature_p10", "temperature_p90", "humidity_p10", "humidity_p90", "wind_speed_p10",
                 "wind_speed_p90", "cloud_cover_p10", "cloud_cover_p90", "precipitation_mm_p90")
RAIN_THRESHOLD_MM = 0.1
TARGETS = {
    "temperature": ("temperature", None, None),
    "humidity": ("humidity", 0, 100),
    "precipitation_mm": ("precipitation", 0, None),
    "wind_speed": ("wind_speed", 0, None),
    "cloud_cover": ("cloud_cover", 0, 100),
    "rain_probability": ("precipitation", 0, 1),
}
# Climatology key of each target ("rain" = frequency of precipitation > 0.1 mm).
TARGET_CLIM = {"temperature": "temperature", "humidity": "humidity", "precipitation_mm": "precipitation",
               "wind_speed": "wind_speed", "cloud_cover": "cloud_cover", "rain_probability": "rain"}
WEATHER_FEATURES = ("temperature", "humidity", "precipitation", "wind_speed",
                    "cloud_cover", "pressure_msl")
CLIM_KEYS = WEATHER_FEATURES + ("rain",)
STATIC_FEATURES = ("lat", "lon", "elevation")
LAGS = (1, 2, 3, 6, 12, 24)
TARGET_MODES = ("raw", "anomaly", "damped")
SHORT_MAX_HORIZON = 24  # optional dedicated booster for 1..24h, blended per horizon by the policy
INIT_CLIP = 0.005
# Days before each month and month length (non-leap); climatology is interpolated between month centres.
_MONTH_DAYS = np.array([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31], dtype=float)


def timestamps(values) -> pd.Series:
    ts = pd.to_datetime(pd.Series(values), errors="raise")
    if ts.dt.tz is not None:
        ts = ts.dt.tz_convert(TIMEZONE).dt.tz_localize(None)
    if ts.isna().any() or (ts != ts.dt.floor("h")).any():
        raise ValueError("timestamps must be non-null whole hours")
    return ts.reset_index(drop=True)


def local_iso(value) -> str:
    ts = pd.Timestamp(value)
    return (ts.tz_localize(TIMEZONE) if ts.tzinfo is None else ts.tz_convert(TIMEZONE)).isoformat()


def rain_flag(precipitation) -> np.ndarray:
    p = np.asarray(precipitation, dtype=float)
    return np.where(np.isfinite(p), (p > RAIN_THRESHOLD_MM).astype(float), np.nan)


def clim_values(table, ts) -> np.ndarray:
    """Month x hour table (12 x 24) linearly interpolated between month centres at timestamps ts."""
    table = np.asarray(table, dtype=float).reshape(12, 24)
    ts = pd.DatetimeIndex(ts)
    month = ts.month.to_numpy() - 1
    days = _MONTH_DAYS[month]
    day = np.minimum(ts.day.to_numpy() - 1, days - 1)  # 29 Feb behaves like 28 Feb
    pos = month + (day + 0.5) / days - 0.5
    lower = np.floor(pos).astype(int)
    frac = pos - lower
    hour = ts.hour.to_numpy()
    return (1 - frac) * table[lower % 12, hour] + frac * table[(lower + 1) % 12, hour]


def feature_columns() -> list[str]:
    names = []
    for name in WEATHER_FEATURES:
        names.append(name)
        names.extend(f"{name}_lag_{lag}" for lag in LAGS)
        names.extend([f"{name}_diff_3", f"{name}_diff_24", f"{name}_mean_6", f"{name}_mean_24",
                      f"{name}_std_24", f"{name}_anom"])
    names += ["rain_hours_24", "precipitation_max_24", *STATIC_FEATURES,
              "issue_hour_sin", "issue_hour_cos", "issue_year_sin", "issue_year_cos",
              "horizon_hours", "valid_hour_sin", "valid_hour_cos", "valid_year_sin", "valid_year_cos"]
    names += [f"clim_valid_{key}" for key in CLIM_KEYS]
    names += [f"base_{name}" for name in TARGETS]
    return names


def _issue_columns() -> list[str]:
    return feature_columns()[:feature_columns().index("horizon_hours")]


def issue_features(history: pd.DataFrame, static: dict, clim: dict) -> pd.DataFrame:
    """Past-only features for every row of an hourly, contiguous history."""
    ts = timestamps(history.timestamp)
    hist = history.reset_index(drop=True)
    out = {}
    for name in WEATHER_FEATURES:
        s = (pd.to_numeric(hist[name], errors="coerce") if name in hist
             else pd.Series(np.nan, index=hist.index)).astype(float).replace([np.inf, -np.inf], np.nan)
        out[name] = s
        for lag in LAGS:
            out[f"{name}_lag_{lag}"] = s.shift(lag)
        out[f"{name}_diff_3"] = (s - s.shift(3)).round(5)
        out[f"{name}_diff_24"] = (s - s.shift(24)).round(5)
        out[f"{name}_mean_6"] = s.rolling(6, min_periods=6).mean().round(5)
        out[f"{name}_mean_24"] = s.rolling(24, min_periods=24).mean().round(5)
        out[f"{name}_std_24"] = s.rolling(24, min_periods=24).std().round(5)
        out[f"{name}_anom"] = (s - clim_values(clim[name], ts)).round(5)
    rain = pd.Series(rain_flag(out["precipitation"]))
    out["rain_hours_24"] = rain.rolling(24, min_periods=24).sum()
    out["precipitation_max_24"] = out["precipitation"].rolling(24, min_periods=24).max()
    for name in STATIC_FEATURES:
        out[name] = pd.Series(float(static[name]), index=hist.index)
    for prefix, period, value in (("hour", 24, ts.dt.hour), ("year", 365.25, ts.dt.dayofyear)):
        out[f"issue_{prefix}_sin"] = np.sin(2 * np.pi * value / period)
        out[f"issue_{prefix}_cos"] = np.cos(2 * np.pi * value / period)
    frame = pd.DataFrame(out, index=hist.index)
    return frame[_issue_columns()].astype(np.float32)


def issue_state(history: pd.DataFrame, clim: dict) -> pd.DataFrame:
    """Current value and current anomaly per target (base inputs), float64."""
    ts = timestamps(history.timestamp)
    out = {}
    for name in TARGETS:
        key = TARGET_CLIM[name]
        raw = pd.to_numeric(history[TARGETS[name][0]], errors="coerce").to_numpy(dtype=float)
        now = rain_flag(raw) if key == "rain" else raw
        out[f"now_{name}"] = now
        out[f"anom_{name}"] = now - clim_values(clim[key], ts)
    return pd.DataFrame(out)


def horizon_rows(issues: pd.DataFrame, state: pd.DataFrame, issue_times, horizons, clim: dict,
                 rho: dict) -> tuple[pd.DataFrame, dict]:
    """Feature matrix (feature_columns()) and damped base value per target, aligned rows."""
    horizons = np.asarray(horizons, dtype=np.int32)
    if len(horizons) != len(issues) or len(state) != len(issues) or (
            (horizons < 1) | (horizons > MAX_HORIZON)).any():
        raise ValueError("horizons must align with issues and lie in 1..168")
    valid = pd.DatetimeIndex(pd.to_datetime(np.asarray(issue_times))) + pd.to_timedelta(horizons, unit="h")
    out = {c: issues[c].to_numpy() for c in issues.columns}
    out["horizon_hours"] = horizons.astype(np.float32)
    for prefix, period, value in (("hour", 24, valid.hour), ("year", 365.25, valid.dayofyear)):
        out[f"valid_{prefix}_sin"] = np.sin(2 * np.pi * np.asarray(value) / period)
        out[f"valid_{prefix}_cos"] = np.cos(2 * np.pi * np.asarray(value) / period)
    clim_valid = {key: clim_values(clim[key], valid) for key in CLIM_KEYS}
    for key in CLIM_KEYS:
        out[f"clim_valid_{key}"] = clim_valid[key]
    bases = {}
    for name in TARGETS:
        coef = np.asarray(rho[name], dtype=float)[horizons - 1]
        damped = clim_valid[TARGET_CLIM[name]] + coef * state[f"anom_{name}"].to_numpy()
        bases[name] = {"raw": np.zeros(len(horizons)), "anomaly": clim_valid[TARGET_CLIM[name]],
                       "damped": damped}
        out[f"base_{name}"] = damped
    return pd.DataFrame(out)[feature_columns()].astype(np.float32), bases


def bounded(name: str, values) -> np.ndarray:
    _, lower, upper = TARGETS[name]
    return np.clip(np.asarray(values, dtype=float),
                   lower if lower is not None else -np.inf,
                   upper if upper is not None else np.inf)


def logit(p) -> np.ndarray:
    p = np.clip(np.asarray(p, dtype=float), INIT_CLIP, 1 - INIT_CLIP)
    return np.log(p / (1 - p))


def model_output(name: str, mode: str, model, x, base: np.ndarray, num_threads: int = 2) -> np.ndarray:
    """Bounded prediction in target units from a booster trained in `mode`."""
    if name == "rain_probability":
        raw = np.asarray(model.predict(x, raw_score=True, num_threads=num_threads), dtype=float)
        score = raw if mode == "raw" else raw + logit(base)
        return bounded(name, 1.0 / (1.0 + np.exp(-score)))
    return bounded(name, np.asarray(model.predict(x, num_threads=num_threads), dtype=float) + base)


def blend_short(name: str, policy: dict, long_values, short_values) -> np.ndarray:
    """v2 value: long booster, blended with the short booster at h<=24 (policy short_weight)."""
    out = np.asarray(long_values, dtype=float).copy()
    if short_values is None:
        return bounded(name, out)
    for key, weight in (policy.get("targets", {}).get(name) or {}).get("short_weight", {}).items():
        i = int(key.rstrip("h")) - 1
        out[i] = float(weight) * float(short_values[i]) + (1 - float(weight)) * out[i]
    return bounded(name, out)


def apply_policy(name: str, policy: dict, horizons, v2_values, v3_values: dict | None) -> np.ndarray:
    """Served values: v2, blended with V3 at horizons listed in policy[name]["v3_weight"]."""
    out = np.asarray(v2_values, dtype=float).copy()
    weights = (policy.get("targets", {}).get(name) or {}).get("v3_weight", {})
    for key, weight in weights.items():
        h = int(key.rstrip("h"))
        if v3_values is None or h not in v3_values:
            continue
        i = np.flatnonzero(np.asarray(horizons) == h)
        out[i] = float(weight) * float(v3_values[h]) + (1 - float(weight)) * out[i]
    return bounded(name, out)


def _directory() -> Path:
    return Path(os.environ.get("LONG_RANGE_V2_MODEL_DIR", DEFAULT_MODEL_DIR))


def _interval_directory() -> Path:
    return Path(os.environ.get("LONG_RANGE_V2_INTERVALS_DIR", DEFAULT_INTERVAL_DIR))


def _interval_stamp() -> int:
    try:
        return (_interval_directory() / "metadata.json").stat().st_mtime_ns
    except (FileNotFoundError, NotADirectoryError):
        return 0


def artifact_revision() -> tuple[str, int]:
    """(model path, stamp); the stamp also changes when the optional interval artifact changes."""
    path = _directory().resolve()
    try:
        modified = (path / "metadata.json").stat().st_mtime_ns
    except (FileNotFoundError, NotADirectoryError):
        return str(path), 0
    extra = _interval_stamp()
    return str(path), modified if not extra else (modified * 1_000_003 + extra) % (1 << 62)


def _check_policy(policy: dict, meta: dict) -> None:
    if policy.get("model_version") != meta["model_version"] or not isinstance(policy.get("targets"), dict):
        raise ValueError("serving_policy.json does not match model_version")
    for name, rule in policy["targets"].items():
        if name not in TARGETS or not isinstance(rule, dict):
            raise ValueError(f"invalid policy target {name}")
        for key, weight in rule.get("v3_weight", {}).items():
            if key not in ("1h", "3h", "6h") or not 0 <= float(weight) <= 1:
                raise ValueError(f"invalid V3 weight for {name} {key}")
        for key, weight in rule.get("short_weight", {}).items():
            if key not in {f"{h}h" for h in range(1, SHORT_MAX_HORIZON + 1)} or not 0 <= float(weight) <= 1:
                raise ValueError(f"invalid short weight for {name} {key}")


@lru_cache(maxsize=2)
def _load(directory: str, modified: int):
    import lightgbm as lgb
    path = Path(directory)
    meta = json.loads((path / "metadata.json").read_text(encoding="utf-8"))
    if (meta["schema_version"] != SCHEMA_VERSION or meta["feature_columns"] != feature_columns()
            or meta["max_horizon_hours"] != MAX_HORIZON or not meta["cell_static"]):
        raise ValueError("incompatible artifact schema")
    cutoff = pd.Timestamp(meta["trained_through"])
    if pd.isna(cutoff) or cutoff.tzinfo is None:
        raise ValueError("trained_through must have an explicit timezone")
    for key in ("fit_labels_through", "selection_labels_through"):
        if key in meta and pd.Timestamp(meta[key]) > cutoff:
            raise ValueError(f"trained_through precedes {key}")
    if not meta["model_version"]:
        raise ValueError("missing model_version")
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
    for name in TARGETS:
        rho = np.asarray(climate["rho"][name], dtype=float)
        if rho.shape != (MAX_HORIZON,) or not np.isfinite(rho).all():
            raise ValueError(f"invalid damping coefficients for {name}")
    policy = json.loads((path / "serving_policy.json").read_text(encoding="utf-8"))
    _check_policy(policy, meta)
    short_modes = (meta.get("short_range") or {}).get("target_mode", {})
    if short_modes and meta["short_range"].get("max_horizon_hours") != SHORT_MAX_HORIZON:
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
    return meta, models, climate, policy


@lru_cache(maxsize=2)
def _load_intervals(directory: str, modified: int, model_version: str) -> dict:
    """Validated interval artifact for this v2 model_version; raises if absent/invalid/foreign."""
    import long_range_model_v21 as S  # lazy: v21 imports this module
    path = Path(directory)
    meta = json.loads((path / "metadata.json").read_text(encoding="utf-8"))
    blob = (path / "intervals.json").read_bytes()
    if hashlib.sha256(blob).hexdigest() != meta.get("intervals_sha256"):
        raise ValueError("intervals.json sha256 mismatch")
    body = json.loads(blob)
    if (body.get("schema_version") != INTERVAL_SCHEMA_VERSION
            or meta.get("schema_version") != INTERVAL_SCHEMA_VERSION
            or float(body.get("level", 0)) != S.INTERVAL_LEVEL):
        raise ValueError("incompatible interval artifact")
    if body.get("v2_model_version") != model_version or meta.get("v2_model_version") != model_version:
        raise ValueError("interval artifact belongs to another v2 model_version")
    if body.get("bands") != {b: list(r) for b, r in S.BANDS.items()}:
        raise ValueError("interval bands differ from v2.1 bands")
    for name, rule in body["intervals"].items():
        if name not in S.INTERVAL_TARGETS or rule.get("method") not in S.INTERVAL_METHODS:
            raise ValueError(f"invalid interval rule for {name}")
        for band, entry in rule["bands"].items():
            qs = [entry["q_lo"], entry["q_hi"]] + [v for q in (entry.get("by_season") or {}).values()
                                                   for v in (q["q_lo"], q["q_hi"])]
            if band not in S.BANDS or not np.isfinite(np.asarray(qs, float)).all():
                raise ValueError(f"invalid interval quantiles for {name} {band}")
    for cid, tables in body["std"].items():
        for name in body["intervals"]:
            t = np.asarray(tables[name], float)
            if t.shape != (288,) or not (t > 0).all():
                raise ValueError(f"invalid std table for {cid} {name}")
    methods = "/".join(sorted({r["method"] for r in body["intervals"].values()}))
    return {"rules": body["intervals"], "std": body["std"], "level": S.INTERVAL_LEVEL,
            "method": f"{methods} split-conformal on v2 residuals (VAL_CAL 2024-10-14..2024-12-24)"}


def interval_layer(model_version: str) -> dict | None:
    """Interval artifact for model_version, or None (missing/invalid: intervals omitted, points unaffected)."""
    path = _interval_directory()
    if not (path / "metadata.json").exists():
        return None
    try:
        return _load_intervals(str(path.resolve()), _interval_stamp(), model_version)
    except Exception as exc:  # noqa: BLE001 - optional layer; points must still be served
        logger.warning("long_range_v2 intervals unavailable: %s", exc)
        return None


def interval_arrays(values: dict, issue, cell_id: str, layer: dict | None) -> dict:
    """{INTERVAL_KEYS: 168 arrays} (NaN where the band gate failed); {} without a layer or cell."""
    if not layer or cell_id not in layer["std"]:
        return {}
    import long_range_model_v21 as S
    valid = pd.DatetimeIndex([issue + pd.Timedelta(hours=h) for h in range(1, MAX_HORIZON + 1)])
    out = {}
    for name, rule in layer["rules"].items():
        if name not in values:
            continue
        v = np.asarray(values[name], dtype=float)
        lo, hi = S.intervals(name, v, valid, layer["std"][cell_id][name], rule)
        ok = (~np.isfinite(hi) | (hi >= v - 1e-9)) & (~np.isfinite(lo) | (lo <= v + 1e-9))
        if not ok.all():
            logger.warning("long_range_v2 interval ordering violated for %s; omitted", name)
            continue
        out[f"{name}_p90"] = hi
        if name not in S.UPPER_ONLY:
            out[f"{name}_p10"] = lo
    return out


def _num(values: dict, key: str, i: int):
    arr = values.get(key)
    if arr is None or not np.isfinite(arr[i]):
        return None
    return round(float(arr[i]), 4)


def status() -> dict:
    """Distinguish absent/broken artifacts from unsupported training targets."""
    path = _directory()
    manifest = path / "metadata.json"
    try:
        state = "untrained" if not path.exists() or (path.is_dir() and not any(path.iterdir())) else "unavailable"
        if not manifest.exists():
            return {"status": state, "reason": "missing metadata.json", "source": "ai",
                    "cell_ids": [], "capabilities": {n: {"status": state} for n in TARGETS}}
        meta, _, _, _ = _load(str(path.resolve()), manifest.stat().st_mtime_ns)
        return {"status": "available", "source": "ai", "model_version": meta["model_version"],
                "trained_through": meta["trained_through"], "cell_ids": sorted(meta["cell_static"]),
                "capabilities": meta["capabilities"], "max_horizon_hours": MAX_HORIZON,
                "limitations": meta.get("limitations", [])}
    except Exception as exc:
        return {"status": "unavailable", "source": "ai", "reason": str(exc), "cell_ids": [],
                "capabilities": {n: {"status": "unavailable"} for n in TARGETS}}


def _prepare(history: pd.DataFrame, cell_id: str) -> pd.DataFrame:
    hist = history.copy()
    hist["timestamp"] = timestamps(hist.timestamp).to_numpy()
    hist = hist.sort_values("timestamp").reset_index(drop=True)
    if "cell_id" in hist and not hist.cell_id.eq(cell_id).all():
        raise ValueError("history contains a different cell")
    if len(hist) < MIN_HISTORY_HOURS or hist.timestamp.duplicated().any():
        raise ValueError("need >=48 distinct hourly rows")
    hist = hist.tail(MIN_HISTORY_HOURS).reset_index(drop=True)
    if not hist.timestamp.diff().dropna().eq(pd.Timedelta(hours=1)).all():
        raise ValueError("last 48 hours must be contiguous")
    bad = [name for name in WEATHER_FEATURES if name not in hist
           or not np.isfinite(pd.to_numeric(hist[name], errors="coerce")).all()]
    if bad:
        raise ValueError(f"history must be finite for: {', '.join(bad)}")
    return hist


def v3_component(history: pd.DataFrame, cell_id: str) -> dict:
    """{h: {target: value}} from the served V3 short-range model (1/3/6h); raises on failure.

    Point values only (ai_model.predict_points_v3: same numbers as predict_for_location, without the
    interval models and notes that v2 never uses)."""
    import ai_model
    return v3_values(ai_model.predict_points_v3(history, cell_id, set(TARGETS)))


def v3_values(result: dict) -> dict:
    """{h: {target: value}} of a predict_for_location-like V3 result; raises unless V3 answered."""
    if not str(result.get("model_version", "")).startswith("lgbm-hcmc-global-v3"):
        raise ValueError("V3 model is not the one answering")
    return {int(k.rstrip("h")): v for k, v in result["predictions"].items()}


def forecast_arrays(hist: pd.DataFrame, cell_id: str, meta, models, climate, policy,
                    v3_lookup=v3_component) -> tuple[dict, list]:
    """Served value arrays (index = horizon-1) for one prepared 48h history; no leakage guard."""
    clim = climate["cells"][cell_id]
    base = issue_features(hist, meta["cell_static"][cell_id], clim).iloc[[-1]]
    state = issue_state(hist, clim).iloc[[-1]]
    horizons = np.arange(1, MAX_HORIZON + 1)
    x, bases = horizon_rows(pd.concat([base] * MAX_HORIZON, ignore_index=True),
                            pd.concat([state] * MAX_HORIZON, ignore_index=True),
                            [hist.timestamp.iloc[-1]] * MAX_HORIZON, horizons, clim, climate["rho"])
    values = {}
    short = slice(0, SHORT_MAX_HORIZON)
    for name, pair in models.items():
        mode, model = pair["long"]
        long_values = model_output(name, mode, model, x, bases[name][mode])
        short_values = None
        if "short" in pair:
            mode, model = pair["short"]
            short_values = model_output(name, mode, model, x.iloc[short], bases[name][mode][short])
        values[name] = blend_short(name, policy, long_values, short_values)
    fallbacks = []
    needs_v3 = [n for n in values if (policy["targets"].get(n) or {}).get("v3_weight")]
    v3 = None
    if needs_v3:
        try:
            v3 = v3_lookup(hist, cell_id)
        except Exception as exc:  # noqa: BLE001 - V3 is optional; v2 alone stays a valid own forecast
            fallbacks.append(f"v3_unavailable: {type(exc).__name__}")
    for name in needs_v3:
        comp = None
        if v3 is not None:
            comp = {h: p[name] for h, p in v3.items() if p.get(name) is not None
                    and np.isfinite(float(p[name]))}
            missing = [f"{h}h" for h in (int(k.rstrip("h")) for k in policy["targets"][name]["v3_weight"])
                       if h not in comp]
            if missing:
                fallbacks.append(f"v3_missing_{name}: {','.join(missing)}")
        values[name] = apply_policy(name, policy, horizons, values[name], comp)
    return values, fallbacks


def predict(history: pd.DataFrame, cell_id: str, v3_result: dict | None = None) -> dict:
    """Return predictions['1h'..'168h']; failures raise prefixed ValueError.

    v3_result: optional V3 output already computed by the caller for this exact history and cell
    (predict_for_location-like); reused instead of running V3 again.

    Unsupported targets are None. Reject issue <= trained_through (validation
    labels used for early stopping and policy selection are model knowledge).
    No aliasing, unknown-cell model, NWP or climatological serving fallback.
    """
    info = status()
    if info["status"] != "available":
        raise ValueError(f"{info['status']}: {info.get('reason', 'artifact not ready')}")
    path = _directory()
    try:
        meta, models, climate, policy = _load(str(path.resolve()), (path / "metadata.json").stat().st_mtime_ns)
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
    try:
        if v3_result is None:
            values, fallbacks = forecast_arrays(hist, cell_id, meta, models, climate, policy)
        else:
            values, fallbacks = forecast_arrays(hist, cell_id, meta, models, climate, policy,
                                                lambda *_: v3_values(v3_result))
    except Exception as exc:
        raise ValueError(f"unavailable: {exc}") from exc
    if any(not np.isfinite(v).all() for v in values.values()):
        raise ValueError("unavailable: model returned non-finite predictions")
    layer = interval_layer(meta["model_version"])
    try:
        bounds = interval_arrays(values, issue, cell_id, layer)
    except Exception as exc:  # noqa: BLE001 - intervals are optional; points stay served
        logger.warning("long_range_v2 intervals failed for %s: %s", cell_id, exc)
        bounds = {}
    issued_at = local_iso(issue)
    records = {}
    for i, horizon in enumerate(range(1, MAX_HORIZON + 1)):
        records[f"{horizon}h"] = {
            "horizon_hours": horizon, "valid_at": local_iso(issue + pd.Timedelta(hours=horizon)),
            "issued_at": issued_at, "model_version": meta["model_version"], "source": "ai",
            **{name: round(float(values[name][i]), 4) if name in values else None for name in TARGETS},
        }
        if bounds:
            records[f"{horizon}h"].update({key: _num(bounds, key, i) for key in INTERVAL_KEYS})
    out = {"issued_at": issued_at, "model_version": meta["model_version"], "source": "ai",
           "trained_through": meta["trained_through"], "cell_id": cell_id,
           "capabilities": meta["capabilities"], "predictions": records,
           "hourly": list(records.values()), "limitations": meta.get("limitations", []),
           "policy_fallbacks": fallbacks}
    if bounds:
        out.update({"interval_level": layer["level"], "interval_method": layer["method"]})
    return out
