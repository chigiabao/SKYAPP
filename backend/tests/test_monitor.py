"""Forecast log hooked into ingest, retention, GET /admin/monitor and retrain / rollback (subprocess mocked)."""
import json
import sqlite3
import threading
from datetime import datetime, timedelta
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

import ai_model
import database
import ingest
import main
from conftest import synthetic_rows, write_db
from database import LOCAL_TZ
from routers import monitor
from test_ingest import NOW, NOW_HOUR, FakeAPI

ADMIN = {"X-Admin-Token": "test-admin-token-0123456789abcdef"}
MON_NOW = datetime(2023, 6, 25, 0, 30, tzinfo=LOCAL_TZ)   # synthetic observations end 2023-06-24 23:00


def _q(db, sql, params=()):
    with sqlite3.connect(db) as con:
        rows = con.execute(sql, params).fetchall()
    con.close()
    return rows


def _exec(db, sql, rows):
    with sqlite3.connect(db) as con:
        con.executemany(sql, rows)
    con.close()


@pytest.fixture
def ingest_db(tmp_path, monkeypatch):
    monkeypatch.setattr(ingest, "_get_json", FakeAPI())
    monkeypatch.setenv("LONG_RANGE_MODEL_DIR", str(tmp_path / "absent-model"))
    monkeypatch.setenv("LONG_RANGE_V2_MODEL_DIR", str(tmp_path / "absent-model"))
    monitor._retention_day.clear()
    return write_db(tmp_path / "w.db", synthetic_rows(), locations=False)


def test_ingest_logs_published_forecasts_once(ingest_db):
    assert ingest.run_ingest(db_path=ingest_db, now=NOW)["status"] == "ok"
    ai = _q(ingest_db, "SELECT horizon_h, issued_at, target_time, temperature, rain_probability FROM ai_forecast_log "
                       "WHERE source = 'ai' ORDER BY horizon_h")
    assert [(r[0], r[1]) for r in ai] == [(1, NOW_HOUR), (3, NOW_HOUR), (6, NOW_HOUR)]
    assert ai[2][2] == "2023-06-25 16:00:00"
    # the batched prediction equals what /weather/ai-forecast would publish
    ref = ai_model.predict_for_location(ai_model.load_history_from_db(str(ingest_db), location_id="tsn"), "tsn")
    for h, _, _, temp, prob in ai:
        assert temp == ref["predictions"][f"{h}h"]["temperature"]
        assert prob == ref["predictions"][f"{h}h"]["rain_probability"]
    metadata = ai_model._v3.get("meta", {}) if ref["model_version"] == ai_model._v3.get("meta", {}).get("model_version") else ai_model._meta
    assert dict(_q(ingest_db, "SELECT horizon_h, rain_threshold FROM ai_forecast_log WHERE source = 'ai'")) == (
        monitor._rain_thresholds(metadata, ref["model_version"]))
    alert = _q(ingest_db, "SELECT issued_at, horizon_h, alert, precipitation FROM ai_forecast_log "
                          "WHERE source = 'map_alert'")
    assert alert == []   # no own-model artifact: external forecasts are not published
    assert _q(ingest_db, "SELECT * FROM ai_forecast_log WHERE source = 'ai_long_range'") == []
    n = _q(ingest_db, "SELECT COUNT(*) FROM ai_forecast_log")[0][0]
    ingest.run_ingest(db_path=ingest_db, now=NOW)   # same hour again: first publication kept, no duplicates
    assert _q(ingest_db, "SELECT COUNT(*) FROM ai_forecast_log")[0][0] == n


@pytest.fixture
def map_log_db(tmp_path, monkeypatch):
    path = write_db(tmp_path / "map.db", synthetic_rows()[-72:], locations=False)
    ingest.connect(path).close()   # migrate, without ingest or network
    _exec(path, "INSERT INTO nwp_forecast (location_id, issued_at, timestamp, precipitation, "
                "precipitation_probability, weather_code) VALUES ('tsn', ?, ?, 20, 99, 95)",
          [("2023-06-24 23:00:00", "2023-06-25 00:00:00")])
    monkeypatch.setattr(monitor, "_predict_all", lambda items: {})
    return path


def _own_result(issued):
    return {"issued_at": issued.replace(tzinfo=LOCAL_TZ).isoformat(), "model_version": "own-test",
            "predictions": {f"{h}h": {"temperature": 30.0, "precipitation_mm": 0.0, "rain_probability": 0.0}
                            for h in range(1, 169)}}


@pytest.mark.parametrize("amounts,probs,total,prob,alert", [
    ([2.0, 3.0, 5.0], [0.2, 0.876, 0.4], 10.0, 0.88, 1),
    ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], 0.0, 0.0, 0),
])
@pytest.mark.parametrize("age", [timedelta(minutes=30), timedelta(hours=3)])
def test_map_alert_logs_own_model(map_log_db, monkeypatch, amounts, probs, total, prob, alert, age):
    issued = datetime(2023, 6, 24, 20)
    now = issued.replace(tzinfo=LOCAL_TZ) + age
    _exec(map_log_db, "DELETE FROM hourly_weather WHERE timestamp > ? AND timestamp <= ?",
          [(issued.strftime(monitor.TS_FMT), monitor._naive_now(now).strftime(monitor.TS_FMT))])
    result = _own_result(issued)
    offset = int(age.total_seconds() // 3600)
    for h in (1, 2, 3):
        result["predictions"][f"{offset + h}h"].update(
            precipitation_mm=amounts[h - 1], rain_probability=probs[h - 1])
    result["predictions"][f"{offset + 4}h"].update(precipitation_mm=100, rain_probability=1)
    predict = Mock(return_value=result)
    load = Mock(wraps=ai_model.load_history_from_db)
    monkeypatch.setattr(monitor.long_range_model, "predict", predict)
    monkeypatch.setattr(monitor.ai_model, "load_history_from_db", load)
    assert monitor.log_published_forecasts(map_log_db, now) == 12
    predict.assert_called_once()
    load.assert_called_once_with(db_path=str(map_log_db), location_id="tsn", until=monitor._naive_now(now))
    history, cid = predict.call_args.args
    assert cid == ai_model.canonical_cell_id("tsn")
    assert history.timestamp.max() == issued.strftime(monitor.TS_FMT)
    assert _q(map_log_db, "SELECT series_id, source, issued_at, horizon_h, target_time, rain_probability, "
                        "precipitation, alert, model_version FROM ai_forecast_log WHERE source = 'map_alert'") == [
        ("tsn", "map_alert", monitor._naive_now(now).replace(minute=0).strftime(monitor.TS_FMT), 3,
         (monitor._naive_now(now).replace(minute=0) + timedelta(hours=3)).strftime(monitor.TS_FMT),
         prob, total, alert, "own-test")]
    logged = _q(map_log_db, "SELECT horizon_h, issued_at, target_time, temperature, rain_probability, "
                           "precipitation, model_version FROM ai_forecast_log WHERE source = 'ai_long_range' "
                           "ORDER BY horizon_h")
    assert [r[0] for r in logged] == list(monitor.LONG_RANGE_HORIZONS)
    for h, issue, target, temp, rain_prob, precip, version in logged:
        assert issue == issued.strftime(monitor.TS_FMT)
        assert target == (issued + timedelta(hours=h)).strftime(monitor.TS_FMT)
        assert (temp, rain_prob, precip, version) == (
            30.0, result["predictions"][f"{h}h"]["rain_probability"],
            result["predictions"][f"{h}h"]["precipitation_mm"], "own-test")
    assert monitor.log_published_forecasts(map_log_db, now) == 0


@pytest.mark.parametrize("missing", ["one", "all", "record"])
def test_map_alert_missing_precipitation_is_not_a_quiet_sample(map_log_db, monkeypatch, missing):
    result = _own_result(datetime(2023, 6, 24, 23))
    for h in ((1, 2, 3) if missing == "all" else (2,)):
        if missing == "record":
            del result["predictions"][f"{h}h"]
        else:
            result["predictions"][f"{h}h"]["precipitation_mm"] = None
    monkeypatch.setattr(monitor.long_range_model, "predict", Mock(return_value=result))
    assert monitor.log_published_forecasts(map_log_db, MON_NOW) == 11
    assert _q(map_log_db, "SELECT * FROM ai_forecast_log WHERE source = 'map_alert'") == []
    with monitor._connect(map_log_db) as conn:
        assert monitor._alert_quality(conn, "2023-06-01")["total"]["evaluated"] == 0


@pytest.mark.parametrize("delay", [1, 2, 3])
def test_delayed_map_alert_scores_now_window_not_issue_window(map_log_db, monkeypatch, delay):
    issued = datetime(2023, 6, 24, 20)
    now = issued.replace(tzinfo=LOCAL_TZ) + timedelta(hours=delay)
    _exec(map_log_db, "DELETE FROM hourly_weather WHERE timestamp > ?", [(issued.strftime(monitor.TS_FMT),)])
    result = _own_result(issued)
    for h in (1, 2, 3):
        result["predictions"][f"{h}h"]["precipitation_mm"] = 20
    for h in range(delay + 1, delay + 4):
        result["predictions"][f"{h}h"]["precipitation_mm"] = 1
    monkeypatch.setattr(monitor.long_range_model, "predict", Mock(return_value=result))
    assert monitor.log_published_forecasts(map_log_db, now) == 12
    assert _q(map_log_db, "SELECT issued_at, target_time, precipitation, alert FROM ai_forecast_log "
                        "WHERE source = 'map_alert'") == [
        (monitor._naive_now(now).strftime(monitor.TS_FMT),
         (monitor._naive_now(now) + timedelta(hours=3)).strftime(monitor.TS_FMT), 3.0, 0)]
    _exec(map_log_db, "INSERT INTO hourly_weather (location_id, timestamp, precipitation, weather_code) "
                    "VALUES ('tsn', ?, ?, 95)",
          [((issued + timedelta(hours=h)).strftime(monitor.TS_FMT), 20 if h <= delay else 1)
           for h in range(1, delay + 4)])
    with monitor._connect(map_log_db) as conn:
        quality = monitor._alert_quality(conn, "2023-06-01")
    assert quality["total"] == {"evaluated": 1, "predicted": 0, "observed": 0, "false_alarms": 0, "missed": 0}
    assert "rainfall only" in quality["rule"]   # lightning truth is unsupported by this model
    _exec(map_log_db, "UPDATE hourly_weather SET precipitation = NULL WHERE timestamp = ?",
          [((monitor._naive_now(now) + timedelta(hours=2)).strftime(monitor.TS_FMT),)])
    with monitor._connect(map_log_db) as conn:
        assert monitor._alert_quality(conn, "2023-06-01")["total"]["evaluated"] == 0


@pytest.mark.parametrize("error", [ValueError("untrained: missing metadata.json"),
                                  ValueError("unsupported_cell: unknown"), OSError("broken artifact")])
def test_map_alert_unavailable_has_no_external_fallback(map_log_db, monkeypatch, error):
    predict = Mock(side_effect=error)
    monkeypatch.setattr(monitor.long_range_model, "predict", predict)
    assert monitor.log_published_forecasts(map_log_db, MON_NOW) == 0
    predict.assert_called_once()
    assert _q(map_log_db, "SELECT * FROM ai_forecast_log") == []


@pytest.mark.parametrize("history_kind", ["stale", "empty", "future-only"])
def test_map_alert_without_fresh_history_has_no_external_fallback(map_log_db, monkeypatch, history_kind):
    if history_kind == "stale":
        now = datetime(2023, 6, 25, 2, 0, 1, tzinfo=LOCAL_TZ)
    else:
        sql = ("DELETE FROM hourly_weather" if history_kind == "empty" else
               "UPDATE hourly_weather SET timestamp = datetime(timestamp, '+4 days')")
        _exec(map_log_db, sql, [()])
        now = MON_NOW
    predict = Mock()
    monkeypatch.setattr(monitor.long_range_model, "predict", predict)
    assert monitor.log_published_forecasts(map_log_db, now) == 0
    predict.assert_not_called()
    assert _q(map_log_db, "SELECT * FROM ai_forecast_log") == []


def test_post_ingest_failure_never_fails_ingest(ingest_db, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("monitor down")
    monkeypatch.setattr(monitor, "post_ingest", boom)
    assert ingest.run_ingest(db_path=ingest_db, now=NOW)["status"] == "ok"


def test_retention_deletes_old_rows_once_per_day(ingest_db, monkeypatch):
    monkeypatch.setenv("MAINTENANCE_ENABLED", "1")
    ingest.connect(ingest_db).close()   # migrate
    _exec(ingest_db, "INSERT INTO feedback (created_at, kind) VALUES (?, 'bug')",
          [("2022-06-24 00:00:00",), ("2022-06-26 00:00:00",)])
    _exec(ingest_db, "INSERT INTO ai_forecast_log (series_id, source, issued_at, horizon_h, target_time, logged_at) "
                     "VALUES ('tsn', 'ai', ?, 1, ?, ?)",
          [("2023-03-26 00:00:00",) * 3, ("2023-03-28 00:00:00",) * 3])
    assert monitor.run_retention(ingest_db, NOW) == {"feedback_deleted": 1, "forecast_log_deleted": 1}
    assert _q(ingest_db, "SELECT created_at FROM feedback") == [("2022-06-26 00:00:00",)]
    calls = []
    monkeypatch.setattr(monitor, "run_retention", lambda db, now: calls.append(now) or {})
    monkeypatch.setattr(monitor, "log_published_forecasts", lambda db, now: 0)
    monitor.post_ingest(ingest_db, NOW)
    monitor.post_ingest(ingest_db, NOW.replace(hour=11))
    monitor.post_ingest(ingest_db, NOW.replace(day=26))
    assert len(calls) == 2


@pytest.mark.parametrize("ingest_enabled", ["0", "1"])
def test_post_ingest_respects_explicit_maintenance_disable(monkeypatch, ingest_enabled):
    monkeypatch.setenv("INGEST_ENABLED", ingest_enabled)
    monkeypatch.setenv("MAINTENANCE_ENABLED", "0")
    monkeypatch.setattr(monitor, "log_published_forecasts", lambda *args: 7)
    retention = Mock()
    monkeypatch.setattr(monitor, "maybe_run_retention", retention)
    assert monitor.post_ingest("unused.db", NOW) == {"logged": 7}
    retention.assert_not_called()


@pytest.fixture
def admin(syn_db, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", "test-admin-token-0123456789abcdef")
    monkeypatch.setattr(monitor, "now_local", lambda: MON_NOW)
    return TestClient(main.app)


def test_monitor_scores_published_forecasts(admin, syn_db, monkeypatch):
    obs = dict(_q(syn_db, "SELECT timestamp, temperature FROM hourly_weather WHERE location_id = 'tsn' "
                          "AND timestamp BETWEEN '2023-06-20 00:00:00' AND '2023-06-24 23:00:00'"))
    precip = dict(_q(syn_db, "SELECT timestamp, precipitation FROM hourly_weather WHERE location_id = 'tsn'"))
    rows = []
    for issued in ("2023-06-20 12:00:00", "2023-06-21 12:00:00", "2023-06-10 12:00:00"):   # last one: > 7 days ago
        for h in (1, 3, 6):
            t = datetime.fromisoformat(issued).replace(hour=12 + h).strftime("%Y-%m-%d %H:%M:%S")
            rows.append(("tsn", "ai", issued, h, t, (obs.get(t) or 0) + 1.0, 0.9, None, None, "v3", issued))
    rows += [  # map alerts: one false alarm, one hit-free quiet window, one missed storm
        ("tsn", "map_alert", "2023-06-22 01:00:00", 3, "2023-06-22 04:00:00", None, 0.9, 12.0, 1, "nwp", "x"),
        ("tsn", "map_alert", "2023-06-22 02:00:00", 3, "2023-06-22 05:00:00", None, 0.1, 0.0, 0, "nwp", "x"),
        ("tsn", "map_alert", "2023-06-23 05:00:00", 3, "2023-06-23 08:00:00", None, 0.1, 0.0, 0, "nwp", "x"),
        ("tsn", "map_alert", "2023-06-24 22:00:00", 3, "2023-06-25 01:00:00", None, 0.1, 0.0, 0, "nwp", "x"),  # not observed yet
    ]
    _exec(syn_db, "INSERT INTO ai_forecast_log (series_id, source, issued_at, horizon_h, target_time, temperature, "
                  "rain_probability, precipitation, alert, model_version, logged_at, rain_threshold) "
                  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [r + (0.5 if r[1] == "ai" else None,) for r in rows])
    _exec(syn_db, "UPDATE hourly_weather SET weather_code = 95 WHERE location_id = 'tsn' AND timestamp = ?",
          [("2023-06-23 07:00:00",)])
    _exec(syn_db, "INSERT INTO ingest_log (started_at, status, api_calls, cells_failed, message) VALUES (?, ?, ?, ?, ?)",
          [("2023-06-24 10:05:00", "ok", 8, 0, "fine"), ("2023-06-24 11:05:00", "error", 3, 0, "boom")])
    _exec(syn_db, "INSERT INTO api_call_log (day, service, calls, errors) VALUES (?, 'osrm', ?, ?)",
          [("2023-06-24", 5, 1)])
    _exec(syn_db, "INSERT INTO feedback (created_at, kind, message) VALUES (?, ?, ?)",
          [("2023-06-24 09:00:00", "bug", "lỗi"), ("2023-01-01 00:00:00", "bug", "cũ")])

    assert admin.get("/admin/monitor").status_code == 401
    m = admin.get("/admin/monitor", headers=ADMIN).json()
    q = m["ai_quality"]
    assert q["overall"]["n"] == 6 and q["overall"]["temperature_mae"] == 1.0
    targets = [r[4] for r in rows[:6]]
    tp = sum(precip[t] >= 0.1 for t in targets)
    assert q["overall"]["rain_f1"] == round(2 * tp / (2 * tp + (6 - tp)), 3)
    assert [d["day"] for d in q["by_day"]] == ["2023-06-20", "2023-06-21"]
    assert q["by_horizon"]["6h"]["n"] == 2
    assert m["alerts"]["total"]["evaluated"] == 0   # historical NWP rules are not own-model samples
    a = m["legacy_alerts"]["total"]
    assert a == {"evaluated": 3, "predicted": 1, "observed": 1, "false_alarms": 1, "missed": 1}
    assert m["ingest"]["by_day"] == [{"day": "2023-06-24", "runs": 2, "errors": 1, "partial": 0, "api_calls": 11,
                                      "cells_failed": 0}]
    assert m["ingest"]["recent_errors"][0]["message"] == "boom"
    assert m["api_calls"] == [{"day": "2023-06-24", "open_meteo": 11, "osrm": 5, "osrm_errors": 1}]
    assert m["feedback"]["total"] == 1 and m["feedback"]["latest"][0]["verified"] is False


@pytest.mark.parametrize('amount', [0.0, 0.099, 0.1, 0.101, 0.2])
def test_long_range_rain_event_matches_training_without_changing_legacy(monkeypatch, amount):
    # The direct-horizon artifact targets >0.1 mm; legacy monitoring uses >=0.1 mm.
    own_event = amount > monitor.long_range_model.RAIN_THRESHOLD_MM
    probability = 1.0 if own_event else 0.0
    with sqlite3.connect(':memory:') as conn:
        conn.row_factory = sqlite3.Row
        conn.execute('CREATE TABLE hourly_weather (location_id TEXT, timestamp TEXT, '
                     'temperature REAL, precipitation REAL)')
        conn.execute('CREATE TABLE ai_forecast_log (series_id TEXT, source TEXT, issued_at TEXT, '
                     'horizon_h INTEGER, target_time TEXT, temperature REAL, rain_probability REAL, '
                     'model_version TEXT, rain_threshold REAL)')
        conn.executemany('INSERT INTO hourly_weather VALUES (?, ?, 30, ?)', [
            ('tsn', '2023-06-24 12:00:00', amount), ('tsn', '2023-06-24 13:00:00', 1.0)])
        for source in ('ai', 'ai_long_range'):
            conn.executemany('INSERT INTO ai_forecast_log (series_id, source, issued_at, horizon_h, target_time, '
                             'temperature, rain_probability, model_version, rain_threshold) '
                             'VALUES (?, ?, ?, 1, ?, 30, ?, ?, 0.5)', [
                ('tsn', source, '2023-06-24 11:00:00', '2023-06-24 12:00:00', probability, 'test'),
                ('tsn', source, '2023-06-24 12:00:00', '2023-06-24 13:00:00', 1.0, 'test')])
        own = monitor._ai_quality(conn, '2023-06-01', source='ai_long_range')
        legacy = monitor._ai_quality(conn, '2023-06-01')
    for scores in (own['overall'], own['by_horizon']['1h'], own['by_day'][0],
                   own['by_model_version']['test']):
        assert scores['rain_f1'] == 1.0
        assert scores['temperature_mae'] == 0.0
    assert legacy['overall']['rain_f1'] == (0.667 if amount == 0.1 else 1.0)


def test_own_long_range_quality_is_separate_with_actual_horizons_and_versions(admin, syn_db, monkeypatch):
    target = datetime(2023, 6, 24, 12)
    _exec(syn_db, "UPDATE hourly_weather SET temperature = 30, precipitation = 1 WHERE timestamp = ?",
          [(target.strftime(monitor.TS_FMT),)])
    rows = []
    for i, h in enumerate(monitor.LONG_RANGE_HORIZONS):
        issue = (target - timedelta(hours=h)).strftime(monitor.TS_FMT)
        rows.append(("tsn", "ai_long_range", issue, h, target.strftime(monitor.TS_FMT), 32, 0.6,
                     1, None, "own-v1" if i < 5 else "own-v2", issue))
    rows.append(("tsn", "ai", "2023-06-24 11:00:00", 1, target.strftime(monitor.TS_FMT),
                 31, 0.6, None, None, "legacy-v3", "x"))
    _exec(syn_db, "INSERT INTO ai_forecast_log (series_id, source, issued_at, horizon_h, target_time, temperature, "
                  "rain_probability, precipitation, alert, model_version, logged_at, rain_threshold) "
                  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [r + (0.9 if r[1] == "ai" else None,) for r in rows])
    response = admin.get("/admin/monitor", headers=ADMIN, params={"days": 14})
    assert response.status_code == 200
    data = response.json()
    own = data["own_long_range_quality"]
    assert own["source"] == "ai_long_range"
    assert own["overall"] == {"n": 11, "temperature_mae": 2.0, "rain_f1": 1.0,
                              "rain_n": 11, "rain_threshold_missing": 0}
    assert set(own["by_horizon"]) == {f"{h}h" for h in monitor.LONG_RANGE_HORIZONS}
    assert all(v == {"n": 1, "temperature_mae": 2.0, "rain_f1": 1.0,
                     "rain_n": 1, "rain_threshold_missing": 0} for v in own["by_horizon"].values())
    assert set(own["rain_thresholds"].values()) == {0.5}
    assert own["by_model_version"] == {
        "own-v1": {"n": 5, "temperature_mae": 2.0, "rain_f1": 1.0, "rain_n": 5, "rain_threshold_missing": 0},
        "own-v2": {"n": 6, "temperature_mae": 2.0, "rain_f1": 1.0, "rain_n": 6, "rain_threshold_missing": 0}}
    legacy = data["ai_quality"]
    assert legacy["overall"] == {"n": 1, "temperature_mae": 1.0, "rain_f1": 0.0,
                                 "rain_n": 1, "rain_threshold_missing": 0}
    assert set(legacy["by_horizon"]) == {"1h", "3h", "6h"}
    assert legacy["rain_thresholds"] == {"1h": 0.9, "3h": None, "6h": None}


def test_logged_threshold_survives_model_change_and_duplicate_publication(ingest_db, monkeypatch):
    with monitor._connect(ingest_db) as con:
        database.migrate(con)
    meta = {"model_version": "issue-v1", "rain_decision_threshold": {f"{h}h": 0.3 for h in (1, 3, 6)}}
    monkeypatch.setattr(ai_model, "_meta", meta)
    monkeypatch.setattr(ai_model, "_load_v3", lambda: False)
    monkeypatch.setattr(ai_model, "predict_for_location", lambda *_: {
        "issued_at": "2023-06-24T12:00:00", "model_version": ai_model._meta["model_version"],
        "predictions": {f"{h}h": {"temperature": 30.0, "rain_probability": 0.6} for h in (1, 3, 6)}})
    monkeypatch.setattr(monitor.long_range_model, "predict", Mock(side_effect=ValueError("unavailable")))
    _exec(ingest_db, "UPDATE hourly_weather SET temperature = 30, precipitation = 1 WHERE timestamp = ?",
          [(f"2023-06-24 {h:02}:00:00",) for h in (13, 15, 18)])
    assert monitor.log_published_forecasts(ingest_db, MON_NOW) == 3
    with monitor._connect(ingest_db) as con:
        before = monitor._ai_quality(con, "2023-06-01")
    assert before["overall"]["rain_f1"] == 1.0 and before["overall"]["rain_n"] == 3
    monkeypatch.setattr(ai_model, "_meta", {"model_version": "replacement-v2", "rain_decision_threshold": {
        f"{h}h": 0.9 for h in (1, 3, 6)}})
    assert monitor.log_published_forecasts(ingest_db, MON_NOW) == 0
    with monitor._connect(ingest_db) as con:
        assert monitor._ai_quality(con, "2023-06-01") == before
    assert _q(ingest_db, "SELECT DISTINCT model_version, rain_threshold FROM ai_forecast_log") == [("issue-v1", 0.3)]


def test_archive_migration_preserves_unknown_legacy_thresholds(tmp_path):
    path = tmp_path / "legacy-archive.db"
    with monitor._connect(path) as con:
        con.execute("CREATE TABLE hourly_weather (timestamp TEXT, temperature REAL, precipitation REAL, location_id TEXT)")
        con.execute("INSERT INTO hourly_weather VALUES ('2023-06-24 13:00:00', 30, 1, 'tsn')")
        con.execute("CREATE TABLE ai_forecast_log (series_id TEXT, source TEXT, issued_at TEXT, horizon_h INTEGER, "
                    "target_time TEXT, temperature REAL, rain_probability REAL, precipitation REAL, alert INTEGER, "
                    "model_version TEXT, logged_at TEXT)")
        con.executemany("INSERT INTO ai_forecast_log (series_id, source, issued_at, horizon_h, target_time, temperature, "
                        "rain_probability, model_version, logged_at) VALUES ('tsn', ?, '2023-06-24 12:00:00', 1, "
                        "'2023-06-24 13:00:00', 31, 0.6, 'legacy', 'x')", [("ai",), ("ai_long_range",)])
        legacy = monitor._ai_quality(con, "2023-06-01")
        assert legacy["overall"] == {"n": 1, "temperature_mae": 1.0, "rain_f1": None,
                                      "rain_n": 0, "rain_threshold_missing": 1}
        assert legacy["legacy_missing_threshold"] == "excluded_from_rain_f1"
        assert monitor._ai_quality(con, "2023-06-01", "ai_long_range")["overall"]["rain_f1"] == 1.0
        database.migrate(con)
        database.migrate(con)
        assert [r[0] for r in con.execute("SELECT rain_threshold FROM ai_forecast_log")] == [None, None]
        assert monitor._ai_quality(con, "2023-06-01") == legacy


def test_threshold_capture_requires_matching_model_provenance():
    meta = {"model_version": "m1", "rain_decision_threshold": {"1h": 0.3, "3h": float("inf"), "6h": None}}
    assert monitor._rain_thresholds(meta, "m1") == {1: 0.3}
    assert monitor._rain_thresholds(meta, "m2") == {}


def test_mixed_archived_thresholds_are_scored_per_forecast():
    rows = [{"temperature": 30, "obs_t": 30, "rain_probability": 0.6, "obs_p": 1, "rain_threshold": threshold}
            for threshold in (0.3, 0.9, None)]
    assert monitor._scores(rows) == {"n": 3, "temperature_mae": 0.0, "rain_f1": 0.667,
                                     "rain_n": 2, "rain_threshold_missing": 1}


# --- retrain / rollback ---------------------------------------------------------------------------------

def _write_model(d, mae, f1, version):
    d.mkdir(parents=True, exist_ok=True)
    for f in monitor.V3_REQUIRED:
        (d / f).write_text("{}", encoding="utf-8")
    ev = {c: {"temperature_mae_1h": mae, "temperature_mae_3h": mae, "temperature_mae_6h": mae, "rain_f1_1h": f1,
              "rain_f1_3h": f1, "rain_f1_6h": f1, "test_kind": "test"} for c in ("om-a", "om-b")}
    ev["tsn"] = dict(ev["om-a"], temperature_mae_1h=99)   # alias: ignored
    (d / "evaluation_v3.json").write_text(json.dumps(ev), encoding="utf-8")
    (d / "metadata_v3.json").write_text(json.dumps({"model_version": version}), encoding="utf-8")


def _write_selection(d, cand, cur=(0.5, 0.5), cur_version="current", beats=True, split="val_select"):
    """selection_v3.json as written by train_global_v3.py --compare-with: val_select scores of both models."""
    score = lambda mf: None if mf is None else {"temperature_mae": mf[0], "rain_f1": mf[1], "beats_baselines": beats,
        "rain_brier": 0.1, "baseline_persistence_mae": 0.8, "baseline_climatology_mae": 0.9,
        "baseline_persistence_f1": 0.2, "baseline_climatology_f1": 0.3, "baseline_climatology_brier": 0.2,
        "cells": 2, "rows": 100, "evaluation_rows_sha256": "0" * 64}
    sel = {"split": split, "window": ["2024-10-01 00:00:00", "2025-09-23 23:00:00"],
           "comparison_policy": "rain_calibration_only",
           "candidate": score(cand), "current": score(cur), "current_model_version": cur_version,
           "current_error": None if cur else "no served model to compare with"}
    (d / "selection_v3.json").write_text(json.dumps(sel), encoding="utf-8")


class FakePopen:
    """Stands in for the training subprocess: writes the candidate model when it 'finishes'."""
    result = (0.4, 0.6, "cand-1")   # TEST mae, f1, version; None = write nothing
    selection = {"cand": (0.4, 0.6)}   # kwargs of _write_selection (VALIDATION scores); None = no file
    returncode = 0
    ext_returncode = 0              # train_global_v3_ext.py
    gate = None                     # threading.Event to hold the job in 'running'
    calls = []

    def __init__(self, cmd, **kw):
        FakePopen.calls.append(cmd)
        self.out = monitor.Path(cmd[cmd.index("--out") + 1])

    def wait(self):
        if FakePopen.gate is not None:
            FakePopen.gate.wait(5)
        if FakePopen.calls and FakePopen.calls[-1][1].endswith("train_global_v3_ext.py"):
            ev_path = self.out / "evaluation_v3.json"   # ext merges new keys into the candidate's file
            if ev_path.exists():
                ev = json.loads(ev_path.read_text(encoding="utf-8"))
                ev["_ext"] = {"wind_speed": {"enabled": True}}
                ev_path.write_text(json.dumps(ev), encoding="utf-8")
            return FakePopen.ext_returncode
        if FakePopen.calls and FakePopen.calls[-1][1].endswith("train_global_v3_interval.py"):
            ev_path = self.out / "evaluation_v3.json"   # interval refit adds its keys to the same file
            if ev_path.exists():
                ev = json.loads(ev_path.read_text(encoding="utf-8"))
                ev["_interval"] = {"level": 0.9}
                ev_path.write_text(json.dumps(ev), encoding="utf-8")
            return FakePopen.interval_returncode
        if FakePopen.result is not None:
            _write_model(self.out, *FakePopen.result)
            if FakePopen.selection is not None:
                _write_selection(self.out, **FakePopen.selection)
        return FakePopen.returncode


@pytest.fixture
def models(tmp_path, monkeypatch):
    d = tmp_path / "models"
    _write_model(d / "v3", 0.5, 0.5, "current")
    monkeypatch.setattr(monitor, "MODELS_DIR", d)
    monkeypatch.setattr(monitor.subprocess, "Popen", FakePopen)
    reloads = []
    monkeypatch.setattr(monitor.ai_model, "reset_v3_cache", lambda: reloads.append(1))
    FakePopen.result, FakePopen.returncode, FakePopen.gate, FakePopen.calls = (0.4, 0.6, "cand-1"), 0, None, []
    FakePopen.selection = {"cand": (0.4, 0.6)}
    FakePopen.ext_returncode = 0
    FakePopen.interval_returncode = 0
    monitor._jobs.clear()
    yield d, reloads
    monitor._jobs.clear()


def _run_job(admin, **params):
    r = admin.post("/admin/retrain", headers=ADMIN, params=params)
    assert r.status_code == 202, r.text
    job = r.json()
    monitor._jobs[job["job_id"]]["_thread"].join(5)
    return admin.get(f"/admin/retrain/{job['job_id']}", headers=ADMIN).json()


def _version(d):
    return json.loads((d / "metadata_v3.json").read_text())["model_version"]


def test_retrain_promotes_better_candidate_and_rollback(admin, models):
    d, reloads = models
    job = _run_job(admin, quick=True)
    assert job["status"] == "promoted" and job["returncode"] == 0
    cmd = FakePopen.calls[0]
    assert cmd[1].endswith("train_global_v3.py") and cmd[cmd.index("--out") + 1] == str(d / "v3_candidate")
    assert "--quick" in cmd and cmd[cmd.index("--compare-with") + 1] == str(d / "v3")   # same val rows
    ext = FakePopen.calls[1]   # then the extension script on the SAME candidate dir (no --quick)
    assert len(FakePopen.calls) == 3 and ext[1].endswith("train_global_v3_ext.py")
    assert ext[ext.index("--out") + 1] == str(d / "v3_candidate") and "--quick" not in ext
    interval = FakePopen.calls[2]   # last: the 90% interval refit on the same candidate dir
    assert interval[1].endswith("train_global_v3_interval.py")
    assert interval[interval.index("--out") + 1] == str(d / "v3_candidate") and "--quick" not in interval
    promoted = json.loads((d / "v3" / "evaluation_v3.json").read_text())
    assert "_ext" in promoted and "_interval" in promoted   # extended and interval keys both promoted
    assert _version(d / "v3") == "cand-1" and _version(d / "v3_prev") == "current"
    assert not (d / "v3_candidate").exists() and reloads == [1]
    assert job["candidate_val_score"]["temperature_mae"] == 0.4 and job["current_val_score"]["temperature_mae"] == 0.5
    assert job["selection_split"] == "val_select" and job["selection_window"][0].startswith("2024-10-01")
    assert job["candidate_test_score"]["temperature_mae"] == 0.4   # reported, not used for the decision

    r = admin.post("/admin/rollback", headers=ADMIN)
    assert r.status_code == 200 and r.json()["current"]["model_version"] == "current"
    assert _version(d / "v3") == "current" and _version(d / "v3_prev") == "cand-1"
    admin.post("/admin/rollback", headers=ADMIN)   # rollback of the rollback
    assert _version(d / "v3") == "cand-1"


def test_retrain_rejects_worse_or_broken_candidate(admin, models):
    d, reloads = models
    FakePopen.result = (0.45, 0.4, "worse-f1")
    FakePopen.selection = {"cand": (0.45, 0.4)}   # lower val MAE but lower val F1: not better
    job = _run_job(admin)
    assert job["status"] == "rejected" and _version(d / "v3") == "current"
    assert _version(d / "v3_candidate") == "worse-f1" and not (d / "v3_prev").exists() and reloads == []
    FakePopen.result = None   # script "succeeded" but wrote nothing
    assert _run_job(admin)["status"] == "rejected"
    FakePopen.returncode = 1
    FakePopen.calls = []
    assert _run_job(admin)["status"] == "failed"
    assert len(FakePopen.calls) == 1   # ext script skipped when the base training failed
    FakePopen.returncode, FakePopen.result, FakePopen.ext_returncode = 0, (0.4, 0.6, "cand-2"), 1
    FakePopen.selection = {"cand": (0.4, 0.6)}
    job = _run_job(admin)
    assert job["status"] == "failed" and job["step"] == "train_global_v3_ext.py"   # ext failed: no promotion
    assert _version(d / "v3") == "current"
    FakePopen.ext_returncode, FakePopen.interval_returncode, FakePopen.calls = 0, 1, []
    job = _run_job(admin)
    assert job["status"] == "failed" and job["step"] == "train_global_v3_interval.py"   # interval failed
    assert len(FakePopen.calls) == 3 and _version(d / "v3") == "current"
    assert admin.post("/admin/rollback", headers=ADMIN).status_code == 409   # no v3_prev yet


def test_promotion_is_decided_on_validation_not_test(admin, models):
    d, _ = models
    FakePopen.result = (0.9, 0.1, "bad-test-good-val")   # much worse on its (longer) test window ...
    FakePopen.selection = {"cand": (0.4, 0.6)}            # ... but better on the shared val rows
    job = _run_job(admin)
    assert job["status"] == "promoted" and _version(d / "v3") == "bad-test-good-val"
    assert job["candidate_test_score"]["temperature_mae"] == 0.9   # still reported

    FakePopen.result = (0.1, 0.9, "good-test-bad-val")   # far better test score must not promote
    FakePopen.selection = {"cand": (0.6, 0.4), "cur": (0.4, 0.6), "cur_version": "bad-test-good-val"}
    job = _run_job(admin)
    assert job["status"] == "rejected" and "validation" in job["reason"]
    assert _version(d / "v3") == "bad-test-good-val"


def test_promotion_needs_both_models_on_the_same_val_rows(admin, models):
    d, _ = models
    FakePopen.selection = {"cand": (0.4, 0.6), "cur": None}   # served model could not be scored
    job = _run_job(admin)
    assert job["status"] == "rejected" and "validation rows" in job["reason"] and _version(d / "v3") == "current"
    FakePopen.selection = {"cand": (0.4, 0.6), "cur_version": "older-model"}   # scored a different model
    assert _run_job(admin)["status"] == "rejected" and _version(d / "v3") == "current"
    FakePopen.selection = {"cand": (0.4, 0.6), "split": "validation"}   # old file: window also tuned the model
    job = _run_job(admin)
    assert job["status"] == "rejected" and "val_select" in job["reason"] and _version(d / "v3") == "current"
    FakePopen.selection = None   # no validation comparison at all (old training script)
    job = _run_job(admin)
    assert job["status"] == "rejected" and "selection_v3.json" in job["reason"]
    FakePopen.selection = {"cand": (0.4, 0.6), "beats": False}   # better than v3 but not than the baselines
    job = _run_job(admin)
    assert job["status"] == "rejected" and "baselines" in job["reason"] and _version(d / "v3") == "current"


def test_is_better_uses_validation_scores(tmp_path):
    _write_selection(tmp_path, (0.4, 0.6), cur=(0.5, 0.6))
    scores = json.loads((tmp_path / "selection_v3.json").read_text())
    cand, cur = scores["candidate"], scores["current"]
    assert monitor._is_better(cand, cur)
    assert not monitor._is_better(cand, dict(cur, temperature_mae=0.4))   # MAE must be lower
    assert not monitor._is_better(cand, dict(cur, rain_brier=0.09))
    assert not monitor._is_better(dict(cand, beats_baselines=False), None)
    assert monitor._is_better(cand, None) and not monitor._is_better(None, None)


@pytest.mark.parametrize("field,value", [("rows", 99), ("cells", 3), ("baseline_climatology_f1", 0.31),
                                       ("evaluation_rows_sha256", "1" * 64),
                                       ("temperature_mae", float("nan")), ("rain_brier", float("inf"))])
def test_promotion_rejects_mismatched_or_nonfinite_validation(models, field, value):
    d, _ = models
    candidate = d / "v3_candidate"
    _write_model(candidate, 0.4, 0.6, "candidate")
    _write_selection(candidate, (0.4, 0.6))
    path = candidate / "selection_v3.json"
    sel = json.loads(path.read_text())
    sel["current"][field] = value
    path.write_text(json.dumps(sel))
    assert monitor._promotion_check(candidate, d / "v3")[0] is False


def test_promotion_recomputes_baseline_gate_instead_of_trusting_flag(tmp_path):
    _write_selection(tmp_path, (0.4, 0.6))
    score = json.loads((tmp_path / "selection_v3.json").read_text())["candidate"]
    for field, value in (("rain_brier", 0.21), ("rain_f1", 0.3), ("temperature_mae", 0.8)):
        assert not monitor._is_better(dict(score, **{field: value}), None)


def test_retrain_one_job_at_a_time_and_auth(admin, models):
    assert admin.post("/admin/retrain").status_code == 401
    FakePopen.gate = threading.Event()
    r = admin.post("/admin/retrain", headers=ADMIN)
    assert r.status_code == 202 and r.json()["status"] == "running"
    assert admin.post("/admin/retrain", headers=ADMIN).status_code == 409
    FakePopen.gate.set()
    monitor._jobs[r.json()["job_id"]]["_thread"].join(5)
    assert admin.get("/admin/retrain/nope", headers=ADMIN).status_code == 404
