"""
Daily aggregation of hour items and the per-day confidence label of AI days.
"""
from datetime import date
from typing import List, Optional

import numpy as np
import pandas as pd

from models import WeatherData, DailySummary
from routers.weather_core import RAIN_DAY_MM, _code, _num


# WMO codes from least to most severe (showers rank with rain of the same intensity).
_SEVERITY = {c: i for i, c in enumerate(
    [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 80, 63, 81, 66, 65, 82, 67,
     71, 73, 75, 77, 85, 86, 95, 96, 99])}


def _severe_code(codes: List[Optional[int]]) -> Optional[int]:
    """Most severe code of an hour-ordered list, ignoring drizzle hours with no wet (>= 51) neighbour."""
    def wet(c):
        return c is not None and c >= 51

    kept = [c for i, c in enumerate(codes) if c is not None and not (
        51 <= c <= 57 and not wet(codes[i - 1] if i > 0 else None)
        and not wet(codes[i + 1] if i + 1 < len(codes) else None))]
    kept = kept or [c for c in codes if c is not None]
    return max(kept, key=lambda c: _SEVERITY.get(c, -1)) if kept else None


def _clim_daily_summary(day: date, row) -> DailySummary:
    return DailySummary(
        date=day.strftime("%Y-%m-%d"),
        temperature_min=_num(row['temp_min'], 1),
        temperature_max=_num(row['temp_max'], 1),
        temperature_avg=_num(row['temp_avg'], 1),
        humidity_avg=_num(row['humidity_avg'], 1),
        precipitation_total=_num(row['precip_total'], 2),
        weather_code=_code(row['weather_code']),
        wind_speed_max=_num(row['wind_max'], 1),
        cloud_cover_avg=_num(row['cloud_avg'], 1),
        rain_day_probability=_num(row['rain_day_prob'], 2),
        precipitation_median=_num(row['precip_median'], 2),
        wind_gusts_max=_num(row['gust_max'], 1),
        source="climatology",
    )


def _daily_summary(day: date, items: List[Optional[WeatherData]], clim_daily: pd.DataFrame) -> Optional[DailySummary]:
    """Aggregate one local day's hour items (see get_daily_forecast for the rules)."""
    present = [i for i in items if i is not None]
    kinds = {i.source for i in present}
    key = (day.month, day.day)
    crow = clim_daily.loc[key] if key in clim_daily.index else None

    def agg(field, fn, digits):
        v = [getattr(i, field) for i in present if getattr(i, field) is not None]
        if 'ai' in kinds and len(v) != 24:
            return None  # Partial known hours are not a forecast of the full-day statistic.
        return _num(fn(v), digits) if v else None

    if kinds <= {"climatology"}:
        if crow is None:
            return None
        summary = _clim_daily_summary(day, crow)
        summary.uv_index_max = agg("uv_index", max, 1)
        return summary

    def mean(v):
        return sum(v) / len(v)

    total = agg("precipitation", sum, 2)
    obs_precip = [i.precipitation for i in present if i.source == "observed" and i.precipitation is not None]
    obs_rain_day = (1.0 if sum(obs_precip) >= RAIN_DAY_MM else 0.0) if obs_precip else None
    clim_prob = _num(crow['rain_day_prob'], 2) if crow is not None else None
    # Codes of the real (observed/forecast) hours only; climatology hours break drizzle adjacency.
    codes = [i.weather_code if i is not None and i.source != "climatology" else None for i in items]

    if "forecast" in kinds or "ai" in kinds:
        source = "ai" if "ai" in kinds else "forecast"
        probs = [i.rain_probability for i in present if i.source in {"forecast", "ai"} and i.rain_probability is not None]
        if obs_rain_day is not None:
            probs.append(obs_rain_day)
        if source == 'ai':
            # Max hourly P(>=0.1 mm) over all 24 h (observed hours are 1/0): a lower bound for "some rainy
            # hour today" under any hour-to-hour dependence. Not the calibrated daily >=1 mm event; the
            # independence product 1-prod(1-p) would overstate it for strongly autocorrelated rain.
            hour_probs = [i.rain_probability for i in present]
            rain_day_prob = max(hour_probs) if len(present) == 24 and None not in hour_probs else None
        else:
            rain_day_prob = max(probs) if probs else clim_prob
        code, median = _severe_code(codes), None if source == "ai" else total
    elif kinds == {"observed"} and len(present) == 24:
        source = "observed"
        rain_day_prob = obs_rain_day
        code, median = _severe_code(codes), total
    else:   # observed hours + climatology for the rest of the day
        source = "climatology"
        known = [p for p in (clim_prob, obs_rain_day) if p is not None]
        rain_day_prob = max(known) if known else None
        both = [c for c in (_code(crow['weather_code']) if crow is not None else None, _severe_code(codes))
                if c is not None]
        code = max(both, key=lambda c: _SEVERITY.get(c, -1)) if both else None
        median = _num(crow['precip_median'], 2) if crow is not None else total

    return DailySummary(
        date=day.strftime("%Y-%m-%d"),
        temperature_min=agg("temperature", min, 1),
        temperature_max=agg("temperature", max, 1),
        temperature_avg=agg("temperature", mean, 1),
        humidity_avg=agg("humidity", mean, 1),
        precipitation_total=total,
        weather_code=code,
        wind_speed_max=agg("wind_speed", max, 1),
        cloud_cover_avg=agg("cloud_cover", mean, 1),
        rain_day_probability=_num(rain_day_prob, 2),
        precipitation_median=median,
        wind_gusts_max=agg("wind_gusts", max, 1),
        uv_index_max=agg("uv_index", max, 1),
        us_aqi_max=agg("us_aqi", max, 0),
        source=source,
    )


# Long-range skill by lead day, from the artifact's test by_day report (lead day k = hours (k-1)*24+1..k*24).
CONFIDENCE_HIGH_TEMP_SKILL = 0.10
CONFIDENCE_MEDIUM_TEMP_SKILL = 0.06
SKILL_NOTES = {
    "high": "AI vượt rõ trung bình nhiều năm ở tầm dự báo này.",
    "medium": "AI chỉ nhỉnh hơn trung bình nhiều năm một chút.",
    "low": "Gần với trung bình nhiều năm; chỉ nên xem là xu hướng.",
    "observed": "Số liệu đã ghi nhận (dữ liệu phân tích Open-Meteo).",
    "climatology": "Trung bình nhiều năm, không phải dự báo.",
}


def _skill(scores: dict, metric: str) -> Optional[float]:
    try:
        model, clim = float(scores["model"][metric]), float(scores["climatology"][metric])
    except (KeyError, TypeError, ValueError):
        return None
    return 1 - model / clim if clim > 0 and np.isfinite(model) else None


def _day_confidence(lead_day: int, evaluation: Optional[dict]) -> str:
    """Confidence of an AI day from test-set skill vs climatology at that lead day.

    temp_skill = 1 - MAE_model / MAE_climatology (temperature), rain_skill = 1 - Brier_model / Brier_climatology
    (rain_probability), both from evaluation.json test by_day[lead_day]:
      high   if temp_skill >= 0.10 and rain_skill > 0
      medium if temp_skill >= 0.06 and rain_skill >= 0
      low    otherwise, incl. lead days beyond the report or a missing/unreadable evaluation.
    Current artifact (long_range_v2): days 1-2 high (temp 28.6/14.3 %), days 3-4 medium (9.3/7.1 %; day-4 rain
    skill only ~0.01 %), days 5-7 low (rain Brier loses to climatology)."""
    try:
        targets = evaluation["targets"]
        temp = _skill(targets["temperature"]["by_day"][str(lead_day)], "mae")
        rain = _skill(targets["rain_probability"]["by_day"][str(lead_day)], "brier")
    except (KeyError, TypeError):
        return "low"
    if temp is None or rain is None:
        return "low"
    if temp >= CONFIDENCE_HIGH_TEMP_SKILL and rain > 0:
        return "high"
    if temp >= CONFIDENCE_MEDIUM_TEMP_SKILL and rain >= 0:
        return "medium"
    return "low"


def _label_confidence(summary: DailySummary, lead_day: int, evaluation: Optional[dict]) -> DailySummary:
    level = _day_confidence(lead_day, evaluation) if summary.source == "ai" else         "high" if summary.source == "observed" else "low" if summary.source == "climatology" else None
    summary.confidence = level
    summary.skill_note = SKILL_NOTES.get(level if summary.source == "ai" else summary.source)
    return summary
