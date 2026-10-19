"""Historical replay, own-model sources, no external fallback, and short-range AI verification."""
import sqlite3
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

import main
from conftest import FROZEN_NOW, LAST_TS, freeze_now, point_app_at, write_db
from database import LOCAL_TZ, WEATHER_COLUMNS, migrate
from routers import weather as weather_router

T = datetime(2023, 6, 20, 12, 0)          # replay time inside the synthetic data
T_ISO = T.isoformat()
ISSUE = "2023-06-24 23:00:00"             # = LAST_TS: NWP issue made at the latest observed hour
LIVE_NOW = datetime(2023, 6, 24, 23, 10, tzinfo=LOCAL_TZ)


def _ts(s: str) -> datetime:
    assert s.endswith("+07:00"), s
    return datetime.fromisoformat(s)


def _add_forecast(db, code_at=None, pp=40.0):
    """168 h NWP issue after ISSUE; constant fields, precipitation_probability `pp`, weather_code 3 unless
    overridden per timestamp via `code_at`."""
    code_at = code_at or {}
    con = sqlite3.connect(db)
    migrate(con)
    issued = datetime.fromisoformat(ISSUE)
    rows = []
    for k in range(1, 169):
        t = issued + timedelta(hours=k)
        vals = {c: 1.0 for c in WEATHER_COLUMNS}
        vals.update(temperature=30.0 + (k % 24) / 10, precipitation_probability=pp + (k % 24),
                    precipitation=0.0, weather_code=float(code_at.get(t, 3)), wind_speed=10.0, wind_gusts=20.0 + k % 5,
                    wind_direction=90.0)
        rows.append(("tsn", ISSUE, t.strftime("%Y-%m-%d %H:%M:%S"), *(vals[c] for c in WEATHER_COLUMNS)))
    con.executemany(f"INSERT INTO nwp_forecast (location_id, issued_at, timestamp, {', '.join(WEATHER_COLUMNS)}) "
                    f"VALUES ({', '.join('?' * (3 + len(WEATHER_COLUMNS)))})", rows)
    con.commit()
    con.close()


# --- `at` validation --------------------------------------------------------------------------------

@pytest.mark.parametrize("path", ["/weather/current", "/weather/hourly", "/weather/daily",
                                  "/weather/ai-forecast", "/weather/ai-verify"])
@pytest.mark.parametrize("at", ["2024-06-10T15:00", "2021-06-09T23:00", "garbage", "2021-06-10T00:00:00+07:00 "])
def test_at_validation(client, path, at):
    # frozen now 2024-06-10 14:23; earliest row 2021-06-08 00:00 -> earliest allowed 2021-06-10 00:00
    expected = 200 if at.startswith("2021-06-10") else 400
    r = client.get(path, params={"at": at})
    if expected == 200 and path in ("/weather/hourly", "/weather/daily"):
        assert r.status_code == 200
    elif expected == 200:
        assert r.status_code in (200, 503)   # 2021-06-10 has exactly 48 h of history
    else:
        assert r.status_code == 400, r.text


def test_at_same_hour_as_now_is_allowed(client):
    assert client.get("/weather/current", params={"at": "2024-06-10T14:59"}).status_code == 200


def test_at_offset_and_unencoded_plus(client):
    for at in ("2023-06-20T05:00:00Z", "2023-06-20T12:30:00+07:00", "2023-06-20T12:59"):
        body = client.get("/weather/current", params={"at": at}).json()
        assert _ts(body["timestamp"]) == T.replace(tzinfo=LOCAL_TZ), at
    # a literal "+" in the query string decodes to a space
    r = client.get("/weather/current?at=2023-06-20T12:00:00+07:00")
    assert _ts(r.json()["timestamp"]) == T.replace(tzinfo=LOCAL_TZ)


# --- /current ---------------------------------------------------------------------------------------

def test_current_replay_never_after_at(client, syn_db):
    body = client.get("/weather/current", params={"at": "2023-06-20T12:45"}).json()
    assert _ts(body["timestamp"]) == T.replace(tzinfo=LOCAL_TZ)
    assert body["source"] == "observed"
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp = ?", (T.strftime("%Y-%m-%d %H:%M:%S"),))
    con.close()
    body = client.get("/weather/current", params={"at": T_ISO}).json()
    assert _ts(body["timestamp"]) == (T - timedelta(hours=1)).replace(tzinfo=LOCAL_TZ)


def test_current_live_source(client):
    body = client.get("/weather/current").json()
    assert body["source"] == "observed" and _ts(body["timestamp"]) == LAST_TS.replace(tzinfo=LOCAL_TZ)


# --- /hourly + /daily: sources ------------------------------------------------------------------------

def test_hourly_live_without_own_input_is_unavailable(client):
    assert client.get('/weather/hourly', params={'hours': 24}).status_code == 503
    assert client.get('/weather/daily', params={'days': 7}).status_code == 503


def test_hourly_replay_observed_then_climatology(client, syn_db):
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp > '2023-06-20 15:00:00'")
    con.close()
    weather_router.invalidate_climatology()
    items = client.get("/weather/hourly", params={"hours": 6, "at": T_ISO}).json()
    assert [_ts(x["timestamp"]).hour for x in items] == [12, 13, 14, 15, 16, 17]
    assert [x["source"] for x in items] == ["observed"] * 4 + ["climatology"] * 2
    for x in items[:4]:
        assert x["rain_probability"] == (1.0 if x["precipitation"] >= 0.1 else 0.0)
        assert x["wind_speed"] is not None and x["wind_gusts"] is not None and x["wind_direction"] is not None


def test_hourly_replay_shows_what_happened(client, syn_rows):
    items = client.get("/weather/hourly", params={"hours": 12, "at": T_ISO}).json()
    assert len(items) == 12 and {x["source"] for x in items} == {"observed"}
    by_ts = {r["timestamp"]: r for r in syn_rows if r["timestamp"].startswith("2023-")}
    for x in items:
        row = by_ts[_ts(x["timestamp"]).strftime("%Y-%m-%d %H:%M:%S")]
        assert x["temperature"] == row["temperature"] and x["precipitation"] == row["precipitation"]


def test_daily_replay_shows_what_happened(client, syn_rows):
    days = client.get("/weather/daily", params={"days": 3, "at": T_ISO}).json()
    assert [d["date"] for d in days] == ["2023-06-20", "2023-06-21", "2023-06-22"]
    for d in days:   # same per-hour rule as /hourly: every stored hour is observed, also after `at`
        rows = [r for r in syn_rows if r["timestamp"].startswith(d["date"])]
        total = sum(r["precipitation"] for r in rows)
        assert d["source"] == "observed"
        assert d["precipitation_total"] == round(total, 2)
        assert d["rain_day_probability"] == (1.0 if total >= 1 else 0.0)
        assert d["temperature_max"] == max(r["temperature"] for r in rows)


def test_daily_replay_partly_observed_is_climatology(client, syn_db):
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp > '2023-06-20 15:00:00'")
    con.close()
    weather_router.invalidate_climatology()
    days = client.get("/weather/daily", params={"days": 2, "at": T_ISO}).json()
    assert [d["source"] for d in days] == ["climatology", "climatology"]   # 16 observed + 8 climatology hours


def test_daily_replay_at_end_of_day_is_observed(client, syn_rows):
    day = client.get("/weather/daily", params={"days": 1, "at": "2023-06-20T23:00"}).json()[0]
    assert day["source"] == "observed"
    rows = [r for r in syn_rows if r["timestamp"].startswith("2023-06-20")]
    total = sum(r["precipitation"] for r in rows)
    assert day["precipitation_total"] == round(total, 2) == day["precipitation_median"]
    assert day["rain_day_probability"] == (1.0 if total >= 1 else 0.0)
    assert day["temperature_max"] == max(r["temperature"] for r in rows)
    assert day["wind_gusts_max"] == max(r["wind_gusts"] for r in rows)


@pytest.fixture
def live_nwp(client, syn_db, monkeypatch):
    freeze_now(monkeypatch, LIVE_NOW)
    return syn_db


def test_hourly_live_does_not_serve_external_forecast(client, live_nwp):
    _add_forecast(live_nwp)
    response = client.get('/weather/hourly', params={'hours': 24})
    assert response.status_code == 503  # old input cannot be served by a post-2024 model


def test_hourly_live_beyond_forecast_never_falls_back_to_climatology(client, live_nwp, monkeypatch):
    # climatology only covers June 8-24, so run this one a day earlier with a 3 h issue
    _add_forecast(live_nwp)
    with sqlite3.connect(live_nwp) as con:
        con.execute("DELETE FROM nwp_forecast WHERE timestamp > '2023-06-25 03:00:00'")
        con.execute("UPDATE nwp_forecast SET timestamp = datetime(timestamp, '-1 day'), "
                    "issued_at = '2023-06-23 23:00:00'")
        con.execute("DELETE FROM hourly_weather WHERE timestamp > '2023-06-23 23:00:00'")
    con.close()
    weather_router.invalidate_climatology()
    freeze_now(monkeypatch, LIVE_NOW - timedelta(days=1))
    assert client.get('/weather/hourly', params={'hours': 7}).status_code == 503


def test_daily_live_ai_aggregation(client, live_nwp, monkeypatch):
    d25 = datetime(2023, 6, 25)
    codes = {d25 + timedelta(hours=5): 51,                                     # isolated drizzle: ignored
             d25 + timedelta(days=1, hours=5): 53, d25 + timedelta(days=1, hours=6): 51,   # 2 h drizzle
             d25 + timedelta(days=2, hours=3): 95, d25 + timedelta(days=2, hours=9): 61}
    _add_forecast(live_nwp, code_at=codes)
    weather_router.invalidate_climatology()
    from models import WeatherData
    forecast = {}
    for k in range(72):
        t = d25 + timedelta(hours=k)
        forecast[t] = WeatherData(timestamp=t.replace(tzinfo=LOCAL_TZ), temperature=25.0 + k % 24 / 10,
                                 rain_probability=(40 + k % 24) / 100, precipitation=0.0,
                                 weather_code=codes.get(t, 3), source='ai')
    monkeypatch.setattr(weather_router, '_own_forecast_rows', lambda sid, now: forecast)
    days = client.get("/weather/daily", params={"days": 4}).json()
    assert [d["date"] for d in days] == ["2023-06-24", "2023-06-25", "2023-06-26", "2023-06-27"]
    assert days[0]["source"] == "observed"
    assert [d['source'] for d in days[1:]] == ['ai'] * 3
    assert [d["weather_code"] for d in days[1:]] == [3, 53, 95]
    for d in days[1:]:
        assert d['rain_day_probability'] is None  # no calibrated daily-event target
        assert d['precipitation_total'] == 0.0
        assert d['precipitation_median'] is None
        assert d['wind_gusts_max'] is None
        assert d["temperature_min"] <= d["temperature_avg"] <= d["temperature_max"]
    assert days[1]["temperature_min"] != days[1]["temperature_max"]


def test_replay_ignores_forecast(client, syn_db):
    _add_forecast(syn_db)
    items = client.get("/weather/hourly", params={"hours": 3, "at": "2023-06-24T22:00"}).json()
    assert [x["source"] for x in items] == ["observed", "observed"]   # 06-25: no forecast, no climatology


# --- AI: target_time, leakage, verify -----------------------------------------------------------------

def test_ai_forecast_target_time(client):
    body = client.get("/weather/ai-forecast", params={"at": T_ISO}).json()
    issued = _ts(body["issued_at"])
    assert issued == T.replace(tzinfo=LOCAL_TZ)
    for h in (1, 3, 6):
        assert _ts(body["predictions"][f"{h}h"]["target_time"]) == issued + timedelta(hours=h)
    assert "model_version" in body


def test_ai_forecast_at_no_leak(tmp_path, syn_rows, monkeypatch):
    freeze_now(monkeypatch)
    cut_rows = [r for r in syn_rows if r["timestamp"] <= T.strftime("%Y-%m-%d %H:%M:%S")]
    bodies = []
    for name, rows in (("full.db", syn_rows), ("cut.db", cut_rows)):
        point_app_at(monkeypatch, write_db(tmp_path / name, rows))
        weather_router.invalidate_climatology()
        c = TestClient(main.app)
        bodies.append(c.get("/weather/ai-forecast", params={"at": "2023-06-20T12:40"}).json())
        cur = c.get("/weather/current", params={"at": "2023-06-20T12:40"}).json()
        assert _ts(cur["timestamp"]) == T.replace(tzinfo=LOCAL_TZ)
    weather_router.invalidate_climatology()
    assert bodies[0] == bodies[1]
    assert bodies[0]["issued_at"] == T_ISO + "+07:00"


def test_ai_verify_past(client, syn_rows):
    body = client.get("/weather/ai-verify", params={"at": T_ISO}).json()
    assert body["issued_at"] == T_ISO + "+07:00" and "model_version" in body
    by_ts = {r["timestamp"]: r for r in syn_rows if r["timestamp"].startswith("2023-")}
    assert [h["horizon"] for h in body["horizons"]] == ["1h", "3h", "6h"]
    for h, k in zip(body["horizons"], (1, 3, 6)):
        target = T + timedelta(hours=k)
        assert _ts(h["target_time"]) == target.replace(tzinfo=LOCAL_TZ)
        row = by_ts[target.strftime("%Y-%m-%d %H:%M:%S")]
        assert h["actual_temperature"] == row["temperature"]
        assert h["actual_precipitation"] == row["precipitation"]
        assert h["actual_rain"] is (row["precipitation"] >= 0.1)
        assert h["abs_error_temperature"] == round(abs(h["predicted_temperature"] - row["temperature"]), 2)
        assert 0 <= h["predicted_rain_probability"] <= 1


def test_ai_verify_future_targets_are_null(client, monkeypatch):
    freeze_now(monkeypatch, LIVE_NOW)   # latest row 23:00; at 21:00 -> 1h known, 3h/6h in the future
    body = client.get("/weather/ai-verify", params={"at": "2023-06-24T21:00"}).json()
    h1, h3, h6 = body["horizons"]
    assert h1["actual_temperature"] is not None and h1["actual_rain"] is not None
    for h in (h3, h6):
        assert h["actual_temperature"] is None and h["actual_precipitation"] is None
        assert h["actual_rain"] is None and h["abs_error_temperature"] is None
        assert h["predicted_temperature"] is not None


def test_ai_verify_default_is_now_minus_6h(client, monkeypatch):
    freeze_now(monkeypatch, LIVE_NOW)
    body = client.get("/weather/ai-verify").json()
    assert body["issued_at"] == "2023-06-24T17:00:00+07:00"
    assert all(h["actual_temperature"] is not None for h in body["horizons"])


# --- UV index and air quality -------------------------------------------------------------------------

def _add_aq(db, rows):
    con = sqlite3.connect(db)
    migrate(con)
    con.executemany("INSERT INTO air_quality (location_id, timestamp, us_aqi, pm2_5, pm10) VALUES ('tsn', ?, ?, ?, ?)",
                    rows)
    con.commit()
    con.close()


def test_current_air_quality_same_hour_and_uv(client, live_nwp):
    _add_aq(live_nwp, [("2023-06-24 22:00:00", 40, 10, 20), ("2023-06-24 23:00:00", 55, 15.5, 30),
                       ("2023-06-25 00:00:00", 99, 50, 60)])
    with sqlite3.connect(live_nwp) as con:
        con.execute("UPDATE hourly_weather SET uv_index = 0.5 WHERE timestamp = '2023-06-24 23:00:00'")
    con.close()
    body = client.get("/weather/current").json()
    assert (body["us_aqi"], body["pm2_5"], body["pm10"], body["uv_index"]) == (55, 15.5, 30, 0.5)


def test_current_air_quality_nearest_and_bounded_by_at(client, syn_db):
    _add_aq(syn_db, [("2023-06-20 13:00:00", 99, 1, 1)])
    body = client.get("/weather/current", params={"at": T_ISO}).json()
    assert body["us_aqi"] is None and body["pm2_5"] is None          # 13:00 is after `at`
    _add_aq(syn_db, [("2023-06-20 11:00:00", 42, 2, 3)])
    body = client.get("/weather/current", params={"at": T_ISO}).json()
    assert (body["us_aqi"], body["pm2_5"], body["pm10"]) == (42, 2, 3)  # nearest within 1 h, not after `at`
    body = client.get("/weather/current", params={"at": "2023-06-20T15:00"}).json()
    assert body["us_aqi"] is None                                      # nothing within +-1 h of 15:00


def test_own_forecast_never_borrows_external_uv_aqi(client, live_nwp, monkeypatch):
    _add_forecast(live_nwp)
    _add_aq(live_nwp, [("2023-06-25 01:00:00", 80, 20, 30), ("2023-06-25 05:00:00", 120, 40, 50)])
    weather_router.invalidate_climatology()
    from models import WeatherData
    forecast = {LAST_TS + timedelta(hours=h): WeatherData(
        timestamp=(LAST_TS + timedelta(hours=h)).replace(tzinfo=LOCAL_TZ), temperature=28.0,
        rain_probability=0.2, precipitation=0.0, source='ai') for h in range(1, 169)}
    monkeypatch.setattr(weather_router, '_own_forecast_rows', lambda sid, now: forecast)
    items = client.get("/weather/hourly", params={"hours": 6}).json()
    assert all(x['us_aqi'] is None and x['uv_index'] is None for x in items)
    days = client.get("/weather/daily", params={"days": 2}).json()
    assert days[1]['us_aqi_max'] is None and days[1]['uv_index_max'] is None
    assert days[0]["us_aqi_max"] is None


def test_climatology_uv_needs_history(client, syn_db):
    con = sqlite3.connect(syn_db)
    migrate(con)
    con.execute("UPDATE hourly_weather SET uv_index = 7 WHERE timestamp >= '2023-01-01'")   # one year only
    con.commit()
    con.close()
    weather_router.invalidate_climatology()
    items = client.get('/weather/hourly', params={'hours': 3, 'at': FROZEN_NOW.isoformat()}).json()
    assert {x["source"] for x in items} == {"climatology"}
    assert all(x["uv_index"] is None and x["us_aqi"] is None for x in items)
    assert client.get('/weather/daily', params={'days': 1, 'at': FROZEN_NOW.isoformat()}).json()[0]['uv_index_max'] is None

    con = sqlite3.connect(syn_db)
    con.execute("UPDATE hourly_weather SET uv_index = 7")                                   # all 3 years
    con.commit()
    con.close()
    weather_router.invalidate_climatology()
    items = client.get('/weather/hourly', params={'hours': 3, 'at': FROZEN_NOW.isoformat()}).json()
    assert all(x["uv_index"] == 7.0 for x in items)
    assert client.get('/weather/daily', params={'days': 1, 'at': FROZEN_NOW.isoformat()}).json()[0]['uv_index_max'] == 7.0
