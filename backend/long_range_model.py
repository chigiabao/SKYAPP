"""Direct 1..168h models: past-only weather, future calendar, no fallback.

Naive timestamps mean Asia/Ho_Chi_Minh, matching the historical DB.
Local LightGBM text artifacts are never downloaded or unpickled.
"""
from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path

import numpy as np
import pandas as pd

MAX_HORIZON = 168
MIN_HISTORY_HOURS = 48
TIMEZONE = "Asia/Ho_Chi_Minh"
DEFAULT_MODEL_DIR = Path(__file__).resolve().parent / "models" / "long_range"
RAIN_THRESHOLD_MM = 0.1
TARGETS = {
    "temperature": ("temperature", None, None),
    "humidity": ("humidity", 0, 100),
    "precipitation_mm": ("precipitation", 0, None),
    "wind_speed": ("wind_speed", 0, None),
    "cloud_cover": ("cloud_cover", 0, 100),
    "rain_probability": ("precipitation", 0, 1),
}
WEATHER_FEATURES = ("temperature", "humidity", "precipitation", "wind_speed",
                    "cloud_cover", "pressure_msl")
STATIC_FEATURES = ("lat", "lon", "elevation")


def timestamps(values) -> pd.Series:
    ts = pd.to_datetime(values, errors="raise")
    if ts.dt.tz is not None:
        ts = ts.dt.tz_convert(TIMEZONE).dt.tz_localize(None)
    if ts.isna().any() or (ts != ts.dt.floor("h")).any():
        raise ValueError("timestamps must be non-null whole hours")
    return ts


def local_iso(value) -> str:
    ts = pd.Timestamp(value)
    return (ts.tz_localize(TIMEZONE) if ts.tzinfo is None else ts.tz_convert(TIMEZONE)).isoformat()


def feature_columns() -> list[str]:
    names = []
    for name in WEATHER_FEATURES:
        names.extend([name, f"{name}_lag_1", f"{name}_lag_6", f"{name}_lag_24",
                      f"{name}_mean_24", f"{name}_std_24"])
    return names + list(STATIC_FEATURES) + ["issue_hour_sin", "issue_hour_cos",
        "issue_year_sin", "issue_year_cos", "horizon_hours", "valid_hour_sin",
        "valid_hour_cos", "valid_year_sin", "valid_year_cos"]


def issue_features(history: pd.DataFrame, static: dict) -> pd.DataFrame:
    """Build past-only features on an hourly reindexed series."""
    ts = timestamps(history.timestamp)
    out = pd.DataFrame(index=history.index)
    for name in WEATHER_FEATURES:
        s = (pd.to_numeric(history[name], errors="coerce") if name in history
             else pd.Series(np.nan, index=history.index)).replace([np.inf, -np.inf], np.nan)
        out[name] = s
        for lag in (1, 6, 24):
            out[f"{name}_lag_{lag}"] = s.shift(lag)
        out[f"{name}_mean_24"] = s.rolling(24, min_periods=24).mean().round(5)
        out[f"{name}_std_24"] = s.rolling(24, min_periods=24).std().round(5)
    for name in STATIC_FEATURES:
        out[name] = float(static[name])
    for prefix, period, value in (("hour", 24, ts.dt.hour), ("year", 365.25, ts.dt.dayofyear)):
        out[f"issue_{prefix}_sin"] = np.sin(2 * np.pi * value / period)
        out[f"issue_{prefix}_cos"] = np.cos(2 * np.pi * value / period)
    return out.astype(np.float32)


def horizon_features(issues: pd.DataFrame, issue_times: pd.Series, horizons) -> pd.DataFrame:
    out = issues.reset_index(drop=True).copy()
    horizons = np.asarray(horizons, dtype=np.int32)
    if len(horizons) != len(out) or ((horizons < 1) | (horizons > MAX_HORIZON)).any():
        raise ValueError("horizons must align with issues and lie in 1..168")
    valid = pd.Series(pd.to_datetime(issue_times).to_numpy()) + pd.to_timedelta(horizons, unit="h")
    out["horizon_hours"] = horizons
    for prefix, period, value in (("hour", 24, valid.dt.hour), ("year", 365.25, valid.dt.dayofyear)):
        out[f"valid_{prefix}_sin"] = np.sin(2 * np.pi * value / period)
        out[f"valid_{prefix}_cos"] = np.cos(2 * np.pi * value / period)
    return out[feature_columns()].astype(np.float32)


def bounded(name: str, values) -> np.ndarray:
    _, lower, upper = TARGETS[name]
    return np.clip(np.asarray(values, dtype=float),
                   lower if lower is not None else -np.inf,
                   upper if upper is not None else np.inf)


def _directory() -> Path:
    return Path(os.environ.get("LONG_RANGE_MODEL_DIR", DEFAULT_MODEL_DIR))


def artifact_revision() -> tuple[str, int]:
    path = _directory().resolve()
    try:
        modified = (path / "metadata.json").stat().st_mtime_ns
    except (FileNotFoundError, NotADirectoryError):
        modified = 0
    return str(path), modified


@lru_cache(maxsize=2)
def _load(directory: str, modified: int):
    import lightgbm as lgb
    path = Path(directory)
    meta = json.loads((path / "metadata.json").read_text(encoding="utf-8"))
    if (meta["schema_version"] != 1 or meta["feature_columns"] != feature_columns()
            or meta["max_horizon_hours"] != MAX_HORIZON or not meta["cell_static"]):
        raise ValueError("incompatible artifact schema")
    cutoff = pd.Timestamp(meta["trained_through"])
    if pd.isna(cutoff) or cutoff.tzinfo is None:
        raise ValueError("trained_through must have an explicit timezone")
    for key in ("fit_labels_through", "selection_labels_through"):
        if key in meta and pd.Timestamp(meta[key]) > cutoff:
            raise ValueError(f"trained_through precedes {key}")
    for cell in meta["cell_static"].values():
        if not all(np.isfinite(float(cell[k])) for k in STATIC_FEATURES):
            raise ValueError("non-finite cell coordinates/elevation")
    if not meta["model_version"]:
        raise ValueError("missing model_version")
    models = {}
    for name in TARGETS:
        cap = meta["capabilities"][name]
        if cap["status"] == "available":
            model = lgb.Booster(model_file=str(path / f"{name}.txt"))
            if model.feature_name() != feature_columns():
                raise ValueError(f"feature mismatch for {name}")
            models[name] = model
        elif cap["status"] != "unsupported":
            raise ValueError(f"invalid capability for {name}")
    if not models:
        raise ValueError("artifact contains no trained targets")
    return meta, models


def status() -> dict:
    """Distinguish absent/broken artifacts from unsupported training targets."""
    path = _directory()
    manifest = path / "metadata.json"
    try:
        state = "untrained" if not path.exists() or (path.is_dir() and not any(path.iterdir())) else "unavailable"
        if not manifest.exists():
            return {"status": state, "reason": "missing metadata.json", "source": "ai",
                    "cell_ids": [], "capabilities": {n: {"status": state} for n in TARGETS}}
        meta, _ = _load(str(path.resolve()), manifest.stat().st_mtime_ns)
        return {"status": "available", "source": "ai", "model_version": meta["model_version"],
                "trained_through": meta["trained_through"], "cell_ids": sorted(meta["cell_static"]),
                "capabilities": meta["capabilities"], "max_horizon_hours": MAX_HORIZON,
                "limitations": meta.get("limitations", [])}
    except Exception as exc:
        return {"status": "unavailable", "source": "ai", "reason": str(exc), "cell_ids": [],
                "capabilities": {n: {"status": "unavailable"} for n in TARGETS}}


def predict(history: pd.DataFrame, cell_id: str) -> dict:
    """Return predictions['1h'..'168h']; failures raise prefixed ValueError.

    Unsupported targets are None. Reject issue <= trained_through: validation
    labels used for early stopping are part of model knowledge too.
    No aliasing, unknown-cell model, NWP or climatological serving fallback.
    """
    info = status()
    if info["status"] != "available":
        raise ValueError(f"{info['status']}: {info.get('reason', 'artifact not ready')}")
    path = _directory()
    try:
        meta, models = _load(str(path.resolve()), (path / "metadata.json").stat().st_mtime_ns)
    except Exception as exc:
        raise ValueError(f"unavailable: {exc}") from exc
    if cell_id not in meta["cell_static"]:
        raise ValueError(f"unsupported_cell: {cell_id}")
    try:
        hist = history.copy()
        hist["timestamp"] = timestamps(hist.timestamp)
        hist = hist.sort_values("timestamp").reset_index(drop=True)
        if "cell_id" in hist and not hist.cell_id.eq(cell_id).all():
            raise ValueError("history contains a different cell")
        if len(hist) < MIN_HISTORY_HOURS or hist.timestamp.duplicated().any():
            raise ValueError("need >=48 distinct hourly rows")
        hist = hist.tail(MIN_HISTORY_HOURS).reset_index(drop=True)
        if not hist.timestamp.diff().dropna().eq(pd.Timedelta(hours=1)).all():
            raise ValueError("last 48 hours must be contiguous")
        if not np.isfinite(pd.to_numeric(hist.temperature, errors="coerce")).all():
            raise ValueError("temperature history must be finite")
    except Exception as exc:
        raise ValueError(f"invalid_history: {exc}") from exc
    issue = hist.timestamp.iloc[-1]
    if issue.tz_localize(TIMEZONE) <= pd.Timestamp(meta["trained_through"]):
        raise ValueError(f"replay_leakage: issue must be after {meta['trained_through']}")
    base = issue_features(hist, meta["cell_static"][cell_id]).iloc[[-1]]
    horizons = np.arange(1, MAX_HORIZON + 1)
    x = horizon_features(pd.concat([base] * MAX_HORIZON, ignore_index=True),
                         pd.Series([issue] * MAX_HORIZON), horizons)
    try:
        values = {name: np.asarray(model.predict(x, num_threads=2)) for name, model in models.items()}
    except Exception as exc:
        raise ValueError(f"unavailable: {exc}") from exc
    if any(not np.isfinite(v).all() for v in values.values()):
        raise ValueError("unavailable: model returned non-finite predictions")
    values = {name: bounded(name, value) for name, value in values.items()}
    issued_at = local_iso(issue)
    records = {}
    for i, horizon in enumerate(horizons):
        records[f"{horizon}h"] = {
            "horizon_hours": int(horizon), "valid_at": local_iso(issue + pd.Timedelta(hours=int(horizon))),
            "issued_at": issued_at, "model_version": meta["model_version"], "source": "ai",
            **{name: round(float(values[name][i]), 4) if name in values else None for name in TARGETS},
        }
    return {"issued_at": issued_at, "model_version": meta["model_version"], "source": "ai",
            "trained_through": meta["trained_through"], "cell_id": cell_id,
            "capabilities": meta["capabilities"], "predictions": records,
            "hourly": list(records.values()), "limitations": meta.get("limitations", [])}
