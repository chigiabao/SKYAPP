"""Deployment/ops: CORS from env, per-IP rate limit, ingest failure/staleness alerts, LOG_LEVEL parsing."""
import importlib
import logging
import threading
from datetime import datetime, timedelta

import pytest
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.testclient import TestClient

import main
from database import LOCAL_TZ
from rate_limit import MAX_TRACKED_CLIENTS, RateLimitMiddleware

NOW = datetime(2026, 10, 21, 10, 6, tzinfo=LOCAL_TZ)


# --- CORS -----------------------------------------------------------------------------------------

@pytest.mark.parametrize("raw, expected", [
    (None, ["*"]), ("", ["*"]), ("*", ["*"]), ("https://a.example, *", ["*"]),
    ("https://a.example, http://localhost:8112/", ["https://a.example", "http://localhost:8112"]),
])
def test_cors_origins_from_env(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("CORS_ORIGINS", raising=False)
    else:
        monkeypatch.setenv("CORS_ORIGINS", raw)
    assert main._cors_origins() == expected


def test_default_cors_never_sends_credentials():
    cors = next(m for m in main.app.user_middleware if m.cls is CORSMiddleware)
    assert cors.kwargs["allow_origins"] == ["*"]
    assert cors.kwargs["allow_credentials"] is False


# --- Rate limit -----------------------------------------------------------------------------------

class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def limited_app(per_minute=2, trust_proxy=False, clock=None):
    app = FastAPI()

    @app.get("/x")
    def x():
        return {"ok": True}

    @app.get("/live")
    def live():
        return {"status": "alive"}

    app.add_middleware(RateLimitMiddleware, per_minute=per_minute, trust_proxy=trust_proxy,
                       clock=clock or Clock())
    return TestClient(app)


def test_rate_limit_returns_429_with_retry_after_and_refills():
    clock = Clock()
    c = limited_app(per_minute=2, clock=clock)
    assert [c.get("/x").status_code for _ in range(2)] == [200, 200]
    r = c.get("/x")
    assert r.status_code == 429
    assert r.headers["retry-after"] == "30"   # 2/min -> one token every 30 s
    assert r.json()["detail"]
    clock.t += 30
    assert c.get("/x").status_code == 200


def test_rate_limit_hard_cap_preserves_existing_client_throttling_and_refill():
    clock = Clock()
    limiter = RateLimitMiddleware(None, per_minute=2, clock=clock)
    assert limiter._take("existing") == 0
    assert limiter._take("existing") == 0
    for i in range(MAX_TRACKED_CLIENTS + 100):
        wait = limiter._take(f"client-{i}")
        assert len(limiter._buckets) <= MAX_TRACKED_CLIENTS
        assert (wait == 0) == (i < MAX_TRACKED_CLIENTS - 1)
    assert len(limiter._buckets) == MAX_TRACKED_CLIENTS
    assert limiter._take(f"client-{MAX_TRACKED_CLIENTS - 2}") == 0
    assert limiter._take(f"client-{MAX_TRACKED_CLIENTS - 2}") == pytest.approx(30)
    assert limiter._take("existing") == pytest.approx(30)
    clock.t += 30
    assert limiter._take("existing") == 0
    assert limiter._take("existing") == pytest.approx(30)
    assert len(limiter._buckets) == MAX_TRACKED_CLIENTS


def test_rate_limit_at_capacity_reclaims_only_a_full_bucket(monkeypatch):
    monkeypatch.setattr("rate_limit.MAX_TRACKED_CLIENTS", 2)
    clock = Clock()
    limiter = RateLimitMiddleware(None, per_minute=2, clock=clock)
    assert limiter._take("existing") == 0
    assert limiter._take("existing") == 0
    assert limiter._take("idle") == 0
    assert limiter._take("new") > 0
    assert "new" not in limiter._buckets
    assert limiter._take("existing") == pytest.approx(30)
    clock.t += 29
    assert limiter._take("new") == pytest.approx(1)
    assert set(limiter._buckets) == {"existing", "idle"}
    clock.t += 1
    assert limiter._take("new") == 0
    assert set(limiter._buckets) == {"existing", "new"}
    assert limiter._take("existing") == 0
    assert limiter._take("existing") == pytest.approx(30)


def test_health_probes_are_never_limited():
    c = limited_app(per_minute=1)
    assert c.get("/x").status_code == 200
    assert all(c.get("/live").status_code == 200 for _ in range(5))


def test_forwarded_for_only_used_when_proxy_trusted():
    untrusted = limited_app(per_minute=1)
    assert untrusted.get("/x", headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 200
    assert untrusted.get("/x", headers={"X-Forwarded-For": "2.2.2.2"}).status_code == 429   # same peer

    trusted = limited_app(per_minute=1, trust_proxy=True)
    assert trusted.get("/x", headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 200
    assert trusted.get("/x", headers={"X-Forwarded-For": "2.2.2.2"}).status_code == 200
    # Right-most hop (added by our proxy) is the client; a spoofed left-most entry does not reset the bucket.
    assert trusted.get("/x", headers={"X-Forwarded-For": "9.9.9.9, 1.1.1.1"}).status_code == 429


def test_rate_limit_off_by_default_so_existing_tests_are_not_throttled():
    assert main.RATE_LIMIT_PER_MINUTE == 0
    assert not any(m.cls is RateLimitMiddleware for m in main.app.user_middleware)


def test_rate_limit_and_cors_wired_from_env(monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_PER_MINUTE", "1")
    monkeypatch.setenv("CORS_ORIGINS", "https://app.example")
    try:
        reloaded = importlib.reload(main)
        classes = [m.cls for m in reloaded.app.user_middleware]
        assert classes.index(CORSMiddleware) < classes.index(RateLimitMiddleware)   # CORS outermost
        c = TestClient(reloaded.app)
        origin = {"Origin": "https://app.example"}
        assert c.get("/", headers=origin).status_code == 200
        r = c.get("/", headers=origin)
        assert r.status_code == 429 and r.headers["access-control-allow-origin"] == "https://app.example"
        assert c.get("/live").status_code == 200
    finally:
        monkeypatch.delenv("RATE_LIMIT_PER_MINUTE")
        monkeypatch.delenv("CORS_ORIGINS")
        importlib.reload(main)


# --- Ingest alerts --------------------------------------------------------------------------------

@pytest.fixture
def alerts(monkeypatch):
    monkeypatch.setattr(main, "_alerts_active", set())
    monkeypatch.setattr(main, "_data_age_hours", lambda now: 1.0)
    monkeypatch.delenv("ALERT_WEBHOOK_URL", raising=False)
    monkeypatch.delenv("ALERT_FAILURE_THRESHOLD", raising=False)
    monkeypatch.delenv("ALERT_STALE_HOURS", raising=False)
    sent = []
    monkeypatch.setattr(main, "_post_webhook", lambda url, payload: sent.append((url, payload)))
    return sent


def alert_records(caplog):
    return [r for r in caplog.records if r.name == "ingest.alert" and r.levelno == logging.ERROR]


def test_alert_once_after_threshold_failures_and_rearm_on_recovery(alerts, caplog):
    caplog.set_level(logging.INFO, logger="ingest.alert")
    for n in (1, 2):
        main._check_ingest_alerts("error", n, NOW)
    assert alert_records(caplog) == []
    main._check_ingest_alerts("error", 3, NOW)
    main._check_ingest_alerts("error", 4, NOW)
    records = alert_records(caplog)
    assert len(records) == 1 and '"kind": "consecutive_failures"' in records[0].getMessage()
    main._check_ingest_alerts("ok", 0, NOW)
    assert "ingest_alert_resolved" in caplog.records[-1].getMessage()
    main._check_ingest_alerts("error", 3, NOW)
    assert len(alert_records(caplog)) == 2


def test_stale_data_alert_and_webhook(alerts, monkeypatch, caplog):
    monkeypatch.setenv("ALERT_WEBHOOK_URL", "https://hooks.example/x")
    monkeypatch.setattr(main, "_data_age_hours", lambda now: 7.5)
    started = []
    real_thread = threading.Thread

    def thread(**kw):
        t = real_thread(**kw)
        started.append(t)
        return t
    monkeypatch.setattr(main.threading, "Thread", thread)
    main._check_ingest_alerts("ok", 0, NOW)
    for t in started:
        t.join(1)
    assert len(alerts) == 1
    url, payload = alerts[0]
    assert url == "https://hooks.example/x"
    assert payload["kind"] == "stale_data" and payload["data_age_hours"] == 7.5
    assert started and started[0].daemon


def test_webhook_failure_is_swallowed(monkeypatch, caplog):
    import httpx

    def boom(*a, **kw):
        raise httpx.ConnectTimeout("down")
    monkeypatch.setattr(httpx, "post", boom)
    main._post_webhook("https://hooks.example/x", {"kind": "x"})   # must not raise
    assert any("webhook failed" in r.getMessage() for r in caplog.records)


@pytest.mark.parametrize("status_code", [None, 503])
def test_webhook_failure_never_logs_secret_url(monkeypatch, caplog, status_code):
    import httpx

    url = "https://hooks.example/private-path-token?token=private-query-token"
    request = httpx.Request("POST", url)
    if status_code is None:
        error = httpx.ConnectTimeout(f"Failed request to {url}", request=request)
    else:
        response = httpx.Response(status_code, request=request)
        error = httpx.HTTPStatusError(f"Failed request to {url}", request=request, response=response)

    def boom(*a, **kw):
        raise error
    monkeypatch.setattr(httpx, "post", boom)
    caplog.set_level(logging.WARNING, logger="ingest.alert")
    main._post_webhook(url, {"kind": "x"})
    records = [r for r in caplog.records if r.name == "ingest.alert"]
    assert len(records) == 1
    assert records[0].getMessage() == f"alert webhook failed: {type(error).__name__} (status={status_code})"
    assert records[0].exc_info is None
    for secret in (url, "hooks.example", "private-path-token", "private-query-token"):
        assert secret not in caplog.text


@pytest.mark.parametrize("status_code", [200, 503])
def test_webhook_response_never_logs_secret_url(monkeypatch, caplog, status_code):
    import httpx

    url = "https://hooks.example/private-path-token?token=private-query-token"
    requests = []

    def respond(request):
        requests.append(request.url)
        return httpx.Response(status_code)

    caplog.set_level(logging.INFO)
    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        monkeypatch.setattr(httpx, "post", client.post)
        main._post_webhook(url, {"kind": "x"})
    assert requests == [httpx.URL(url)]
    for secret in (url, "hooks.example", "private-path-token", "private-query-token"):
        assert secret not in caplog.text
    records = [r for r in caplog.records if r.name in {"httpx", "ingest.alert"}]
    expected = [] if status_code == 200 else ["alert webhook failed: HTTPStatusError (status=503)"]
    assert [r.getMessage() for r in records] == expected
    assert all(r.exc_info is None for r in records)


def test_alert_check_never_raises(alerts, monkeypatch):
    monkeypatch.setattr(main, "_data_age_hours", lambda now: 1 / 0)
    main._check_ingest_alerts("error", 5, NOW)   # logged, not raised


def test_scheduler_loop_triggers_alert_after_threshold(alerts, monkeypatch, caplog):
    import ingest
    monkeypatch.setattr(main, "_scheduler_state", dict(main._scheduler_state))
    outcomes = iter(["error", "error", "error", "stop"])

    class Stop:
        now = NOW
        stopped = False

        def is_set(self):
            return self.stopped

        def wait(self, delay):
            self.now += timedelta(seconds=delay)
            return self.stopped

    stop = Stop()

    def run(**kw):
        o = next(outcomes)
        if o == "stop":
            stop.stopped = True
            o = "ok"
        return {"status": o, "rows_inserted": 0, "rows_updated": 0, "message": ""}
    monkeypatch.setattr(main, "now_local", lambda: stop.now)
    monkeypatch.setattr(ingest, "run_ingest", run)
    main._ingest_loop(stop)
    assert len(alert_records(caplog)) == 1


def test_data_age_hours_uses_default_series(client):
    from conftest import FROZEN_NOW, LAST_TS
    age = main._data_age_hours(FROZEN_NOW)
    expected = (FROZEN_NOW - LAST_TS.replace(tzinfo=LOCAL_TZ)).total_seconds() / 3600
    assert age == pytest.approx(expected)


# --- Logging --------------------------------------------------------------------------------------

def test_invalid_log_level_does_not_crash_import(monkeypatch):
    monkeypatch.setenv("LOG_LEVEL", "loud")
    try:
        importlib.reload(main)
    finally:
        monkeypatch.delenv("LOG_LEVEL")
        importlib.reload(main)
