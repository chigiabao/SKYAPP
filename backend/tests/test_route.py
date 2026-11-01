"""POST /route and POST /route/along-weather. OSRM is mocked (routers.route._http_get); no network access."""
import sqlite3
import json
import time
from datetime import timedelta
from types import SimpleNamespace

import httpx
import pytest

from conftest import FROZEN_NOW
from models import WeatherData
from routers import route

TSN = (10.7909, 106.6313)          # inside HCMC
BEN_THANH = (10.7725, 106.6980)    # inside HCMC
HANOI_A, HANOI_B = (21.03, 105.85), (21.00, 105.80)
CAN_THO = (10.03, 105.78)          # outside, ~120 km away


def _line(a, b, n=60):
    return [(a[0] + (b[0] - a[0]) * i / (n - 1), a[1] + (b[1] - a[1]) * i / (n - 1)) for i in range(n)]


class FakeOSRM:
    """Straight line between the requested points, 10 s per segment."""

    def __init__(self):
        self.calls = []
        self.fail = None          # exception instance to raise
        self.status = 200
        self.code = "Ok"
        self.distance_m = None    # override the reported distance

    def __call__(self, url, params):
        self.calls.append((url, dict(params)))
        if self.fail is not None:
            raise self.fail
        lon1, lat1, lon2, lat2 = map(float, url.rsplit("/", 1)[1].replace(";", ",").split(","))
        pts = _line((lat1, lon1), (lat2, lon2))
        km = route._cumulative_km(pts)[-1]
        body = {"code": self.code, "routes": [{
            "distance": self.distance_m if self.distance_m is not None else km * 1000,
            "duration": 10.0 * (len(pts) - 1),
            "geometry": {"type": "LineString", "coordinates": [[p[1], p[0]] for p in pts]},
            "legs": [{"annotation": {"duration": [10.0] * (len(pts) - 1)}}]}]}
        if self.code != "Ok":
            body = {"code": self.code, "message": "no route"}
        return httpx.Response(self.status, json=body)


@pytest.fixture
def osrm(client, monkeypatch):
    fake = FakeOSRM()
    monkeypatch.setattr(route, "_http_get", fake)
    monkeypatch.setattr(route, "OSRM_MIN_INTERVAL", 0)
    monkeypatch.setattr(route, "now_local", lambda: FROZEN_NOW)
    route._cache.clear()
    route._cells.cache_clear()
    yield fake
    route._cache.clear()
    route._cells.cache_clear()


def _get(client, a, b, **params):
    return client.post("/route", json={"from_lat": a[0], "from_lon": a[1], "to_lat": b[0], "to_lon": b[1], **params})


@pytest.mark.parametrize("path", ["/route", "/route/"])
def test_legacy_route_query_is_rejected_without_redirect(client, osrm, path):
    response = client.get(path, params={"from_lat": TSN[0], "from_lon": TSN[1],
                                           "to_lat": BEN_THANH[0], "to_lon": BEN_THANH[1]})
    assert response.status_code == 405 and response.headers["allow"] == "POST"
    assert "location" not in response.headers and not osrm.calls
    assert str(TSN[0]) not in response.text


@pytest.mark.parametrize("payload", [None, [], {"code": "Ok", "routes": [None]},
                                     {"code": "Ok", "routes": [1]},
                                     {"code": "Ok", "routes": [{}]},
                                     {"code": "Ok", "routes": "invalid"}])
def test_malformed_osrm_success_is_controlled(client, osrm, monkeypatch, syn_db, payload):
    monkeypatch.setattr(route, "_http_get", lambda *args: httpx.Response(200, json=payload))
    response = _get(client, TSN, BEN_THANH)
    assert response.status_code == 503 and "OSRM" in response.json()["detail"]
    assert not route._cache
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT calls, errors FROM api_call_log").fetchone() == (1, 1)


@pytest.mark.parametrize("key, value", [
    ("geometry", None), ("geometry", {"coordinates": [[106.6]]}),
    ("geometry", {"coordinates": [[106.6, 10.7], [106.7, float("nan")]]}),
    ("geometry", {"coordinates": [[106.6, 10.7], [float("inf"), 10.8]]}),
    ("geometry", {"coordinates": [[106.6, 10.7], [106.7, 91]]}),
    ("geometry", {"coordinates": [[106.6, 10.7], [106.7, "10.8"]]}),
    ("geometry", {"coordinates": [[106.6, 10.7], [0, 0], [106.7, 10.8]]}),
    ("distance", float("inf")), ("distance", -1), ("distance", {}),
    ("duration", float("nan")), ("duration", 1e100), ("duration", True),
    ("legs", [None]), ("legs", [{"annotation": {"duration": ["bad"]}}]),
    ("legs", [{"annotation": {"duration": [-1]}}]),
    ("legs", [{"annotation": {"duration": [float("inf")]}}]),
    ("legs", [{"annotation": {"duration": [route.MAX_DURATION_SECONDS + 1]}}]),
])
def test_invalid_osrm_route_values_are_not_cached(client, osrm, monkeypatch, key, value):
    valid = {"geometry": {"coordinates": [[106.6313, 10.7909], [106.698, 10.7725]]},
             "duration": 600, "distance": 1000}
    valid[key] = value
    payload = json.dumps({"code": "Ok", "routes": [valid]}).encode()
    monkeypatch.setattr(route, "_http_get", lambda *args: httpx.Response(200, content=payload))
    assert _get(client, TSN, BEN_THANH).status_code == 503
    assert not route._cache


def test_osrm_geometry_point_limit(client, osrm, monkeypatch):
    payload = {"code": "Ok", "routes": [{"geometry": {
        "coordinates": [[106.6, 10.7]] * (route.MAX_INPUT_POINTS + 1)}, "distance": 1, "duration": 1}]}
    monkeypatch.setattr(route, "_http_get", lambda *args: httpx.Response(200, json=payload))
    assert _get(client, TSN, BEN_THANH).status_code == 503


def test_osrm_response_byte_limit_is_controlled(client, osrm, monkeypatch):
    monkeypatch.setattr(route, "OSRM_MAX_RESPONSE_BYTES", 16)
    monkeypatch.setattr(route, "_http_get", lambda *args: httpx.Response(200, content=b" " * 17))
    assert _get(client, TSN, BEN_THANH).status_code == 503


def test_osrm_stream_stops_at_actual_byte_limit(monkeypatch):
    consumed = []

    class Stream(httpx.SyncByteStream):
        def __iter__(self):
            for chunk in [b"12345678", b"123456789", b"not consumed"]:
                consumed.append(chunk)
                yield chunk

    response = httpx.Response(200, headers={"Content-Length": "1"}, stream=Stream())
    with httpx.Client(transport=httpx.MockTransport(lambda request: response)) as upstream:
        monkeypatch.setattr(route, "OSRM_MAX_RESPONSE_BYTES", 16)
        monkeypatch.setattr(route.httpx, "stream", upstream.stream)
        with pytest.raises(route.OsrmError, match="too large"):
            route._http_get("https://osrm.test/route", {})
    assert len(consumed) == 2 and response.is_closed


@pytest.mark.parametrize('status, payload', [(200, b'{"code":"Ok"}'), (503, b'upstream unavailable')])
def test_osrm_stream_returns_buffered_response(monkeypatch, status, payload):
    class Stream(httpx.SyncByteStream):
        def __iter__(self):
            yield payload[:5]
            yield payload[5:]

    response = httpx.Response(status, stream=Stream())
    with httpx.Client(transport=httpx.MockTransport(lambda request: response)) as upstream:
        monkeypatch.setattr(route.httpx, 'stream', upstream.stream)
        result = route._http_get('https://osrm.test/route', {})
    assert response.is_closed
    assert result.status_code == status
    assert result.content == payload
    if status == 200:
        assert result.json() == {'code': 'Ok'}


def test_route_reads_real_http_helper_with_streamed_upstream(client, monkeypatch):
    payload = FakeOSRM()(
        'https://osrm.test/route/106.6313,10.7909;106.6980,10.7725', {}
    ).content

    class Stream(httpx.SyncByteStream):
        def __iter__(self):
            yield payload[:40]
            yield payload[40:]

    route._cache.clear()
    route._cells.cache_clear()
    monkeypatch.setattr(route, 'OSRM_MIN_INTERVAL', 0)
    with httpx.Client(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, stream=Stream()))) as upstream:
        monkeypatch.setattr(route.httpx, 'stream', upstream.stream)
        result = _get(client, TSN, BEN_THANH)
    assert result.status_code == 200, result.text
    assert len(result.json()['geometry']) >= 2
    route._cache.clear()
    route._cells.cache_clear()


@pytest.mark.parametrize("field", ["from_lat", "from_lon", "to_lat", "to_lon"])
@pytest.mark.parametrize("value", ["NaN", "Infinity", "-Infinity"])
def test_post_route_rejects_nonfinite_coordinates(client, osrm, field, value):
    body = {"from_lat": TSN[0], "from_lon": TSN[1], "to_lat": BEN_THANH[0], "to_lon": BEN_THANH[1]}
    body[field] = value
    assert client.post("/route", json=body).status_code == 422
    assert not osrm.calls


def test_route_samples_weather_and_cache(client, osrm, syn_db):
    r = _get(client, TSN, BEN_THANH)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["attribution"] == "© OpenStreetMap contributors, OSRM"
    assert body["cached"] is False and len(osrm.calls) == 1
    url, params = osrm.calls[0]
    assert url.startswith("https://router.project-osrm.org/route/v1/driving/")
    assert params["geometries"] == "geojson"
    assert 7 < body["distance_km"] < 8.5 and body["duration_min"] == pytest.approx(59 * 10 / 60, abs=0.1)
    assert 2 <= len(body["geometry"]) <= 300
    s = body["samples"]
    assert len(s) == 5   # 0, 2, 4, 6 km + destination
    assert s[0]["eta"] == FROZEN_NOW.isoformat(timespec="seconds")
    assert [x["eta"] for x in s] == sorted(x["eta"] for x in s)
    assert all(x['cell_id'] is not None for x in s)
    # Geometry remains usable, but stale/missing own forecasts never become climatology.
    assert all(x['temperature'] is None and x['source'] is None for x in s)
    assert all(not x['forecast_available'] and not x['hazard_assessment_complete'] for x in s)
    assert set(s[0]) >= {"lat", "lon", "eta", "cell_id", "temperature", "precipitation", "rain_probability",
                         "weather_code", "wind_gusts", "humidity", "wind_speed", "uv_index", "alert", "alert_reason"}
    assert all(x[field] is None for x in s for field in ('humidity', 'wind_speed', 'uv_index'))
    assert body["worst"] in s
    again = _get(client, (TSN[0] + 0.00001, TSN[1]), BEN_THANH).json()   # same key at 4 decimals
    assert again["cached"] is True and len(osrm.calls) == 1
    with sqlite3.connect(syn_db) as con:
        assert con.execute("SELECT service, calls, errors FROM api_call_log").fetchall() == [("osrm", 1, 0)]
    con.close()


def test_route_profiles_use_matching_servers(client, osrm):
    assert _get(client, TSN, BEN_THANH, profile="foot").status_code == 200
    assert "routed-foot" in osrm.calls[-1][0]
    assert _get(client, TSN, BEN_THANH, profile="plane").status_code == 422


def test_route_eta_follows_depart_at(client, osrm):
    dep = (FROZEN_NOW + timedelta(hours=5)).replace(minute=0, second=0)
    body = _get(client, TSN, BEN_THANH, depart_at=dep.replace(tzinfo=None).isoformat()).json()
    assert body["depart_at"] == dep.isoformat()
    assert body["samples"][-1]["eta"] == (dep + timedelta(seconds=590)).isoformat()
    assert _get(client, TSN, BEN_THANH, depart_at="hôm qua").status_code == 400
    assert _get(client, TSN, BEN_THANH, depart_at=(FROZEN_NOW + timedelta(days=30)).isoformat()).status_code == 400


def test_route_alert_and_worst(client, osrm, monkeypatch):
    def fake_series(times, obs_until, use_forecast, sid):
        return [SimpleNamespace(temperature=30.0, precipitation=12.0 if t.hour % 2 else 0.0,
                                rain_probability=0.9, weather_code=95 if t.hour % 2 else 2, wind_gusts=20.0,
                                humidity=None, wind_speed=None, uv_index=None, source="forecast") for t in times]
    monkeypatch.setattr(route, "_series", fake_series)
    dep = FROZEN_NOW.replace(hour=15, minute=25, second=0)   # ETAs 15:25..15:35 -> hours 15 (odd) and 16 (even)
    body = _get(client, TSN, BEN_THANH, depart_at=dep.isoformat()).json()
    assert body["alert"] is True
    w = body["worst"]
    assert w["alert"] is True and w["weather_code"] == 95 and "Dông" in w["alert_reason"] and "Mưa to" in w["alert_reason"]
    assert any(not s["alert"] and s["alert_reason"] is None for s in body["samples"])
    assert all(s['forecast_available'] and s['hazard_assessment_complete'] for s in body['samples'])


@pytest.mark.parametrize('field, value, expected', [
    ('humidity', 78.56, 78.6), ('humidity', 0.0, 0.0), ('humidity', None, None),
    ('wind_speed', 60.36, 60.4), ('wind_speed', 0.0, 0.0), ('wind_speed', None, None),
    ('uv_index', 8.26, 8.3), ('uv_index', 0.0, 0.0), ('uv_index', None, None),
])
def test_route_additional_hourly_fields(client, osrm, monkeypatch, field, value, expected):
    def hourly(times, *args):
        return [WeatherData(timestamp=t, source='observed', **{field: value}) for t in times]

    monkeypatch.setattr(route, '_series', hourly)
    response = _get(client, TSN, BEN_THANH)
    assert response.status_code == 200, response.text
    body = response.json()
    refreshed = client.post('/route/along-weather', json={'geometry': body['geometry'], 'duration_min': 20})
    assert refreshed.status_code == 200, refreshed.text
    for result in (body, refreshed.json()):
        assert result['samples'] and not result['alert']
        for sample in result['samples']:
            assert sample[field] == expected
            assert all(sample[other] is None for other in ('humidity', 'wind_speed', 'uv_index') if other != field)
            assert sample['forecast_available'] is (value is not None)
            assert not sample['hazard_assessment_complete']
            assert sample['weather_code'] is None and sample['wind_gusts'] is None
            assert not sample['alert'] and sample['alert_reason'] is None


def test_unavailable_forecast_keeps_geometry_without_hazard_assessment(client, osrm, monkeypatch):
    def unavailable(*args):
        raise route.HTTPException(status_code=503, detail="own forecast unavailable")

    monkeypatch.setattr(route, "_series", unavailable)
    body = _get(client, TSN, BEN_THANH).json()
    assert len(body['geometry']) >= 2 and body['distance_km'] > 0
    assert body['samples'] and not body['alert']
    assert all(not s['forecast_available'] and not s['hazard_assessment_complete'] for s in body['samples'])
    refreshed = client.post('/route/along-weather', json={'geometry': body['geometry'], 'duration_min': 20})
    assert refreshed.status_code == 200
    assert refreshed.json()['geometry'] == body['geometry']
    assert all(not s['forecast_available'] for s in refreshed.json()['samples'])


@pytest.mark.parametrize('code,gusts,amount', [(None, None, 0.0), (1, 0.0, 0.0), (None, None, 12.0)])
def test_own_ai_never_claims_full_hazard_assessment(client, osrm, monkeypatch, code, gusts, amount):
    def own_ai(times, *args):
        return [SimpleNamespace(temperature=30.0, precipitation=amount, rain_probability=0.1,
                                weather_code=code, wind_gusts=gusts, humidity=78.5, wind_speed=60.0,
                                uv_index=None, source='ai') for _ in times]

    monkeypatch.setattr(route, '_series', own_ai)
    body = _get(client, TSN, BEN_THANH).json()
    assert all(s['forecast_available'] and not s['hazard_assessment_complete'] for s in body['samples'])
    assert all(s['humidity'] == 78.5 and s['wind_speed'] == 60.0 and s['uv_index'] is None for s in body['samples'])
    assert body['alert'] == (amount >= route.ALERT_RAIN_MM_H)


@pytest.mark.parametrize("exc", [httpx.ConnectTimeout("timeout"), httpx.ConnectError("down")])
def test_route_osrm_failure_is_503(client, osrm, exc, syn_db):
    osrm.fail = exc
    r = _get(client, TSN, BEN_THANH)
    assert r.status_code == 503 and "OSRM" in r.json()["detail"]
    with sqlite3.connect(syn_db) as con:
        assert con.execute("SELECT calls, errors FROM api_call_log").fetchone() == (1, 1)
    con.close()


def test_route_osrm_bad_answer(client, osrm):
    osrm.status, osrm.code = 500, "InvalidQuery"
    assert _get(client, TSN, BEN_THANH).status_code == 503
    osrm.status, osrm.code = 400, "NoRoute"
    assert _get(client, TSN, BEN_THANH).status_code == 404


def test_route_rejects_outside_and_too_long(client, osrm):
    r = _get(client, HANOI_A, HANOI_B)
    assert r.status_code == 400 and "ngoài TP.HCM" in r.json()["detail"]
    r = _get(client, TSN, (12.24, 109.19))   # Nha Trang: > 300 km in a straight line, no OSRM call
    assert r.status_code == 400 and "300 km" in r.json()["detail"]
    assert osrm.calls == []
    osrm.distance_m = 350_000   # short straight line, long road route
    assert _get(client, TSN, BEN_THANH).status_code == 400
    assert len(osrm.calls) == 1


def test_route_one_end_outside_has_null_cells(client, osrm):
    s = _get(client, TSN, CAN_THO).json()["samples"]
    assert s[0]["cell_id"] is not None
    assert s[-1]["cell_id"] is None and s[-1]["temperature"] is None and s[-1]["alert"] is False
    assert all(s[-1][field] is None for field in ('humidity', 'wind_speed', 'uv_index'))


def test_along_weather_reuses_geometry_without_osrm(client, osrm):
    first = _get(client, TSN, BEN_THANH).json()
    n = len(osrm.calls)
    r = client.post("/route/along-weather", json={"geometry": first["geometry"], "duration_min": 20,
                                                  "depart_at": FROZEN_NOW.isoformat()})
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(osrm.calls) == n
    assert body["duration_min"] == 20.0 and body["distance_km"] == pytest.approx(first["distance_km"], abs=0.1)
    assert body["samples"][-1]["eta"] == (FROZEN_NOW + timedelta(minutes=20)).isoformat(timespec="seconds")
    assert len(body["samples"]) == len(first["samples"])
    # default duration from the profile speed (foot: 5 km/h)
    foot = client.post("/route/along-weather", json={"geometry": first["geometry"], "profile": "foot"}).json()
    assert foot["duration_min"] == pytest.approx(first["distance_km"] / 5 * 60, abs=1)
    assert client.post("/route/along-weather", json={"geometry": [[10.7, 106.6]]}).status_code == 422
    assert client.post("/route/along-weather", json={"geometry": [[10.7, 106.6, 1], [10.8, 106.7]]}).status_code == 422
    assert client.post("/route/along-weather", json={"geometry": [list(HANOI_A), list(HANOI_B)]}).status_code == 400


def test_simplify_keeps_ends_and_caps_points():
    pts = [(10.7 + i * 1e-4, 106.6 + 0.01 * ((i % 7) - 3) * 1e-2) for i in range(5000)]
    out = route.simplify(pts)
    assert len(out) <= 300
    assert out[0] == [round(pts[0][0], 5), round(pts[0][1], 5)] and out[-1] == [round(pts[-1][0], 5), round(pts[-1][1], 5)]
    assert route.simplify(pts[:10]) == [[round(a, 5), round(b, 5)] for a, b in pts[:10]]


def test_osrm_rate_limit_one_per_interval(client, osrm, monkeypatch):
    monkeypatch.setattr(route, "OSRM_MIN_INTERVAL", 0.3)
    route._last_call[0] = 0.0
    t0 = time.monotonic()
    _get(client, TSN, BEN_THANH)
    _get(client, BEN_THANH, TSN)
    assert len(osrm.calls) == 2 and time.monotonic() - t0 >= 0.3
    assert osrm.calls[0][0] != osrm.calls[1][0]
