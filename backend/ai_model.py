"""
HCMC weather forecasting - shared feature engineering + inference.

The SAME `build_features` function is used by the training notebook
(notebooks/weather_forecasting.ipynb) and by `predict_from_history`, so there
is no train/serve skew.

Inputs follow the `hourly_weather` table in backend/data/weather.db
(columns: timestamp, temperature, humidity, dew_point, apparent_temperature,
precipitation, weather_code, cloud_cover, surface_pressure, pressure_msl,
wind_speed, wind_direction, wind_gusts, ...), one row per hour, ascending.

All features for issue time t use only rows with timestamp <= t
(lags via shift(+k), trailing rolling windows). Targets are built separately
in `build_targets` and are never passed to the model.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from typing import Any, Dict, List, Optional

import joblib
import numpy as np
import pandas as pd

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
HORIZONS = (1, 3, 6)
RAIN_THRESHOLD_MM = 0.1
MIN_HISTORY_HOURS = 48

# Observed values at issue time t (precipitation_probability and visibility are
# excluded: >40% missing and precipitation_probability is itself a forecast product;
# rain duplicates precipitation).
BASE_VARS: List[str] = [
    "temperature", "humidity", "dew_point", "apparent_temperature",
    "precipitation", "weather_code", "cloud_cover", "surface_pressure",
    "pressure_msl", "wind_speed", "wind_gusts",
]
LAG_VARS: List[str] = ["temperature", "humidity", "precipitation",
                       "pressure_msl", "wind_speed", "cloud_cover"]
LAG_HOURS: List[int] = [1, 3, 6, 12, 24]
ROLL_VARS: List[str] = ["temperature", "humidity", "precipitation"]
ROLL_WINDOWS: List[int] = [3, 6, 24]
RAINY_MONTHS = (5, 6, 7, 8, 9, 10, 11)


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    """Build the model feature frame from hourly rows (ascending, contiguous).

    Returns a DataFrame indexed like `df` with columns == feature_columns().
    Rows without enough history (first 24h) contain NaN in lag/rolling columns.
    """
    df = df.copy()
    ts = pd.to_datetime(df["timestamp"])
    out = pd.DataFrame(index=df.index)

    for v in BASE_VARS:
        out[v] = df[v].astype(float)
    wd = np.deg2rad(df["wind_direction"].astype(float))
    out["wind_dir_sin"] = np.sin(wd)
    out["wind_dir_cos"] = np.cos(wd)

    # Time features (of issue time t)
    out["hour"] = ts.dt.hour
    out["day_of_week"] = ts.dt.dayofweek
    out["month"] = ts.dt.month
    out["is_rainy_season"] = ts.dt.month.isin(RAINY_MONTHS).astype(int)
    out["hour_sin"] = np.sin(2 * np.pi * out["hour"] / 24)
    out["hour_cos"] = np.cos(2 * np.pi * out["hour"] / 24)
    out["month_sin"] = np.sin(2 * np.pi * out["month"] / 12)
    out["month_cos"] = np.cos(2 * np.pi * out["month"] / 12)

    # Lags: value at t-k (shift with positive k => past only)
    for v in LAG_VARS:
        s = df[v].astype(float)
        for k in LAG_HOURS:
            out[f"{v}_lag_{k}h"] = s.shift(k)

    # Trailing rolling stats over [t-w+1, t] (not centered)
    for v in ROLL_VARS:
        s = df[v].astype(float)
        for w in ROLL_WINDOWS:
            r = s.rolling(window=w, min_periods=w)
            # Rounded: pandas' online rolling algorithm leaves ~1e-7 float residue
            # that depends on series length (e.g. std of all-zero precip != 0 in a
            # 10-year series but == 0 in a 48h window). Rounding makes training
            # and serving features bit-identical.
            out[f"{v}_roll_mean_{w}h"] = r.mean().round(5)
            out[f"{v}_roll_std_{w}h"] = r.std().round(5)

    # Tendencies
    out["temperature_diff_1h"] = out["temperature"] - out["temperature_lag_1h"]
    out["pressure_tendency_3h"] = out["pressure_msl"] - out["pressure_msl_lag_3h"]
    out["precip_hours_last_24h"] = (
        (df["precipitation"].astype(float) > RAIN_THRESHOLD_MM)
        .rolling(24, min_periods=24).sum()
    )
    return out


def feature_columns() -> List[str]:
    """Feature names in model order (derived from build_features on a dummy frame)."""
    dummy = pd.DataFrame({c: [0.0] * 2 for c in BASE_VARS + ["wind_direction"]})
    dummy["timestamp"] = pd.date_range("2020-01-01", periods=2, freq="h")
    return list(build_features(dummy).columns)


def build_targets(df: pd.DataFrame) -> pd.DataFrame:
    """Training targets: temperature and rain flag at t+h (NaN where t+h unknown)."""
    out = pd.DataFrame(index=df.index)
    for h in HORIZONS:
        fut_t = df["temperature"].astype(float).shift(-h)
        fut_p = df["precipitation"].astype(float).shift(-h)
        out[f"temp_target_{h}h"] = fut_t
        out[f"rain_target_{h}h"] = np.where(fut_p.isna(), np.nan,
                                            (fut_p > RAIN_THRESHOLD_MM).astype(float))
    return out


# ---------------------------------------------------------------- inference
_models: Dict[str, Any] = {}
_meta: Dict[str, Any] = {}


def _load_models() -> None:
    if _models:
        return
    with open(os.path.join(MODEL_DIR, "feature_columns.json"), encoding="utf-8") as f:
        cols = json.load(f)
    if cols != feature_columns():
        raise RuntimeError("feature_columns.json does not match build_features(); retrain.")
    meta_path = os.path.join(MODEL_DIR, "model_metadata.json")
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as f:
            _meta.update(json.load(f))
    for h in HORIZONS:
        _models[f"temp_{h}h"] = joblib.load(os.path.join(MODEL_DIR, f"temperature_model_{h}h.pkl"))
        _models[f"rain_{h}h"] = joblib.load(os.path.join(MODEL_DIR, f"rain_model_{h}h.pkl"))


def predict_from_history(history: pd.DataFrame) -> Dict[str, Any]:
    """Predict 1h/3h/6h ahead from the last >= 48 hourly rows (ascending).

    Issue time = last row's timestamp.
    """
    _load_models()
    if len(history) < MIN_HISTORY_HOURS:
        raise ValueError(f"need >= {MIN_HISTORY_HOURS} hourly rows, got {len(history)}")
    hist = history.sort_values("timestamp").reset_index(drop=True)
    ts = pd.to_datetime(hist["timestamp"])
    if (ts.diff().dropna() != pd.Timedelta(hours=1)).any():
        raise ValueError("history must be contiguous hourly rows")

    feats = build_features(hist)
    x = feats[feature_columns()].iloc[[-1]]
    if x.isna().any(axis=None):
        missing = list(x.columns[x.isna().iloc[0]])
        raise ValueError(f"missing feature values at issue time: {missing}")

    preds: Dict[str, Dict[str, float]] = {}
    for h in HORIZONS:
        temp = float(_models[f"temp_{h}h"].predict(x.values)[0])
        prob = float(_models[f"rain_{h}h"].predict(x.values)[0])
        preds[f"{h}h"] = {"temperature": round(temp, 2),
                          "rain_probability": round(min(max(prob, 0.0), 1.0), 4)}
    return {
        "issued_at": ts.iloc[-1].isoformat(),
        "predictions": preds,
        "model_version": _meta.get("model_version", "unknown"),
    }


def predict_weather(current_data: Dict[str, Any]) -> Dict[str, Any]:
    """Backward-compatible entry point.

    Pass `{"history": [ {timestamp, temperature, ...}, ... ]}` (>= 48 hourly rows).
    A single snapshot is NOT supported: the models need lag/rolling features
    over the past 24h, and faking them causes train/serve skew.
    """
    history = current_data.get("history")
    if history is None:
        raise ValueError("predict_weather needs current_data['history'] with >= 48 hourly rows; "
                         "use predict_from_history(DataFrame) directly.")
    return predict_from_history(pd.DataFrame(history))


def load_history_from_db(db_path: Optional[str] = None, hours: int = MIN_HISTORY_HOURS,
                         until: Optional[datetime] = None, location_id: str = "tsn") -> pd.DataFrame:
    """Convenience: read the last `hours` rows (<= until) of one series from hourly_weather."""
    import sqlite3
    db_path = db_path or os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "weather.db")
    with sqlite3.connect(db_path) as con:
        cols = {r[1] for r in con.execute("PRAGMA table_info(hourly_weather)")}
        where, params = [], []
        if "location_id" in cols:
            where.append("location_id = ?")
            params.append(location_id)
        if until is not None:
            where.append("timestamp <= ?")
            params.append(pd.Timestamp(until).strftime("%Y-%m-%d %H:%M:%S"))
        q = "SELECT * FROM hourly_weather" + (" WHERE " + " AND ".join(where) if where else "")
        q += " ORDER BY timestamp DESC LIMIT ?"
        df = pd.read_sql(q, con, params=tuple(params) + (hours,))
    return df.drop(columns=["location_id"], errors="ignore").iloc[::-1].reset_index(drop=True)



# ---------------------------------------------------------------- v3: global (all-cells) model
# Trained by scripts/train_global_v3.py on every Open-Meteo cell of new HCMC
# (backend/data/history/cells_history.db). Features = build_features(...) + static cell features
# (read from models/v3/cell_static.json at serving time, written by the training script, so the
# values are identical in training and serving). The v2 files in models/ are not touched.
V3_DIR = os.path.join(MODEL_DIR, "v3")
CELL_ALIASES = {"tsn": "om-10.7909-106.6313"}   # 'tsn' is the same grid point as this ward cell
STATIC_FEATURES: List[str] = ["lat", "lon", "elevation", "dist_to_coast_km",
                              "region_hcm", "region_bd", "region_brvt"]
_v3: Dict[str, Any] = {}


def canonical_cell_id(cell_id: Optional[str]) -> Optional[str]:
    return CELL_ALIASES.get(cell_id, cell_id) if cell_id else cell_id


def feature_columns_v3() -> List[str]:
    return feature_columns() + STATIC_FEATURES


def build_features_v3(df: pd.DataFrame, static: Dict[str, float]) -> pd.DataFrame:
    """build_features(df) plus constant static features of the cell (same for train and serve)."""
    out = build_features(df)
    for k in STATIC_FEATURES:
        out[k] = float(static[k])
    return out


def temperature_interval(q10, q90, point, offset: float = 0.0):
    """Served p10-p90 interval (same code in scripts/train_global_v3_ext.py and serving):
    [min(q10, point) - offset, max(q90, point) + offset], offset = split-conformal correction from val."""
    q10, q90, point = np.asarray(q10, float), np.asarray(q90, float), np.asarray(point, float)
    lo = np.minimum(np.minimum(q10, q90), point) - offset
    hi = np.maximum(np.maximum(q10, q90), point) + offset
    return np.minimum(lo, point), np.maximum(hi, point)


# ---- 90 % interval (scripts/train_global_v3_interval.py): q05/q95 + Mondrian CQR offsets per group.
# Group keys are built from the TARGET time (t+h); same code in training and serving.
INTERVAL_GROUPINGS: Dict[str, Dict[str, Any]] = {
    "const": {}, "month_hour": {}, "coast_season": {}, "coast_month": {},
    "cell_season": {"needs_cell": True}, "cell_month": {"needs_cell": True},
}
INTERVAL_MIN_SCALE = 0.3   # degC, floor of q95-q05 for normalized scores


def coast_class(static: Dict[str, float]) -> str:
    if static["lat"] < 9.5:
        return "island"                       # Con Dao
    return "coastal" if static["dist_to_coast_km"] <= 10 else "inland"


def interval_group_keys(grouping: str, h, cell_id, month, hour, static: Dict[str, Dict[str, float]]):
    h, cell_id = np.asarray(h).astype(str), np.asarray(cell_id).astype(str)
    month, hour = np.asarray(month).astype(int), np.asarray(hour).astype(int)
    season = np.where(np.isin(month, RAINY_MONTHS), "wet", "dry")
    coast = pd.Series(cell_id).map({c: coast_class(s) for c, s in static.items()}).fillna("inland").values
    m, b = np.char.add("m", month.astype(str)), np.char.add("b", (hour // 6).astype(str))
    parts = {"const": [h], "month_hour": [h, m, b], "coast_season": [h, coast, season],
             "coast_month": [h, coast, m], "cell_season": [h, cell_id, season], "cell_month": [h, cell_id, m]}[grouping]
    key = parts[0].astype(object)
    for p in parts[1:]:
        key = key + "|" + np.asarray(p).astype(object)
    return key.astype(str)


def interval_scale(qlo, qhi, scale: str):
    if scale == "abs":
        return np.ones_like(np.asarray(qlo, float))
    return np.maximum(np.asarray(qhi, float) - np.asarray(qlo, float), INTERVAL_MIN_SCALE)


def conformal_interval(qlo, qhi, offset, scale: str, point=None):
    """[qlo - off*s, qhi + off*s] (CQR), widened to contain `point` when given."""
    qlo, qhi = np.asarray(qlo, float), np.asarray(qhi, float)
    a, b = np.minimum(qlo, qhi), np.maximum(qlo, qhi)
    s = interval_scale(a, b, scale) * np.asarray(offset, float)
    lo, hi = a - s, b + s
    mid = (lo + hi) / 2
    lo, hi = np.minimum(lo, mid), np.maximum(hi, mid)      # negative offsets never invert the interval
    if point is not None:
        point = np.asarray(point, float)
        lo, hi = np.minimum(lo, point), np.maximum(hi, point)
    return lo, hi


def reset_v3_cache() -> None:
    _v3.clear()


def _load_v3() -> bool:
    """Load v3 models once; False (=> v2 fallback) if any file is missing or inconsistent."""
    if "ok" in _v3:
        return _v3["ok"]
    try:
        with open(os.path.join(V3_DIR, "feature_columns.json"), encoding="utf-8") as f:
            if json.load(f) != feature_columns_v3():
                raise RuntimeError("v3 feature_columns.json does not match build_features_v3(); retrain.")
        with open(os.path.join(V3_DIR, "cell_static.json"), encoding="utf-8") as f:
            static = json.load(f)
        with open(os.path.join(V3_DIR, "metadata_v3.json"), encoding="utf-8") as f:
            meta = json.load(f)
        models = {}
        for h in HORIZONS:
            models[f"temp_{h}h"] = joblib.load(os.path.join(V3_DIR, f"temperature_model_{h}h.pkl"))
            models[f"rain_{h}h"] = joblib.load(os.path.join(V3_DIR, f"rain_model_{h}h.pkl"))
        _v3.update(ok=True, static=static, meta=meta, models=models)
    except Exception as e:  # noqa: BLE001 - any problem with v3 files means "serve v2"
        _v3.clear()
        _v3.update(ok=False, error=f"{type(e).__name__}: {e}")
        return False
    _v3["ext"] = _load_v3_ext()
    return True


# Extra targets written by scripts/train_global_v3_ext.py. Only targets listed in
# extension_v3.json "enabled_targets" (they passed the >= 80 %-of-cells baseline gate) are served.
EXT_TARGETS = ("humidity", "wind_speed", "wind_gusts", "precipitation_mm")
_EXT_BOUNDS = {"humidity": (0.0, 100.0), "wind_speed": (0.0, None), "wind_gusts": (0.0, None),
               "precipitation_mm": (0.0, None)}


def _load_v3_ext() -> Optional[Dict[str, Any]]:
    """Interval / calibration / extra-target models; None (=> plain v3 output) if anything is missing."""
    try:
        with open(os.path.join(V3_DIR, "extension_v3.json"), encoding="utf-8") as f:
            ext = json.load(f)
        if ext.get("base_model_version") != _v3["meta"].get("model_version"):
            raise RuntimeError("extension_v3.json was trained for another v3 model; re-run train_global_v3_ext.py")
        enabled = [t for t in ext["enabled_targets"] if t in EXT_TARGETS]
        models, calib = {}, {}
        iv = ext["interval"]
        qs = ("q05", "q95") if iv.get("version") == 2 else ("p10", "p90")
        for h in HORIZONS:
            for q in qs:
                models[f"temp_{q}_{h}h"] = joblib.load(os.path.join(V3_DIR, f"temperature_{q}_model_{h}h.pkl"))
            for t in enabled:
                models[f"{t}_{h}h"] = joblib.load(os.path.join(V3_DIR, f"{t}_model_{h}h.pkl"))
            if ext["rain_calibration"]["per_horizon"][f"{h}h"]["applied"]:
                calib[f"{h}h"] = joblib.load(os.path.join(V3_DIR, f"rain_calibrator_{h}h.pkl"))
        if iv.get("version") == 2:
            offsets = {k: float(v) for k, v in iv["offsets"].items()}
        else:
            offsets = {k: float(v["offset"]) for k, v in iv["conformal"].items()}
        return {"meta": ext, "enabled": enabled, "models": models, "calibrators": calib, "offsets": offsets,
                "interval": iv}
    except Exception:  # noqa: BLE001 - extension is optional; base v3 output stays valid
        return None


def _uncertainty_note(lo: float, hi: float, coverage: Optional[float], period: Optional[str],
                      level: Optional[float] = None) -> str:
    vi = lambda v: f"{v:.1f}".replace(".", ",")  # noqa: E731 - Vietnamese decimal comma
    kind = f"khoảng tin cậy {level * 100:.0f}%" if level else "khoảng p10–p90"
    note = f"Nhiệt độ nhiều khả năng trong khoảng {vi(lo)}–{vi(hi)} °C ({kind})."
    if coverage is not None:
        when = f" {period.replace('..', ' đến ')}" if period else ""
        note += f" Kiểm chứng trên dữ liệu{when} ở ô này: thực tế rơi vào khoảng ~{coverage * 100:.0f}% số lần."
    return note + " Đây là mức bất định, không phải điểm độ chính xác."


def _interval_v3(ext: Dict[str, Any], xv, temp: float, h: int, cid: str, issued: pd.Timestamp):
    m, k, iv = ext["models"], f"{h}h", ext["interval"]
    if iv.get("version") != 2:   # legacy p10/p90 extension
        lo, hi = temperature_interval(m[f"temp_p10_{k}"].predict(xv), m[f"temp_p90_{k}"].predict(xv),
                                      [temp], ext["offsets"].get(k, 0.0))
        return float(lo[0]), float(hi[0]), None
    tt = issued + pd.Timedelta(hours=h)
    key = interval_group_keys(iv["grouping"], [h], [cid], [tt.month], [tt.hour], _v3["static"])[0]
    off = ext["offsets"].get(key, ext["offsets"][str(h)])
    lo, hi = conformal_interval(m[f"temp_q05_{k}"].predict(xv), m[f"temp_q95_{k}"].predict(xv), [off],
                                iv["scale"], [temp])
    return float(lo[0]), float(hi[0]), float(iv["nominal"])


def _prepare_history(history: pd.DataFrame) -> pd.DataFrame:
    if len(history) < MIN_HISTORY_HOURS:
        raise ValueError(f"need >= {MIN_HISTORY_HOURS} hourly rows, got {len(history)}")
    hist = history.sort_values("timestamp").reset_index(drop=True)
    ts = pd.to_datetime(hist["timestamp"])
    if (ts.diff().dropna() != pd.Timedelta(hours=1)).any():
        raise ValueError("history must be contiguous hourly rows")
    return hist


def predict_for_location(history: pd.DataFrame, cell_id: Optional[str]) -> Dict[str, Any]:
    """Like predict_from_history, for any cell of new HCMC.

    Uses the global v3 model when its files exist and the cell is known to it; otherwise falls
    back to v2 (predict_from_history). The output format is identical in both cases; the
    `model_version` tells which model answered.
    """
    cid = canonical_cell_id(cell_id)
    if not _load_v3() or cid not in _v3["static"]:
        return predict_from_history(history)
    hist = _prepare_history(history)
    ts = pd.to_datetime(hist["timestamp"])
    cols = feature_columns_v3()
    x = build_features_v3(hist, _v3["static"][cid])[cols].iloc[[-1]]
    if x.isna().any(axis=None):
        missing = list(x.columns[x.isna().iloc[0]])
        raise ValueError(f"missing feature values at issue time: {missing}")
    xv = x.values.astype(np.float32)
    ext = _v3.get("ext")
    ev = (_v3_evaluation().get(cid) or {}) if ext else {}
    preds: Dict[str, Dict[str, Any]] = {}
    for h in HORIZONS:
        k = f"{h}h"
        temp = float(_v3["models"][f"temp_{h}h"].predict(xv)[0])
        prob = float(_v3["models"][f"rain_{h}h"].predict(xv)[0])
        if ext and k in ext["calibrators"]:
            prob = float(ext["calibrators"][k].predict([prob])[0])
        p: Dict[str, Any] = {"temperature": round(temp, 2),
                             "rain_probability": round(min(max(prob, 0.0), 1.0), 4)}
        if ext:
            m = ext["models"]
            lo, hi, level = _interval_v3(ext, xv, temp, h, cid, ts.iloc[-1])
            p["temperature_low"], p["temperature_high"] = round(lo, 2), round(hi, 2)
            if level is not None:
                p["interval_level"] = level
            # DEPRECATED: temperature_p10 / temperature_p90 are kept only for old clients. They equal
            # temperature_low / temperature_high (a 90 % interval when interval_level == 0.9), NOT quantiles.
            p["temperature_p10"], p["temperature_p90"] = p["temperature_low"], p["temperature_high"]
            for t in ext["enabled"]:
                a, b = _EXT_BOUNDS[t]
                v = float(np.clip(m[f"{t}_{k}"].predict(xv)[0], a, b if b is not None else np.inf))
                p[t] = round(v, 2 if t == "precipitation_mm" else 1)
            p["uncertainty_note"] = _uncertainty_note(
                p["temperature_low"], p["temperature_high"], ev.get(f"temperature_interval_coverage_{k}"),
                ev.get("interval_test_period") or ev.get("test_period"), level)
        preds[k] = p
    out = {
        "issued_at": ts.iloc[-1].isoformat(),
        "predictions": preds,
        "model_version": _v3["meta"].get("model_version", "unknown-v3"),
    }
    out["enabled_targets"] = list(ext["meta"]["enabled_targets"]) if ext else ["temperature", "rain_probability"]
    return out


def _v3_evaluation() -> Dict[str, Any]:
    if "evaluation" not in _v3:
        try:
            with open(os.path.join(V3_DIR, "evaluation_v3.json"), encoding="utf-8") as f:
                _v3["evaluation"] = json.load(f)
        except (OSError, ValueError):
            _v3["evaluation"] = {}
    return _v3["evaluation"]


def evaluation_for(cell_id: Optional[str]) -> Optional[Dict[str, Any]]:
    """Held-out test metrics of v3 at a cell (from models/v3/evaluation_v3.json).

    None if the cell was never evaluated, or if v3 is not being served (then the caller
    should show the v2 evaluation, which describes the model actually answering).
    """
    if not cell_id or not _load_v3():
        return None
    ev = _v3_evaluation()
    entry = ev.get(cell_id) or ev.get(canonical_cell_id(cell_id))
    if entry is None:
        return None
    entry = json.loads(json.dumps(entry))
    ext = _v3.get("ext")
    if ext:   # what is actually served now (overrides the copy stored at training time)
        entry["enabled_targets"] = list(ext["meta"]["enabled_targets"])
        entry["serving_rule"] = ext["meta"]["serving_rule"]
    return entry

if __name__ == "__main__":
    out = predict_from_history(load_history_from_db())
    print(json.dumps(out, indent=2))
