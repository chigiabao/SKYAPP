"""Regression tests for the backend review: admin trust, Vietnamese errors without leaked exception text,
abuse paths (register cost, OSRM lock, limiter eviction), router->main import cycle and models/ read-only."""
import ast
import sqlite3
import time
from pathlib import Path
from unittest.mock import Mock

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

import errors
import ingest
import main
from rate_limit import RateLimitMiddleware
from routers import admin, auth, monitor, route
from routers.admin import require_admin

TOKEN = "test-admin-token-0123456789abcdef"
BACKEND = Path(__file__).resolve().parents[1]


# --- admin ---------------------------------------------------------------------------------------------

@pytest.fixture
def local_admin():
    app = FastAPI()

    @app.post("/x", dependencies=[Depends(require_admin)])
    def x():
        return {"ok": True}
    return TestClient(app, client=("127.0.0.1", 50000))


@pytest.mark.parametrize("headers", [
    {"Origin": "https://evil.example"}, {"Origin": "null"},
    {"Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "same-site"}, {"Sec-Fetch-Site": "same-origin"},
])
def test_tokenless_localhost_admin_rejects_browser_requests(local_admin, monkeypatch, headers):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    r = local_admin.post("/x", headers=headers)
    assert r.status_code == 403 and r.json()["detail"] == admin.MSG_BROWSER


def test_tokenless_localhost_admin_still_allows_curl(local_admin, monkeypatch):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    assert local_admin.post("/x").status_code == 200
    assert local_admin.post("/x", headers={"Sec-Fetch-Site": "none"}).status_code == 200


@pytest.mark.parametrize("weak", ["change-me", "CHANGE-ME", "short-token", "x" * 23])
def test_placeholder_or_short_admin_token_disables_admin(local_admin, monkeypatch, weak, caplog):
    monkeypatch.setenv("ADMIN_TOKEN", weak)
    r = local_admin.post("/x", headers={"X-Admin-Token": weak})
    assert r.status_code == 503 and r.json()["detail"] == admin.MSG_WEAK_TOKEN
    admin.warn_if_weak_admin_token()
    assert "ADMIN_TOKEN" in caplog.text


def test_strong_admin_token_works_from_browser(local_admin, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", TOKEN)
    assert local_admin.post("/x", headers={"Origin": "https://evil.example"}).status_code == 401
    assert local_admin.post("/x", headers={"X-Admin-Token": TOKEN + "x"}).status_code == 401
    assert local_admin.post("/x", headers={"X-Admin-Token": TOKEN}).status_code == 200


def test_env_example_admin_token_is_rejected():
    env = (BACKEND.parent / ".env.example").read_text(encoding="utf-8")
    value = next(line.split("=", 1)[1].strip() for line in env.splitlines() if line.startswith("ADMIN_TOKEN="))
    assert value == "" or admin.weak_admin_token(value)


def test_forecast_only_ingest_is_409_not_500(client, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", TOKEN)
    monkeypatch.setenv("EXTERNAL_FORECAST_ENABLED", "0")
    run = Mock(side_effect=AssertionError("must not ingest"))
    monkeypatch.setattr(ingest, "run_ingest", run)
    r = client.post("/admin/ingest", params={"forecast_only": True}, headers={"X-Admin-Token": TOKEN})
    assert r.status_code == 409 and r.json()["detail"] == admin.MSG_FORECAST_ONLY
    run.assert_not_called()


# --- Vietnamese errors, no exception text ---------------------------------------------------------------

def test_query_validation_is_vietnamese_and_does_not_echo_input(client):
    r = client.get("/weather/hourly", params={"hours": 999})
    assert r.status_code == 422
    body = r.json()
    assert body["detail"] == "Dữ liệu yêu cầu không hợp lệ: hours: phải nhỏ hơn hoặc bằng 168."
    assert body["errors"] == [{"loc": ["query", "hours"], "msg": "phải nhỏ hơn hoặc bằng 168",
                               "type": "less_than_equal"}]
    assert "999" not in r.text and "Input should" not in r.text


def test_body_validation_keeps_authored_vietnamese_messages():
    payload = errors.validation_payload([
        {"type": "missing", "loc": ("body", "email"), "msg": "Field required", "input": {"secret": 1}},
        {"type": "value_error", "loc": ("body", "saved_places"), "msg": "Value error, Địa điểm bị trùng.",
         "input": "secret", "ctx": {"error": ValueError("x")}},
        {"type": "something_new", "loc": ("query", "q"), "msg": "English", "input": "secret"},
    ])
    assert payload["detail"] == ("Dữ liệu yêu cầu không hợp lệ: email: thiếu giá trị bắt buộc; "
                                 "saved_places: Địa điểm bị trùng; q: giá trị không hợp lệ.")
    assert "secret" not in str(payload) and all("input" not in e and "ctx" not in e for e in payload["errors"])


def test_route_profile_validation_is_vietnamese(client):
    r = client.post("/route", json={"from_lat": 10.8, "from_lon": 106.6, "to_lat": 10.7, "to_lon": 106.7,
                                     "profile": "plane"})
    assert r.status_code == 422 and r.json()["detail"].startswith("Dữ liệu yêu cầu không hợp lệ: profile: phải là")


@pytest.mark.parametrize("params, detail", [
    ({"start_date": "2023-13-01", "end_date": "2023-06-02"}, "Ngày không hợp lệ; dùng định dạng YYYY-MM-DD."),
    ({"start_date": "2023-06-02", "end_date": "2023-06-01"}, "Ngày kết thúc phải sau ngày bắt đầu."),
    ({"start_date": "2021-01-01", "end_date": "2023-06-01"}, "Khoảng thời gian không được vượt quá 365 ngày."),
])
def test_history_errors_are_vietnamese(client, params, detail):
    r = client.get("/weather/history", params=params)
    assert r.status_code == 400 and r.json()["detail"] == detail


def test_bad_at_is_vietnamese(client):
    r = client.get("/weather/current", params={"at": "yesterday"})
    assert r.status_code == 400 and r.json()["detail"].startswith("Thời điểm `at` không hợp lệ")


def test_monitor_503_logs_but_does_not_return_exception_text(client, monkeypatch, caplog):
    monkeypatch.setenv("ADMIN_TOKEN", TOKEN)
    monkeypatch.setattr(monitor, "_ingest_stats",
                        Mock(side_effect=sqlite3.OperationalError("no such table: C:/private/path/x")))
    r = client.get("/admin/monitor", headers={"X-Admin-Token": TOKEN})
    assert r.status_code == 503 and "private" not in r.text
    assert "private/path" in caplog.text


def test_rate_limit_429_is_vietnamese():
    limiter = TestClient(RateLimitMiddleware(FastAPI(), per_minute=1))
    limiter.get("/x")
    r = limiter.get("/x")
    assert r.status_code == 429 and r.json()["detail"].startswith("Quá nhiều yêu cầu")


# --- abuse paths ----------------------------------------------------------------------------------------

def test_throttled_registration_skips_bcrypt_and_duplicate_is_409(client, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "REGISTER_RATE_LIMIT", 2)
    body = {"email": "an@example.com", "password": "matkhau-dung-123"}
    assert client.post("/auth/register", json=body).status_code == 201
    dup = client.post("/auth/register", json={**body, "email": "AN@example.com"})
    assert dup.status_code == 409 and dup.json()["detail"] == auth.MSG_REGISTER
    hashing = Mock(side_effect=AssertionError("throttled requests must not pay for bcrypt"))
    monkeypatch.setattr(auth, "hash_password", hashing)
    r = client.post("/auth/register", json={**body, "email": "binh@example.com"})
    assert r.status_code == 429 and r.json()["detail"] == auth.MSG_REGISTER_LOCKED
    hashing.assert_not_called()


def test_limiter_at_capacity_evicts_least_recently_used_refilled_bucket(monkeypatch):
    monkeypatch.setattr("rate_limit.MAX_TRACKED_CLIENTS", 2)
    now = [0.0]
    limiter = RateLimitMiddleware(None, per_minute=2, clock=lambda: now[0])
    assert limiter._take("old") == 0          # one token spent, full again after 30 s
    now[0] = 50
    assert limiter._take("recent") == 0
    now[0] = 60
    assert limiter._take("newcomer") == 0     # the old (refilled) bucket is reclaimed, not the recent one
    assert set(limiter._buckets) == {"recent", "newcomer"}


def test_osrm_lock_is_not_held_during_http_call(client, monkeypatch):
    monkeypatch.setattr(monitor, "record_api_call", Mock())   # never count calls in any real DB
    held = []

    def fake_get(url, params):
        held.append(route._osrm_lock.locked())
        return route.httpx.Response(200, json={"code": "NoRoute"})
    monkeypatch.setattr(route, "_http_get", fake_get)
    monkeypatch.setattr(route, "OSRM_MIN_INTERVAL", 0)
    with pytest.raises(route.NoRoute):
        route._osrm_request("driving", (10.8, 106.6), (10.7, 106.7))
    assert held == [False]


def test_osrm_queue_full_is_503_without_sleeping(client, monkeypatch):
    monkeypatch.setattr(route, "_http_get", Mock(side_effect=AssertionError("must not call OSRM")))
    saved = route._last_call[0]
    route._last_call[0] = time.monotonic() + 3600   # next free OSRM slot is an hour away
    route._cache.clear()
    try:
        started = time.monotonic()
        r = client.post("/route", json={"from_lat": 10.8, "from_lon": 106.65, "to_lat": 10.77, "to_lon": 106.7})
    finally:
        route._last_call[0] = saved
    assert r.status_code == 503 and time.monotonic() - started < 2


# --- structure / ops ------------------------------------------------------------------------------------

def test_no_router_imports_main():
    for path in (BACKEND / "routers").glob("*.py"):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            names = ([a.name for a in node.names] if isinstance(node, ast.Import)
                     else [node.module] if isinstance(node, ast.ImportFrom) else [])
            assert "main" not in names, f"{path.name} imports main"


def test_health_and_live_ai_share_config_freshness():
    import config
    from routers import weather_ai
    assert weather_ai.config is config and main.config is config


def test_retrain_on_read_only_models_dir_is_409(client, monkeypatch, tmp_path):
    monkeypatch.setenv("ADMIN_TOKEN", TOKEN)
    not_a_dir = tmp_path / "models"
    not_a_dir.write_text("read-only stand-in", encoding="utf-8")   # mkdir under a file -> OSError
    monkeypatch.setattr(monitor, "MODELS_DIR", not_a_dir)
    monkeypatch.setattr(monitor.subprocess, "Popen", Mock(side_effect=AssertionError("must not train")))
    r = client.post("/admin/retrain", headers={"X-Admin-Token": TOKEN})
    assert r.status_code == 409 and r.json()["detail"] == monitor.MSG_MODELS_READONLY


def test_rollback_failure_is_409_and_keeps_current_model(client, monkeypatch, tmp_path):
    monkeypatch.setenv("ADMIN_TOKEN", TOKEN)
    (tmp_path / "v3").mkdir()
    (tmp_path / "v3" / "marker").write_text("current", encoding="utf-8")
    (tmp_path / "v3_prev").mkdir()
    monkeypatch.setattr(monitor, "MODELS_DIR", tmp_path)
    reload = Mock()
    monkeypatch.setattr(monitor, "_reload_models", reload)
    real_rename = Path.rename

    def rename(self, target):
        if self.name == "v3_prev":
            raise PermissionError("read-only")
        return real_rename(self, target)
    monkeypatch.setattr(Path, "rename", rename)
    r = client.post("/admin/rollback", headers={"X-Admin-Token": TOKEN})
    assert r.status_code == 409 and r.json()["detail"] == monitor.MSG_MODELS_READONLY
    assert (tmp_path / "v3" / "marker").read_text(encoding="utf-8") == "current"
    assert (tmp_path / "v3_prev").is_dir()
    reload.assert_not_called()
