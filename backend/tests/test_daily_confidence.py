"""Daily confidence / skill_note / rain_day_probability for the long-range AI days."""
import json
from pathlib import Path

import pytest

from routers import weather_endpoints
from routers.weather_daily import SKILL_NOTES, _day_confidence
from test_self_forecast_api import live as live, _get, _predict


def _report(temp, rain):
    """evaluation-shaped dict: by_day skill = 1 - model/climatology."""
    def day(model, clim, metric):
        return {"model": {metric: model}, "climatology": {metric: clim}}
    return {"targets": {
        "temperature": {"by_day": {str(k): day(m, 1.0, "mae") for k, m in temp.items()}},
        "rain_probability": {"by_day": {str(k): day(m, 1.0, "brier") for k, m in rain.items()}},
    }}


@pytest.mark.parametrize("temp,rain,level", [
    (0.85, 0.96, "high"), (0.92, 1.0, "medium"), (0.93, 0.98, "medium"),
    (0.95, 0.9, "low"), (0.80, 1.02, "low"), (1.01, 0.9, "low"),
])
def test_confidence_rule(temp, rain, level):
    assert _day_confidence(1, _report({1: temp}, {1: rain})) == level


@pytest.mark.parametrize("evaluation", [None, {}, {"targets": {}}, _report({1: 0.5}, {1: 0.5})])
def test_missing_evaluation_or_lead_day_is_low(evaluation):
    assert _day_confidence(3, evaluation) == "low"


def test_current_artifact_report_ranks_days():
    path = Path(__file__).resolve().parents[1] / "models" / "long_range_v2" / "evaluation.json"
    if not path.exists():
        pytest.skip("no trained artifact")
    raw = json.loads(path.read_text(encoding="utf-8"))
    evaluation = {"targets": {n: {"by_day": r["test"]["by_day"]} for n, r in raw.items()}}
    levels = [_day_confidence(d, evaluation) for d in range(1, 8)]
    assert levels[0] == "high"
    assert levels[4] == levels[6] == "low"  # rain Brier does not beat climatology on days 5-7


def test_live_daily_labels_by_lead_day(live, monkeypatch):
    client, _ = live
    report = _report({1: 0.8, 2: 0.92, 3: 0.97}, {1: 0.9, 2: 0.99, 3: 0.99})
    monkeypatch.setattr(weather_endpoints, "_own_evaluation", lambda revision: report)
    days = _get(client, "daily", days=7)    # NOW = 12:00 -> day 0 lead day 1, day 1 lead day 2, ...
    assert [d["confidence"] for d in days] == ["high", "medium"] + ["low"] * 5
    assert all(d["skill_note"] for d in days)
    assert days[2]["skill_note"] == SKILL_NOTES["low"]
    bundle = client.get("/weather/bundle", params={"days": 7}).json()
    assert [d["confidence"] for d in bundle["daily"]] == [d["confidence"] for d in days]


def test_live_daily_rain_probability_and_no_thunder_without_evidence(live):
    client, predictor = live

    def wet(history, cell_id):
        result = _predict(history, cell_id)
        for p in result["predictions"].values():
            p.update(rain_probability=0.9, precipitation_mm=12.0, cloud_cover=100.0)
        return result
    predictor.side_effect = wet
    days = _get(client, "daily", days=3)
    assert all(d["rain_day_probability"] == 0.9 for d in days)
    assert all(d["weather_code"] is not None and d["weather_code"] < 95 for d in days[1:])


def test_live_daily_rain_probability_null_when_hour_missing(live):
    client, predictor = live

    def gap(history, cell_id):
        result = _predict(history, cell_id)
        result["predictions"]["30h"]["rain_probability"] = None
        return result
    predictor.side_effect = gap
    days = _get(client, "daily", days=3)
    assert days[0]["rain_day_probability"] is not None
    assert days[1]["rain_day_probability"] is None
