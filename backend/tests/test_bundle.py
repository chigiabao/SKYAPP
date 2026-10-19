"""/weather/bundle: same output as /current, /hourly, /daily, /ai-forecast; AI 503 -> null (synthetic DB)."""
import sqlite3
import time

import pytest

T_ISO = "2023-06-20T12:00"


def _singles(client, params, hours=48, days=7):
    return {
        "current": client.get("/weather/current", params=params).json(),
        "hourly": client.get("/weather/hourly", params={**params, "hours": hours}).json(),
        "daily": client.get("/weather/daily", params={**params, "days": days}).json(),
        "ai_forecast": client.get("/weather/ai-forecast", params=params).json(),
    }


def test_bundle_equals_singles_live(client):
    r = client.get("/weather/bundle")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "max-age=60"
    body = r.json()
    assert body["location_id"] == "tsn" and body["cell_id"] == "tsn"
    assert body["generated_at"].endswith("+07:00")
    assert body["ai_error"] is None
    assert body['current'] == client.get('/weather/current').json()
    assert body['ai_forecast'] == client.get('/weather/ai-forecast').json()
    assert body['hourly'] == [] and body['daily'] == []
    assert body['forecast_provider'] == 'sky_weather_ai'
    assert body['forecast_error'] == client.get('/weather/hourly').json()['detail']
    assert client.get('/weather/daily').status_code == 503


@pytest.mark.parametrize("params", [{"at": T_ISO}, {"at": T_ISO, "location_id": "tsn"}])
def test_bundle_equals_singles_replay(client, params):
    r = client.get("/weather/bundle", params={**params, "hours": 12, "days": 3})
    assert r.status_code == 200
    assert "cache-control" not in r.headers
    body = r.json()
    for key, value in _singles(client, params, hours=12, days=3).items():
        assert body[key] == value, key
    assert len(body["hourly"]) == 12 and len(body["daily"]) == 3


def test_bundle_ai_503_is_null(client, syn_db):
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp = '2023-06-24 10:00:00'")
    con.close()
    ai = client.get("/weather/ai-forecast")
    assert ai.status_code == 503
    r = client.get("/weather/bundle")
    assert r.status_code == 200
    body = r.json()
    assert body["ai_forecast"] is None
    assert body["ai_error"] == ai.json()["detail"]
    assert body["current"] == client.get("/weather/current").json()


@pytest.mark.parametrize("params,code", [
    ({"location_id": "khong-ton-tai"}, 404),
    ({"at": "not-a-date"}, 400),
    ({"at": "2030-01-01T00:00"}, 400),
    ({"hours": 0}, 422), ({"hours": 169}, 422), ({"days": 0}, 422), ({"days": 15}, 422),
])
def test_bundle_errors_match_singles(client, params, code):
    r = client.get("/weather/bundle", params=params)
    assert r.status_code == code
    single = {k: v for k, v in params.items() if k in ("location_id", "at")}
    if single:
        s = client.get("/weather/current", params=single)
        assert (s.status_code, s.json()) == (r.status_code, r.json())


def test_bundle_real_db_fast_when_warm(real_client):
    real_client.get("/weather/bundle")   # warm caches
    best = float("inf")
    for _ in range(3):
        t0 = time.perf_counter()
        r = real_client.get("/weather/bundle")
        best = min(best, time.perf_counter() - t0)
        assert r.status_code == 200
    print(f"bundle warm: {best * 1000:.0f} ms")
    assert best < 1.0   # target ~300 ms; loose bound so slow CI machines do not flake
