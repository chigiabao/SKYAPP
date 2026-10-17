"""Climatology math hand-checked against the synthetic rows, and cache invalidation."""
import sqlite3
import statistics
from datetime import datetime

import pytest

from conftest import SYN_YEARS, _row, insert_rows
from routers import weather as weather_router

MONTH, DAY, HOUR = 6, 10, 15   # a rainy hour in 1 of 3 years (FROZEN_NOW date)


def _hour_rows(rows, month, day, hour):
    return [r for r in rows if r["timestamp"][5:13] == f"{month:02d}-{day:02d} {hour:02d}"]


def _day_rows(rows, year, month, day):
    return [r for r in rows if r["timestamp"][:10] == f"{year}-{month:02d}-{day:02d}"]


def test_hourly_climatology_by_hand(client, syn_rows):
    sample = _hour_rows(syn_rows, MONTH, DAY, HOUR)
    assert len(sample) == len(SYN_YEARS)
    mean_temp = sum(r["temperature"] for r in sample) / len(sample)
    rain_prob = sum(r["precipitation"] >= 0.1 for r in sample) / len(sample)
    precip_median = statistics.median(r["precipitation"] for r in sample)
    assert 0 < rain_prob < 1, "pick an hour with mixed rain so the check is meaningful"

    hourly, _ = weather_router._climatology()
    row = hourly.loc[(MONTH, DAY, HOUR)]
    assert row["temperature"] == pytest.approx(mean_temp)
    assert row["rain_probability"] == pytest.approx(rain_prob)
    assert row["precipitation_median"] == pytest.approx(precip_median)

    items = client.get("/weather/hourly", params={"hours": 3}).json()
    item = next(x for x in items if x["timestamp"].startswith(f"2024-06-10T{HOUR:02d}:00"))
    assert item["temperature"] == round(mean_temp, 1)
    assert item["rain_probability"] == round(rain_prob, 2)
    assert item["precipitation_median"] == round(precip_median, 2)


def test_daily_climatology_by_hand(client, syn_rows):
    per_year = [_day_rows(syn_rows, y, MONTH, DAY) for y in SYN_YEARS]
    assert all(len(d) == 24 for d in per_year)
    t_min = sum(min(r["temperature"] for r in d) for d in per_year) / len(per_year)
    t_max = sum(max(r["temperature"] for r in d) for d in per_year) / len(per_year)
    totals = [sum(r["precipitation"] for r in d) for d in per_year]
    rain_day_prob = sum(t >= 1.0 for t in totals) / len(totals)
    # per-year-then-average must differ from the pooled min/max for this to be a real check
    pooled_min = min(r["temperature"] for d in per_year for r in d)
    assert t_min != pytest.approx(pooled_min)

    _, daily = weather_router._climatology()
    row = daily.loc[(MONTH, DAY)]
    assert row["temp_min"] == pytest.approx(t_min)
    assert row["temp_max"] == pytest.approx(t_max)
    assert row["rain_day_prob"] == pytest.approx(rain_day_prob)
    assert row["precip_median"] == pytest.approx(statistics.median(totals))

    item = client.get("/weather/daily", params={"days": 1}).json()[0]
    assert item["date"] == "2024-06-10"
    assert item["temperature_min"] == round(t_min, 1)
    assert item["temperature_max"] == round(t_max, 1)
    assert item["rain_day_probability"] == round(rain_day_prob, 2)
    assert item["precipitation_median"] == round(statistics.median(totals), 2)


def test_invalidate_climatology(client, syn_db):
    before = client.get("/weather/hourly", params={"hours": 1}).json()[0]
    hot = _row(datetime(2020, 6, 10, 14))
    hot["temperature"] = 60.0
    with sqlite3.connect(syn_db) as con:
        insert_rows(con, [hot])
    con.close()

    cached = client.get("/weather/hourly", params={"hours": 1}).json()[0]
    assert cached["temperature"] == before["temperature"], "climatology is expected to be cached"

    weather_router.invalidate_climatology()
    after = client.get("/weather/hourly", params={"hours": 1}).json()[0]
    sample = _hour_rows(_all_rows_at(syn_db), 6, 10, 14)
    assert len(sample) == len(SYN_YEARS) + 1
    expected = sum(r["temperature"] for r in sample) / len(sample)
    assert after["temperature"] != before["temperature"]
    assert after["temperature"] == round(expected, 1)


def _all_rows_at(db_path):
    with sqlite3.connect(db_path) as con:
        con.row_factory = sqlite3.Row
        rows = [dict(r) for r in con.execute("SELECT timestamp, temperature FROM hourly_weather")]
    con.close()
    return rows
