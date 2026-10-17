"""Forecast log hooked into ingest, retention, GET /admin/monitor and retrain / rollback (subprocess mocked)."""
import json
import sqlite3
import threading
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

import ai_model
import ingest
import main
from conftest import point_app_at, synthetic_rows, write_db
from database import LOCAL_TZ
from routers import monitor
from test_ingest import NOW, NOW_HOUR, FakeAPI

ADMIN = {"X-Admin-Token": "s3cret"}
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
    alert = _q(ingest_db, "SELECT issued_at, horizon_h, alert, precipitation FROM ai_forecast_log "
                          "WHERE source = 'map_alert'")
    assert len(alert) == 1 and alert[0][:3] == (NOW_HOUR, 3, 0) and alert[0][3] is not None
    n = _q(ingest_db, "SELECT COUNT(*) FROM ai_forecast_log")[0][0]
    ingest.run_ingest(db_path=ingest_db, now=NOW)   # same hour again: first publication kept, no duplicates
    assert _q(ingest_db, "SELECT COUNT(*) FROM ai_forecast_log")[0][0] == n


def test_post_ingest_failure_never_fails_ingest(ingest_db, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("monitor down")
    monkeypatch.setattr(monitor, "post_ingest", boom)
    assert ingest.run_ingest(db_path=ingest_db, now=NOW)["status"] == "ok"


def test_retention_deletes_old_rows_once_per_day(ingest_db, monkeypatch):
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


@pytest.fixture
def admin(syn_db, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", "s3cret")
    monkeypatch.setattr(monitor, "now_local", lambda: MON_NOW)
    return TestClient(main.app)


def test_monitor_scores_published_forecasts(admin, syn_db, monkeypatch):
    monkeypatch.setattr(monitor, "_rain_thresholds", lambda: {1: 0.5, 3: 0.5, 6: 0.5})
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
    _exec(syn_db, "INSERT INTO ai_forecast_log VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
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
    a = m["alerts"]["total"]
    assert a == {"evaluated": 3, "predicted": 1, "observed": 1, "false_alarms": 1, "missed": 1}
    assert m["ingest"]["by_day"] == [{"day": "2023-06-24", "runs": 2, "errors": 1, "partial": 0, "api_calls": 11,
                                      "cells_failed": 0}]
    assert m["ingest"]["recent_errors"][0]["message"] == "boom"
    assert m["api_calls"] == [{"day": "2023-06-24", "open_meteo": 11, "osrm": 5, "osrm_errors": 1}]
    assert m["feedback"]["total"] == 1 and m["feedback"]["latest"][0]["verified"] is False


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


class FakePopen:
    """Stands in for the training subprocess: writes the candidate model when it 'finishes'."""
    result = (0.4, 0.6, "cand-1")   # mae, f1, version; None = write nothing
    returncode = 0
    gate = None                     # threading.Event to hold the job in 'running'
    calls = []

    def __init__(self, cmd, **kw):
        FakePopen.calls.append(cmd)
        self.out = monitor.Path(cmd[cmd.index("--out") + 1])

    def wait(self):
        if FakePopen.gate is not None:
            FakePopen.gate.wait(5)
        if FakePopen.result is not None:
            _write_model(self.out, *FakePopen.result)
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
    assert "--quick" in cmd
    assert _version(d / "v3") == "cand-1" and _version(d / "v3_prev") == "current"
    assert not (d / "v3_candidate").exists() and reloads == [1]
    assert job["candidate_score"]["temperature_mae"] == 0.4 and job["current_score"]["temperature_mae"] == 0.5

    r = admin.post("/admin/rollback", headers=ADMIN)
    assert r.status_code == 200 and r.json()["current"]["model_version"] == "current"
    assert _version(d / "v3") == "current" and _version(d / "v3_prev") == "cand-1"
    admin.post("/admin/rollback", headers=ADMIN)   # rollback of the rollback
    assert _version(d / "v3") == "cand-1"


def test_retrain_rejects_worse_or_broken_candidate(admin, models):
    d, reloads = models
    FakePopen.result = (0.45, 0.4, "worse-f1")   # lower MAE but lower F1: not better
    job = _run_job(admin)
    assert job["status"] == "rejected" and _version(d / "v3") == "current"
    assert _version(d / "v3_candidate") == "worse-f1" and not (d / "v3_prev").exists() and reloads == []
    FakePopen.result = None   # script "succeeded" but wrote nothing
    assert _run_job(admin)["status"] == "rejected"
    FakePopen.returncode = 1
    assert _run_job(admin)["status"] == "failed"
    assert _version(d / "v3") == "current"
    assert admin.post("/admin/rollback", headers=ADMIN).status_code == 409   # no v3_prev yet


def test_retrain_one_job_at_a_time_and_auth(admin, models):
    assert admin.post("/admin/retrain").status_code == 401
    FakePopen.gate = threading.Event()
    r = admin.post("/admin/retrain", headers=ADMIN)
    assert r.status_code == 202 and r.json()["status"] == "running"
    assert admin.post("/admin/retrain", headers=ADMIN).status_code == 409
    FakePopen.gate.set()
    monitor._jobs[r.json()["job_id"]]["_thread"].join(5)
    assert admin.get("/admin/retrain/nope", headers=ADMIN).status_code == 404
