"""Ingest pipeline tests. All HTTP is mocked (ingest._get_json); no network access."""
import sqlite3
import threading
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

import database
import ingest
import main
from conftest import write_db, synthetic_rows, point_app_at, freeze_now, FROZEN_NOW
from database import AIR_QUALITY_COLUMNS, LOCAL_TZ, WEATHER_COLUMNS, migrate

NOW = datetime(2023, 6, 25, 10, 37, tzinfo=LOCAL_TZ)   # synthetic data ends 2023-06-24 23:00
NOW_HOUR = "2023-06-25 10:00:00"


def _value(var: str, ts: datetime, bump: float) -> float:
    base = {"temperature_2m": 27.0, "relative_humidity_2m": 80, "weather_code": 3, "wind_direction_10m": 120,
            "visibility": 20000.0, "surface_pressure": 1008.0, "pressure_msl": 1009.0}.get(var, 1.0)
    return round(base + (ts.hour % 5) * 0.1 + bump, 1)


class FakeAPI:
    """Stands in for Open-Meteo. Historical: full days start_date..end_date (incl. future hours of today).
    Forecast: 8 days from today's 00:00. `bump` simulates model revisions; `fail` raises like a dead API."""

    def __init__(self, now=NOW):
        self.now = now
        self.bump = 0.0
        self.fail = set()   # {"historical", "forecast"}
        self.calls = []

    def __call__(self, url, params):
        kind = {ingest.HISTORICAL_URL: "historical", ingest.AIR_QUALITY_URL: "air_quality"}.get(url, "forecast")
        self.calls.append((kind, dict(params)))
        if kind in self.fail:
            raise RuntimeError(f"{kind} API down")
        if kind == "historical":
            start = datetime.fromisoformat(params["start_date"])
            end = datetime.fromisoformat(params["end_date"]) + timedelta(days=1)
        else:
            start = datetime(self.now.year, self.now.month, self.now.day) - timedelta(days=params.get("past_days", 0))
            end = datetime(self.now.year, self.now.month, self.now.day) + timedelta(days=params["forecast_days"])
        times, t = [], start
        while t < end:
            times.append(t)
            t += timedelta(hours=1)
        hourly = {"time": [x.strftime("%Y-%m-%dT%H:%M") for x in times]}
        variables = AIR_QUALITY_COLUMNS if kind == "air_quality" else WEATHER_COLUMNS.values()
        for var in variables:
            hourly[var] = [_value(var, x, self.bump) for x in times]
        return {"timezone": "Asia/Ho_Chi_Minh", "hourly": hourly}


@pytest.fixture
def external_forecast_enabled(monkeypatch):
    monkeypatch.setenv("EXTERNAL_FORECAST_ENABLED", "1")


@pytest.fixture(autouse=True)
def default_external_forecast_disabled(monkeypatch):
    monkeypatch.delenv("EXTERNAL_FORECAST_ENABLED", raising=False)


@pytest.fixture
def api(monkeypatch):
    fake = FakeAPI()
    monkeypatch.setattr(ingest, "_get_json", fake)
    return fake


@pytest.fixture
def db(tmp_path):
    """Old-schema synthetic DB (no location_id) - the migration runs on first connect."""
    return write_db(tmp_path / "w.db", synthetic_rows(), locations=False)


def _q(db, sql, params=()):
    with sqlite3.connect(db) as con:
        rows = con.execute(sql, params).fetchall()
    con.close()
    return rows


def _snapshot(db):
    return (_q(db, "SELECT * FROM hourly_weather ORDER BY location_id, timestamp"),
            _q(db, "SELECT * FROM nwp_forecast ORDER BY issued_at, timestamp"),
            _q(db, "SELECT * FROM air_quality ORDER BY timestamp"))


def test_migration_idempotent_and_backfills(db):
    n = _q(db, "SELECT COUNT(*) FROM hourly_weather")[0][0]
    for _ in range(2):
        con = sqlite3.connect(db)
        migrate(con)
        con.close()
    assert _q(db, "SELECT COUNT(*), MIN(location_id), MAX(location_id) FROM hourly_weather")[0] == (n, "tsn", "tsn")
    assert _q(db, "SELECT id, lat, lon, elevation FROM locations") == [("tsn", 10.7909, 106.6313, 6.0)]
    with sqlite3.connect(db) as con, pytest.raises(sqlite3.IntegrityError):
        con.execute("INSERT INTO hourly_weather (location_id, timestamp) VALUES ('tsn', '2023-06-24 23:00:00')")
    con.close()


def test_ingest_inserts_until_now_only_and_is_idempotent(db, api):
    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row["status"] == "ok", row["message"]
    # 2023-06-25 00:00 .. 10:00 are new (11 h); the 49 overlap hours (06-22 23:00 .. 06-24 23:00) differ
    # from the synthetic values -> updated in place, not duplicated
    assert (row["rows_inserted"], row["rows_updated"]) == (11, 49)
    assert _q(db, "SELECT MAX(timestamp) FROM hourly_weather")[0][0] == NOW_HOUR   # nothing from the future
    assert _q(db, "SELECT COUNT(*) FROM (SELECT 1 FROM hourly_weather GROUP BY location_id, timestamp "
                  "HAVING COUNT(*) > 1)")[0][0] == 0
    # observed window starts 48 h before the last stored hour
    hist = [p for k, p in api.calls if k == "historical"][0]
    assert hist["start_date"] == "2023-06-22" and hist["end_date"] == "2023-06-25" and hist["elevation"] == 6.0

    before = _snapshot(db)[0]
    again = ingest.run_ingest(db_path=db, now=NOW)
    assert again["status"] == "ok"
    assert (again["rows_inserted"], again["rows_updated"]) == (0, 0)
    assert _snapshot(db)[0] == before


def test_revisions_are_updated(db, api):
    ingest.run_ingest(db_path=db, now=NOW)
    api.bump = 0.5
    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row["rows_inserted"] == 0 and row["rows_updated"] > 0
    assert _q(db, "SELECT temperature FROM hourly_weather WHERE timestamp = ?", (NOW_HOUR,))[0][0] == \
        _value("temperature_2m", datetime(2023, 6, 25, 10), 0.5)


def test_gap_fill_within_overlap_and_gap_report(db, api):
    with sqlite3.connect(db) as con:
        migrate(con)
        con.execute("DELETE FROM hourly_weather WHERE timestamp BETWEEN '2023-06-24 05:00:00' AND '2023-06-24 07:00:00'")
        con.execute("DELETE FROM hourly_weather WHERE timestamp = '2023-06-12 03:00:00'")   # older than overlap
    con.close()
    con = ingest.connect(db)
    assert len(ingest.find_gaps(con, "tsn")) >= 2
    con.close()

    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row["status"] == "ok"
    assert row["rows_inserted"] == 3 + 11
    con = ingest.connect(db)
    gaps = ingest.find_gaps(con, "tsn")
    con.close()
    assert ("2023-06-12 02:00:00", "2023-06-12 04:00:00", 1) in gaps
    assert not any(a.startswith("2023-06-24") for a, _, _ in gaps)
    assert "2023-06-12 02:00:00 -> 2023-06-12 04:00:00 (1 h missing)" in row["message"]


def test_failure_leaves_data_unchanged(db, api, external_forecast_enabled):
    ingest.run_ingest(db_path=db, now=NOW)
    before = _snapshot(db)
    api.fail = {"historical"}
    api.bump = 1.0
    later = NOW + timedelta(hours=3)
    api.now = later
    row = ingest.run_ingest(db_path=db, now=later)
    assert row["status"] == "error" and "API down" in row["message"]
    assert row["finished_at"] is not None
    assert _snapshot(db) == before


def test_forecast_failure_still_writes_observed(db, api, external_forecast_enabled):
    ingest.run_ingest(db_path=db, now=NOW)
    previous_forecasts = _snapshot(db)[1]
    api.fail = {"forecast"}
    api.bump = 1.0
    later = NOW + timedelta(hours=3)
    api.now = later
    row = ingest.run_ingest(db_path=db, now=later)
    assert row["status"] == "ok"
    assert "WARNING external forecast skipped" in row["message"] and "API down" in row["message"]
    assert row["rows_inserted"] == 3 and row["rows_updated"] > 0
    assert _q(db, "SELECT MAX(timestamp) FROM hourly_weather")[0][0] == "2023-06-25 13:00:00"
    assert _snapshot(db)[1] == previous_forecasts
    assert _q(db, "SELECT MAX(us_aqi) FROM air_quality")[0][0] == _value("us_aqi", later.replace(hour=4), 1.0)


@pytest.mark.parametrize("enabled", [None, "0", "true"])
def test_default_ingest_stores_historical_without_external_forecast(db, api, monkeypatch, enabled):
    if enabled is not None:
        monkeypatch.setenv("EXTERNAL_FORECAST_ENABLED", enabled)
    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row["status"] == "ok" and row["rows_inserted"] == 11
    assert row["source"] == "open-meteo:historical-forecast"
    assert "external forecasts disabled" in row["message"]
    assert "forecast issue" not in row["message"]
    assert [kind for kind, _ in api.calls] == ["historical", "air_quality"]
    assert _q(db, "SELECT MAX(timestamp) FROM hourly_weather")[0][0] == NOW_HOUR
    assert _q(db, "SELECT COUNT(*) FROM nwp_forecast")[0][0] == 0
    assert _q(db, "SELECT COUNT(*) FROM air_quality")[0][0] == 336


def test_disabling_external_forecasts_preserves_existing_issues(db, api, external_forecast_enabled, monkeypatch):
    ingest.run_ingest(db_path=db, now=NOW)
    before = _snapshot(db)[1]
    assert before
    api.calls.clear()
    monkeypatch.setenv("EXTERNAL_FORECAST_ENABLED", "0")
    row = ingest.run_ingest(db_path=db, now=NOW + timedelta(hours=1))
    assert row["status"] == "ok" and row["rows_inserted"] == 1
    assert [kind for kind, _ in api.calls] == ["historical", "air_quality"]
    assert _snapshot(db)[1] == before


def test_cli_help_documents_external_forecast_opt_in(capsys):
    with pytest.raises(SystemExit) as exc:
        ingest.main(["--help"])
    assert exc.value.code == 0
    help_text = capsys.readouterr().out
    assert "--forecast-only" in help_text and "EXTERNAL_FORECAST_ENABLED=1" in help_text
    assert "default: 0" in help_text


def test_forecast_only_disabled_raises_before_network_or_database(db, api, monkeypatch):
    def unexpected_connect(*args, **kwargs):
        pytest.fail("disabled forecast-only must not open the database")

    monkeypatch.setattr(ingest, "connect", unexpected_connect)
    with pytest.raises(ValueError, match="forecast_only requires EXTERNAL_FORECAST_ENABLED=1"):
        ingest.run_ingest(db_path=db, now=NOW, forecast_only=True)
    assert api.calls == []
    assert not ingest._lock.locked()


def test_forecast_only_failure_leaves_data_unchanged(db, api, external_forecast_enabled):
    ingest.run_ingest(db_path=db, now=NOW, forecast_only=True)
    before = _snapshot(db)
    api.fail = {"forecast"}
    row = ingest.run_ingest(db_path=db, now=NOW + timedelta(hours=1), forecast_only=True)
    assert row["status"] == "error" and "API down" in row["message"]
    assert _snapshot(db) == before


def test_forecast_issue_has_168_future_hours_and_prune_keeps_5(db, api, external_forecast_enabled):
    for h in range(7):
        now = NOW + timedelta(hours=h)
        api.now = now
        row = ingest.run_ingest(db_path=db, now=now, forecast_only=True)
        assert row["status"] == "ok" and row["rows_inserted"] == 168
    issues = [r[0] for r in _q(db, "SELECT DISTINCT issued_at FROM nwp_forecast ORDER BY issued_at")]
    assert len(issues) == ingest.KEEP_ISSUES
    assert issues[-1] == "2023-06-25 16:00:00" and issues[0] == "2023-06-25 12:00:00"
    lo, hi, n = _q(db, "SELECT MIN(timestamp), MAX(timestamp), COUNT(*) FROM nwp_forecast WHERE issued_at = ?",
                   (issues[-1],))[0]
    assert (lo, hi, n) == ("2023-06-25 17:00:00", "2023-07-02 16:00:00", 168)
    # forecast-only never touches hourly_weather
    assert _q(db, "SELECT MAX(timestamp) FROM hourly_weather")[0][0] == "2023-06-24 23:00:00"


def test_lock_prevents_overlapping_runs(db, api):
    assert ingest._lock.acquire(blocking=False)
    try:
        with pytest.raises(ingest.IngestBusy):
            ingest.run_ingest(db_path=db, now=NOW)
    finally:
        ingest._lock.release()


def test_seconds_until_next_run():
    assert main._seconds_until_next_run(datetime(2026, 1, 1, 10, 0, tzinfo=LOCAL_TZ)) == 300
    assert main._seconds_until_next_run(datetime(2026, 1, 1, 10, 5, tzinfo=LOCAL_TZ)) == 3600
    assert main._seconds_until_next_run(datetime(2026, 1, 1, 10, 30, tzinfo=LOCAL_TZ)) == 35 * 60


@pytest.fixture
def admin_client(db, api, monkeypatch):
    point_app_at(monkeypatch, db)
    freeze_now(monkeypatch)
    api.now = FROZEN_NOW
    monkeypatch.setattr(ingest, "now_local", lambda: FROZEN_NOW)
    return TestClient(main.app)


def test_admin_requires_token(admin_client, monkeypatch):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    assert admin_client.get("/admin/ingest/log").status_code == 403    # TestClient host is not localhost
    monkeypatch.setenv("ADMIN_TOKEN", "s3cret")
    assert admin_client.get("/admin/ingest/log").status_code == 401
    assert admin_client.get("/admin/ingest/log", headers={"X-Admin-Token": "nope"}).status_code == 401
    assert admin_client.get("/admin/ingest/log", headers={"X-Admin-Token": "s3cret"}).status_code == 200


def test_admin_ingest_log_and_health(admin_client, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", "s3cret")
    h = {"X-Admin-Token": "s3cret"}
    r = admin_client.post("/admin/ingest", headers=h)
    assert r.status_code == 200
    row = r.json()
    assert row["status"] == "ok" and row["rows_inserted"] > 0
    log = admin_client.get("/admin/ingest/log", params={"limit": 5}, headers=h).json()
    assert log[0]["id"] == row["id"]
    body = admin_client.get("/health").json()
    assert body["latest_timestamp"] == FROZEN_NOW.replace(minute=0, second=0).isoformat()
    assert body["last_ingest"]["status"] == "ok"
    assert body["last_ingest"]["rows_inserted"] == row["rows_inserted"]


def test_health_without_ingest_log(client):
    assert client.get("/health").json()["last_ingest"] is None


def test_scheduler_disabled_in_tests(db, monkeypatch):
    point_app_at(monkeypatch, db)
    assert database.DATABASE_PATH == db
    main.weather.invalidate_climatology()
    with TestClient(main.app):
        assert not any(t.name == "ingest-scheduler" for t in threading.enumerate())
    main.weather.invalidate_climatology()


def test_migration_adds_uv_index_and_air_quality(db):
    con = sqlite3.connect(db)
    migrate(con)
    con.close()
    for table in ("hourly_weather", "nwp_forecast"):
        assert "uv_index" in {r[1] for r in _q(db, f"PRAGMA table_info({table})")}
    assert {r[1] for r in _q(db, "PRAGMA table_info(air_quality)")} == {"location_id", "timestamp", "us_aqi",
                                                                       "pm2_5", "pm10"}
    assert _q(db, "SELECT COUNT(*) FROM hourly_weather WHERE uv_index IS NOT NULL")[0][0] == 0


def test_ingest_stores_uv_index_and_air_quality(db, api, external_forecast_enabled):
    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row["status"] == "ok" and "air quality: 336 hours" in row["message"]
    assert _q(db, "SELECT uv_index FROM hourly_weather WHERE timestamp = ?", (NOW_HOUR,))[0][0] ==         _value("uv_index", datetime(2023, 6, 25, 10), 0)
    assert _q(db, "SELECT COUNT(*) FROM nwp_forecast WHERE uv_index IS NOT NULL")[0][0] == 168
    aq = [p for k, p in api.calls if k == "air_quality"][0]
    assert aq["hourly"] == "us_aqi,pm2_5,pm10" and aq["timezone"] == "Asia/Ho_Chi_Minh"
    assert (aq["latitude"], aq["longitude"], aq["past_days"]) == (10.7909, 106.6313, 7)
    assert _q(db, "SELECT MIN(timestamp), MAX(timestamp), COUNT(*) FROM air_quality")[0] ==         ("2023-06-18 00:00:00", "2023-07-01 23:00:00", 336)
    # upsert: a second run with revised values overwrites, never duplicates
    api.bump = 2.0
    ingest.run_ingest(db_path=db, now=NOW)
    assert _q(db, "SELECT COUNT(*), MAX(us_aqi) FROM air_quality")[0] == (336, _value("us_aqi", datetime(2023, 6, 25, 4), 2.0))   # hour % 5 == 4 is the max


def test_air_quality_failure_still_writes_weather(db, api, external_forecast_enabled):
    api.fail = {"air_quality"}
    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row["status"] == "ok"
    assert "WARNING air quality skipped" in row["message"] and "API down" in row["message"]
    assert _q(db, "SELECT MAX(timestamp) FROM hourly_weather")[0][0] == NOW_HOUR
    assert _q(db, "SELECT COUNT(*) FROM nwp_forecast")[0][0] == 168
    assert _q(db, "SELECT COUNT(*) FROM air_quality")[0][0] == 0
