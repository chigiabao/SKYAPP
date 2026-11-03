"""Own-model HTTP integration tests with synthetic data."""
import sqlite3
from datetime import datetime, timedelta
from unittest.mock import Mock

import pytest

import ai_model
import long_range_model_v2 as long_range_model
from conftest import freeze_now
from database import LOCAL_TZ, weather_data_revision
from routers import weather, weather_climatology, weather_core


NOW = datetime(2023, 6, 20, 12, tzinfo=LOCAL_TZ)
CELL = "om-10.7909-106.6313"
UNSUPPORTED = (
    "dew_point", "apparent_temperature", "visibility", "surface_pressure",
    "pressure_msl", "wind_direction", "wind_gusts", "uv_index", "us_aqi",
    "pm2_5", "pm10", "precipitation_median",
)


def _values(horizon):
    if horizon == 1:
        return dict.fromkeys(("temperature", "rain_probability", "humidity",
                              "precipitation_mm", "wind_speed", "cloud_cover"), 0.0)
    return {
        "temperature": round(20 + horizon / 10, 1),
        "rain_probability": (horizon % 5) / 10,
        "humidity": float(60 + horizon % 20),
        "precipitation_mm": (horizon % 4) / 10,
        "wind_speed": float(horizon % 7),
        "cloud_cover": float((horizon % 10) * 10),
    }


def _predict(history, cell_id):
    issue = datetime.fromisoformat(str(history.timestamp.iloc[-1])).replace(tzinfo=LOCAL_TZ)
    assert cell_id == CELL
    assert len(history) >= 48
    assert history.timestamp.is_monotonic_increasing
    assert issue < weather_core.now_local().replace(minute=0, second=0, microsecond=0)
    return {
        "issued_at": issue.isoformat(), "source": "ai", "cell_id": cell_id,
        "model_version": "synthetic-own-168h",
        "predictions": {
            f"{h}h": {"valid_at": (issue + timedelta(hours=h)).isoformat(), **_values(h)}
            for h in range(1, 169)
        },
    }


def _forbidden(*args, **kwargs):
    raise AssertionError("Live forecast must not use NWP or climatology")


@pytest.fixture
def live(client, monkeypatch):
    freeze_now(monkeypatch, NOW)
    monkeypatch.setattr(weather_core, "_forecast_rows", _forbidden)
    monkeypatch.setattr(weather_climatology, "_climatology", _forbidden)
    predictor = Mock(side_effect=_predict)
    monkeypatch.setattr(long_range_model, "predict", predictor)
    monkeypatch.setattr(long_range_model, "artifact_revision", lambda: ("synthetic", 1), raising=False)
    monkeypatch.setattr(long_range_model, "status", lambda: {
        "status": "available", "cell_ids": [CELL],
        "trained_through": "2023-06-01T00:00:00+07:00",
    })
    # The bundle's separate short-range AI must not load real artifacts either.
    def no_short_model(*args, **kwargs):
        raise ValueError("synthetic short-range unavailable")
    monkeypatch.setattr(ai_model, "predict_for_location", no_short_model)
    weather.invalidate_climatology()
    yield client, predictor
    weather.invalidate_climatology()


def _get(client, path, **params):
    response = client.get(f"/weather/{path}", params=params)
    assert response.status_code == 200, response.text
    return response.json()


def test_live_hourly_uses_ai_not_future_database_rows(live):
    client, predictor = live
    rows = _get(client, "hourly", hours=168)
    assert len(rows) == 168
    assert rows[0]["source"] == "ai"
    assert rows[0]["timestamp"] == NOW.isoformat()
    for h, row in enumerate(rows, start=1):
        expected = _values(h)
        assert row["timestamp"] == (NOW + timedelta(hours=h - 1)).isoformat()
        assert row['issued_at'] == (NOW - timedelta(hours=1)).isoformat()
        assert row['model_version'] == 'synthetic-own-168h'
        assert row["source"] == "ai"
        for field in ("temperature", "humidity", "wind_speed", "cloud_cover", "rain_probability"):
            assert row[field] == expected[field]
        assert row["precipitation"] == expected["precipitation_mm"]
        assert row["rain"] == expected["precipitation_mm"]
        assert row["precipitation_probability"] == pytest.approx(expected["rain_probability"] * 100)
        assert all(row[field] is None for field in UNSUPPORTED)
    assert all(rows[0][field] == 0.0 for field in (
        "temperature", "humidity", "rain_probability", "precipitation_probability",
        "precipitation", "rain", "wind_speed", "cloud_cover", "weather_code",
    ))
    predictor.assert_called_once()
    assert str(predictor.call_args.args[0].timestamp.iloc[-1]) == "2023-06-20 11:00:00"


def test_live_daily_seven_days_aggregate_observed_and_own_ai(live, syn_rows):
    client, _ = live
    days = _get(client, "daily", days=7)
    assert len(days) == 7
    start = NOW.replace(hour=0)
    observed = {r["timestamp"]: r for r in syn_rows}
    for d, day in enumerate(days):
        date_start = start + timedelta(days=d)
        expected = []
        for h in range(24):
            t = date_start + timedelta(hours=h)
            if t < NOW:
                row = observed[t.strftime(weather_core.TS_FMT)]
                expected.append({**row, "rain_probability": float(row["precipitation"] >= 0.1)})
            else:
                v = _values(int((t - NOW).total_seconds() / 3600) + 1)
                expected.append({**v, "precipitation": v["precipitation_mm"]})
        assert day["date"] == date_start.date().isoformat()
        assert day["source"] == "ai"
        for key, field, aggregate, digits in (
            ("temperature_min", "temperature", min, 1),
            ("temperature_max", "temperature", max, 1),
            ("temperature_avg", "temperature", lambda v: sum(v) / len(v), 1),
            ("humidity_avg", "humidity", lambda v: sum(v) / len(v), 1),
            ("precipitation_total", "precipitation", sum, 2),
            ("wind_speed_max", "wind_speed", max, 1),
            ("cloud_cover_avg", "cloud_cover", lambda v: sum(v) / len(v), 1),
        ):
            assert day[key] == pytest.approx(round(aggregate([r[field] for r in expected]), digits)), key
        assert day["precipitation_median"] is None
        assert day['rain_day_probability'] == max(r["rain_probability"] for r in expected)
        assert day['confidence'] == 'low'  # synthetic artifact has no evaluation report
        assert day["uv_index_max"] is None
        assert day["us_aqi_max"] is None
        if d > 0:
            assert day["wind_gusts_max"] is None


def test_live_bundle_keeps_current_and_matches_forecast_routes(live):
    client, predictor = live
    bundle = _get(client, "bundle", hours=168, days=7)
    assert bundle["forecast_provider"] == "sky_weather_ai"
    assert bundle["forecast_error"] is None
    assert bundle["current"] == _get(client, "current")
    assert bundle["current"]["timestamp"] == NOW.isoformat()
    assert bundle["hourly"] == _get(client, "hourly", hours=168)
    assert bundle["daily"] == _get(client, "daily", days=7)
    predictor.assert_called_once()


def test_wal_reads_keep_forecast_cache_but_writes_refresh_it(live, syn_db):
    client, predictor = live
    with sqlite3.connect(syn_db) as con:
        assert con.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    con.close()
    bundle = _get(client, "bundle", hours=168, days=7)
    # A concurrent reader (auth/sync) keeps an empty -wal file alive; once it closes the file is gone again.
    reader = sqlite3.connect(syn_db)
    reader.execute("SELECT COUNT(*) FROM hourly_weather").fetchone()
    assert bundle["hourly"] == _get(client, "hourly", hours=168)
    reader.close()
    assert bundle["daily"] == _get(client, "daily", days=7)
    predictor.assert_called_once()   # reads alone, from any number of connections, keep the cache key
    # An ingest revising an existing hour (same issue time) must still refresh the forecast.
    con = sqlite3.connect(syn_db)
    with con:
        con.execute("UPDATE hourly_weather SET temperature = temperature + 1 WHERE timestamp = ?",
                    ((NOW - timedelta(hours=2)).strftime(weather_core.TS_FMT),))
    con.close()
    _get(client, "hourly", hours=168)
    assert predictor.call_count == 2


@pytest.mark.parametrize("error", ["untrained: no artifact", "unavailable: broken artifact"])
def test_unavailable_model_fails_closed_including_current_and_bundle(live, error):
    client, predictor = live
    predictor.side_effect = ValueError(error)
    failures = [client.get(f"/weather/{route}") for route in ("current", "hourly", "daily", "bundle")]
    for response in failures:
        assert response.status_code == 503
        assert error not in response.json()["detail"]   # logged server-side only
        assert response.json()["detail"].startswith("Dự báo AI riêng chưa sẵn sàng")


def test_stale_input_over_three_hours_rejected_even_with_model(live, syn_db):
    client, predictor = live
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp > ? AND timestamp <= ?",
                    ((NOW - timedelta(hours=4)).strftime(weather_core.TS_FMT), NOW.strftime(weather_core.TS_FMT)))
    for route in ("current", "hourly", "daily", "bundle"):
        response = client.get(f"/weather/{route}")
        assert response.status_code == 503
        assert response.json()["detail"]
    predictor.assert_not_called()


@pytest.mark.parametrize("field", ["humidity", "rain_probability", "precipitation_mm", "wind_speed", "cloud_cover"])
def test_unsupported_model_targets_remain_null(live, field):
    client, predictor = live
    def partial(history, cell_id):
        result = _predict(history, cell_id)
        for prediction in result["predictions"].values():
            prediction[field] = None
        return result
    predictor.side_effect = partial
    row = _get(client, "current")
    api_fields = {
        "precipitation_mm": ("precipitation", "rain"),
        "rain_probability": ("rain_probability", "precipitation_probability"),
    }.get(field, (field,))
    assert all(row[key] is None for key in api_fields)
    assert row["source"] == "ai"
    assert row["temperature"] == 0.0


def test_map_current_outlook_and_future_frame_are_own_ai(live):
    client, _ = live
    meta = _get(client, "map/meta")
    assert meta["forecast_source"] == "ai"
    assert meta["max_offset_hours"] == 72
    for offset in (0, 1, 72):
        cells = _get(client, "map", offset_hours=offset)
        populated = [c for c in cells if c["source"] is not None]
        assert len(populated) == 1
        row = populated[0]
        assert row["source"] == "ai"
        assert row["outlook_source"] == "ai"
        assert row["valid_time"] == (NOW + timedelta(hours=offset)).isoformat()
        assert row["rain_probability_next_3h"] == max(_values(offset + h + 1)["rain_probability"] for h in (1, 2, 3))
        assert row["precipitation_next_3h"] == pytest.approx(round(sum(_values(offset + h + 1)["precipitation_mm"] for h in (1, 2, 3)), 2))
        assert row["temperature"] == _values(offset + 1)["temperature"]
        assert row["observed_at"] is None
        assert row["wind_direction"] is None
        assert row["wind_gusts"] is None
        assert all(c["source"] in (None, "ai") for c in cells)


@pytest.mark.parametrize("hour", [0, 23])
def test_cross_midnight_hourly_and_daily_boundaries(live, monkeypatch, hour):
    client, _ = live
    now = NOW.replace(hour=hour)
    freeze_now(monkeypatch, now)
    rows = _get(client, "hourly", hours=168)
    assert len(rows) == 168
    assert rows[-1]["timestamp"] == (now + timedelta(hours=167)).isoformat()
    assert rows[-1]["source"] == "ai"
    midnight_index = 24 - hour
    assert rows[midnight_index]["timestamp"] == "2023-06-21T00:00:00+07:00"
    assert rows[midnight_index]["source"] == "ai"
    assert len(_get(client, "daily", days=7)) == 7
    assert client.get("/weather/hourly", params={"hours": 169}).status_code == 422


def test_exact_168h_model_horizon_is_included_not_extrapolated(live, syn_db):
    client, _ = live
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp = ?", (NOW.strftime(weather_core.TS_FMT),))
    rows = _get(client, "hourly", hours=168)
    assert len(rows) == 168
    assert all(row["source"] == "ai" for row in rows)
    assert rows[-1]["temperature"] == _values(168)["temperature"]
    assert rows[-1]["timestamp"] == (NOW + timedelta(hours=167)).isoformat()


def test_exact_three_hour_input_age_and_remaining_horizon(live, syn_db):
    client, _ = live
    issue = NOW - timedelta(hours=3)
    with sqlite3.connect(syn_db) as con:
        con.execute("DELETE FROM hourly_weather WHERE timestamp > ? AND timestamp <= ?",
                    (issue.strftime(weather_core.TS_FMT), NOW.strftime(weather_core.TS_FMT)))
    rows = _get(client, "hourly", hours=166)
    assert len(rows) == 166
    assert all(row["source"] == "ai" for row in rows)
    assert rows[0]["temperature"] == _values(3)["temperature"]
    assert rows[-1]["temperature"] == _values(168)["temperature"]
    assert rows[-1]["timestamp"] == (issue + timedelta(hours=168)).isoformat()
    assert client.get("/weather/hourly", params={"hours": 167}).status_code == 503


def test_daily_exact_horizon_boundary_and_beyond(live, monkeypatch):
    client, _ = live
    freeze_now(monkeypatch, NOW.replace(hour=23))
    days = _get(client, "daily", days=7)
    assert len(days) == 7
    assert days[-1]["date"] == "2023-06-26"
    assert days[-1]["source"] == "ai"
    assert client.get("/weather/daily", params={"days": 8}).status_code == 503


def test_missing_current_hour_is_consistent_for_one_and_two_hour_requests(live, syn_db):
    client, _ = live
    with sqlite3.connect(syn_db) as con:
        con.execute('DELETE FROM hourly_weather WHERE timestamp = ?', (NOW.strftime(weather_core.TS_FMT),))
    one = _get(client, 'hourly', hours=1)
    two = _get(client, 'hourly', hours=2)
    assert one[0] == two[0]
    assert one[0]['source'] == 'ai'
    assert one[0]['timestamp'] == NOW.isoformat()


def test_current_is_a_prediction_not_the_same_hour_reference(live, syn_db):
    client, predictor = live
    before = _get(client, 'current')
    assert before['source'] == 'ai'
    assert before['temperature'] == _values(1)['temperature']
    assert datetime.fromisoformat(before['issued_at']) < NOW
    history = predictor.call_args.args[0]
    assert str(history.timestamp.iloc[-1]) == '2023-06-20 11:00:00'
    with sqlite3.connect(syn_db) as con:
        con.execute('UPDATE hourly_weather SET temperature = 99, weather_code = 51, '
                    'precipitation = 50 WHERE timestamp >= ?', (NOW.strftime(weather_core.TS_FMT),))
    after = _get(client, 'current')
    assert after == before
    hourly = _get(client, 'hourly', hours=1)[0]
    for key in hourly:
        if key not in after['field_sources'] and key != 'field_sources':
            assert after[key] == hourly[key]
    assert hourly['field_sources'] == {}
    predictor.assert_called()
    assert str(predictor.call_args.args[0].timestamp.iloc[-1]) == '2023-06-20 11:00:00'


def test_current_hour_input_alone_cannot_be_used_to_predict_itself(live, syn_db):
    client, predictor = live
    with sqlite3.connect(syn_db) as con:
        con.execute('DELETE FROM hourly_weather WHERE timestamp < ? AND timestamp > ?',
                    (NOW.strftime(weather_core.TS_FMT),
                     (NOW - timedelta(hours=4)).strftime(weather_core.TS_FMT)))
    assert client.get('/weather/current').status_code == 503
    predictor.assert_not_called()


def test_current_reference_metrics_keep_ai_and_hourly_untouched(live, syn_db):
    client, _ = live
    hourly_before = _get(client, 'hourly', hours=2)
    with sqlite3.connect(syn_db) as con:
        con.execute('UPDATE hourly_weather SET apparent_temperature=37, visibility=25000, '
                    'pressure_msl=1008, uv_index=0 WHERE location_id=? AND timestamp=?',
                    ('tsn', NOW.strftime(weather_core.TS_FMT)))
        con.execute('INSERT INTO air_quality VALUES (?, ?, ?, ?, ?)',
                    ('tsn', NOW.strftime(weather_core.TS_FMT), 0, 0, 0))
    current = _get(client, 'current')
    assert current['source'] == 'ai'
    for key in ('temperature', 'humidity', 'precipitation', 'rain_probability', 'weather_code',
                'wind_speed', 'cloud_cover', 'issued_at', 'model_version'):
        assert current[key] == hourly_before[0][key]
        assert key not in current['field_sources']
    assert current['apparent_temperature'] == 37
    assert current['visibility'] == 25000
    assert current['pressure_msl'] == 1008
    assert current['uv_index'] == current['us_aqi'] == current['pm2_5'] == 0
    assert current['field_sources']['uv_index'] == {
        'source': 'open_meteo', 'timestamp': NOW.isoformat()}
    assert current['field_sources']['us_aqi'] == {
        'source': 'open_meteo_cams', 'timestamp': NOW.isoformat()}
    assert _get(client, 'hourly', hours=2) == hourly_before
    assert _get(client, 'bundle')['current'] == current


@pytest.mark.parametrize('age', [0, 1, 2])
def test_reference_metrics_only_use_recent_same_location_data(live, syn_db, age):
    client, _ = live
    target = (NOW - timedelta(hours=age)).strftime(weather_core.TS_FMT)
    with sqlite3.connect(syn_db) as con:
        con.execute('DELETE FROM hourly_weather WHERE location_id=? AND timestamp>?', ('tsn', target))
        con.execute('UPDATE hourly_weather SET uv_index=2 WHERE location_id=? AND timestamp=?', ('tsn', target))
        con.execute('INSERT INTO air_quality VALUES (?, ?, ?, ?, ?)', ('tsn', target, 42, 10, 15))
        # Future references and another cell must never supply the current metrics.
        con.execute('INSERT INTO air_quality VALUES (?, ?, ?, ?, ?)',
                    ('tsn', (NOW + timedelta(hours=1)).strftime(weather_core.TS_FMT), 999, 99, 99))
        con.execute('INSERT INTO air_quality VALUES (?, ?, ?, ?, ?)',
                    ('another-cell', NOW.strftime(weather_core.TS_FMT), 888, 88, 88))
    current = _get(client, 'current')
    if age <= 1:
        assert current['us_aqi'] == 42 and current['uv_index'] == 2
        assert current['field_sources']['us_aqi']['timestamp'] == (NOW - timedelta(hours=age)).isoformat()
    else:
        assert current['us_aqi'] is None and current['uv_index'] is None
        assert current['field_sources'] == {}


def test_missing_reference_values_stay_null_without_provenance(live, syn_db):
    client, _ = live
    with sqlite3.connect(syn_db) as con:
        con.execute('UPDATE hourly_weather SET apparent_temperature=NULL, visibility=NULL, '
                    'pressure_msl=NULL, surface_pressure=NULL, uv_index=NULL WHERE location_id=?', ('tsn',))
    current = _get(client, 'current')
    assert current['source'] == 'ai'
    assert all(current[k] is None for k in ('apparent_temperature', 'visibility', 'pressure_msl',
                                           'uv_index', 'us_aqi'))
    assert current['field_sources'] == {}


def test_wrong_model_issue_cannot_bypass_current_hour_input_cutoff(live):
    client, predictor = live
    def wrong_issue(history, cell_id):
        result = _predict(history, cell_id)
        result['issued_at'] = NOW.isoformat()
        return result
    predictor.side_effect = wrong_issue
    assert client.get('/weather/current').status_code == 503


def test_replay_map_does_not_bypass_training_cutoff(live, monkeypatch):
    client, predictor = live
    predictor.side_effect = ValueError('replay_leakage: issue is before trained_through')
    legacy = Mock(side_effect=AssertionError('unguarded legacy model must not answer replay'))
    monkeypatch.setattr(ai_model, 'predict_for_location', legacy)
    cells = _get(client, 'map', at=NOW.isoformat())
    row = next(c for c in cells if c['cell_id'] == CELL)
    assert row['rain_probability_next_3h'] is None
    assert row['outlook_source'] is None
    legacy.assert_not_called()
    assert datetime.fromisoformat(str(predictor.call_args.args[0].timestamp.iloc[-1])) == NOW.replace(tzinfo=None)


def test_partial_day_targets_are_not_presented_as_full_day_statistics(live):
    client, predictor = live
    def partial(history, cell_id):
        result = _predict(history, cell_id)
        for prediction in result['predictions'].values():
            prediction['precipitation_mm'] = None
            prediction['humidity'] = None
        return result
    predictor.side_effect = partial
    days = _get(client, 'daily', days=2)
    for day in days:
        assert day['precipitation_total'] is None
        assert day['humidity_avg'] is None
        assert day['rain_day_probability'] is not None  # rain_probability is still complete


def test_history_revision_at_same_issue_invalidates_prediction_cache(live, syn_db):
    client, predictor = live
    def based_on_input(history, cell_id):
        result = _predict(history, cell_id)
        result['predictions']['1h']['temperature'] = float(history.temperature.iloc[-1])
        return result
    predictor.side_effect = based_on_input
    before = _get(client, 'current')
    assert predictor.call_count == 1
    with sqlite3.connect(syn_db) as con:
        con.execute('UPDATE hourly_weather SET temperature = temperature + 1 WHERE timestamp = ?',
                    ((NOW - timedelta(hours=1)).strftime(weather_core.TS_FMT),))
    after = _get(client, 'current')
    assert predictor.call_count == 2
    assert after['timestamp'] == before['timestamp']
    assert after['temperature'] == before['temperature'] + 1


def test_unrelated_writes_keep_prediction_cache(live, syn_db, monkeypatch):
    from routers import auth, monitor
    client, predictor = live
    assert weather_data_revision(syn_db)[0] == 'rows'   # counter, not the file-stat fallback
    before = _get(client, 'hourly', hours=2)
    assert predictor.call_count == 1
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    assert client.post('/feedback', json={'kind': 'suggestion', 'message': 'ok'}).status_code == 201
    monitor.record_api_call('osrm')
    monitor.record_api_call('osrm', ok=False)
    account = {'email': 'cache@example.com', 'password': 'correct horse battery'}
    assert client.post('/auth/register', json=account).status_code == 201
    assert client.post('/auth/login', json=account).status_code == 200
    assert _get(client, 'hourly', hours=2) == before
    assert predictor.call_count == 1


def test_old_hour_revision_and_ingest_invalidate_prediction_cache(live, syn_db):
    import ingest
    client, predictor = live
    old = (NOW - timedelta(hours=5)).replace(tzinfo=None)
    def based_on_old_hour(history, cell_id):
        result = _predict(history, cell_id)
        row = history[history.timestamp == old.strftime(weather_core.TS_FMT)]
        result['predictions']['1h']['temperature'] = float(row.temperature.iloc[0])
        return result
    predictor.side_effect = based_on_old_hour
    first = _get(client, 'current')['temperature']
    with sqlite3.connect(syn_db) as con:   # a past hour revised in place (same rowid, same issue time)
        con.execute('UPDATE hourly_weather SET temperature = temperature + 1 WHERE timestamp = ?',
                    (old.strftime(weather_core.TS_FMT),))
    second = _get(client, 'current')['temperature']
    assert predictor.call_count == 2 and second == first + 1
    with sqlite3.connect(syn_db) as con:   # the ingest upsert path (ON CONFLICT DO UPDATE)
        con.row_factory = sqlite3.Row
        row = dict(con.execute('SELECT * FROM hourly_weather WHERE timestamp = ?',
                               (old.strftime(weather_core.TS_FMT),)).fetchone())
        row['temperature'] += 1
        assert ingest.upsert_hourly(con, row['location_id'], [row]) == (0, 1)
    third = _get(client, 'current')['temperature']
    assert predictor.call_count == 3 and third == first + 2
