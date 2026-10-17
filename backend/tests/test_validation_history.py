"""Query validation and /history range boundaries (synthetic DB)."""
from datetime import datetime

import pytest

from database import LOCAL_TZ


@pytest.mark.parametrize("hours", [0, -1, 169])
def test_hourly_hours_out_of_range(client, hours):
    assert client.get("/weather/hourly", params={"hours": hours}).status_code == 422


@pytest.mark.parametrize("days", [0, 15])
def test_daily_days_out_of_range(client, days):
    assert client.get("/weather/daily", params={"days": days}).status_code == 422


def test_hourly_non_integer(client):
    assert client.get("/weather/hourly", params={"hours": "abc"}).status_code == 422


def test_history_requires_both_dates(client):
    assert client.get("/weather/history", params={"start_date": "2023-06-01"}).status_code == 422


@pytest.mark.parametrize("start,end", [
    ("abc", "2023-06-01"),
    ("2023-06-01", "not-a-date"),
    ("2023-13-01", "2023-06-01"),
    ("2023-02-30", "2023-03-01"),
    ("", "2023-06-01"),
])
def test_history_bad_dates(client, start, end):
    assert client.get("/weather/history", params={"start_date": start, "end_date": end}).status_code == 400


def test_history_end_before_start(client):
    r = client.get("/weather/history", params={"start_date": "2023-06-10", "end_date": "2023-06-09"})
    assert r.status_code == 400


def test_history_range_limit(client):
    ok = client.get("/weather/history", params={"start_date": "2022-06-01", "end_date": "2023-06-01"})
    assert ok.status_code == 200  # exactly 365 days
    too_long = client.get("/weather/history", params={"start_date": "2022-06-01", "end_date": "2023-06-02"})
    assert too_long.status_code == 400


def test_history_boundaries_inclusive(client):
    r = client.get("/weather/history", params={"start_date": "2023-06-09", "end_date": "2023-06-10"})
    items = r.json()
    assert len(items) == 48
    assert items[0]["timestamp"] == datetime(2023, 6, 9, 0, tzinfo=LOCAL_TZ).isoformat()
    assert items[-1]["timestamp"] == datetime(2023, 6, 10, 23, tzinfo=LOCAL_TZ).isoformat()


def test_history_single_day(client):
    items = client.get("/weather/history", params={"start_date": "2023-06-24", "end_date": "2023-06-24"}).json()
    assert len(items) == 24
    assert items[-1]["timestamp"].startswith("2023-06-24T23:00:00")


def test_history_empty_range_returns_empty_list(client):
    r = client.get("/weather/history", params={"start_date": "2020-01-01", "end_date": "2020-01-05"})
    assert r.status_code == 200 and r.json() == []


def test_history_compact_iso_date(client):
    r = client.get("/weather/history", params={"start_date": "20230610", "end_date": "20230610"})
    assert r.status_code == 400 or len(r.json()) == 24
