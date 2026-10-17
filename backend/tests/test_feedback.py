"""POST /feedback and GET /feedback/summary."""
import sqlite3

import pytest

from routers import feedback

ADMIN = {"X-Admin-Token": "s3cret"}


@pytest.fixture(autouse=True)
def _fresh_rate_limit(monkeypatch):
    feedback._hits.clear()
    monkeypatch.setenv("ADMIN_TOKEN", "s3cret")
    yield
    feedback._hits.clear()


def _rows(db, sql):
    with sqlite3.connect(db) as con:
        out = con.execute(sql).fetchall()
    con.close()
    return out


def test_post_feedback_is_stored_unverified_and_apart_from_observations(client, syn_db):
    n_obs = _rows(syn_db, "SELECT COUNT(*) FROM hourly_weather")[0][0]
    r = client.post("/feedback", json={
        "kind": "wrong_forecast", "message": "  Trời đang mưa to  ", "location_id": "tsn",
        "observed": {"raining": True, "temperature_feel": "cool"},
        "forecast_snapshot": {"rain_probability": 0.1, "temperature": 31.2}, "app_version": "1.2.0",
        "platform": "android"})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["verified"] is False and body["cell_id"] == "tsn" and body["kind"] == "wrong_forecast"
    assert body["created_at"].endswith("+07:00")
    row = _rows(syn_db, "SELECT kind, message, cell_id, observed_raining, temperature_feel, verified FROM feedback")
    assert row == [("wrong_forecast", "Trời đang mưa to", "tsn", 1, "cool", 0)]
    cols = {c[1] for c in _rows(syn_db, "PRAGMA table_info(feedback)")}
    assert not any("ip" in c.split("_") for c in cols)
    assert _rows(syn_db, "SELECT COUNT(*) FROM hourly_weather")[0][0] == n_obs


@pytest.mark.parametrize("payload", [
    {"kind": "spam", "message": "x"},
    {"kind": "bug", "message": "x" * 1001},
    {"kind": "bug", "observed": {"temperature_feel": "freezing"}},
    {"kind": "bug", "forecast_snapshot": {"blob": "x" * 3000}},
])
def test_post_feedback_validation(client, payload):
    assert client.post("/feedback", json=payload).status_code == 422


def test_post_feedback_unknown_location(client):
    assert client.post("/feedback", json={"kind": "bug", "location_id": "nowhere"}).status_code == 404


def test_post_feedback_rate_limit_per_ip(client):
    for _ in range(feedback.RATE_LIMIT):
        assert client.post("/feedback", json={"kind": "suggestion", "message": "ok"}).status_code == 201
    r = client.post("/feedback", json={"kind": "suggestion", "message": "one more"})
    assert r.status_code == 429 and "quá nhiều" in r.json()["detail"]


def test_feedback_summary_admin_only_and_counts(client, syn_db):
    ward_cell = _rows(syn_db, "SELECT l.id, l.cell_id FROM locations l WHERE l.cell_id IS NOT NULL "
                              "AND l.cell_id != 'tsn' LIMIT 1")[0]
    posts = [
        {"kind": "wrong_forecast", "observed": {"raining": True}, "forecast_snapshot": {"rain_probability": 0.1}},
        {"kind": "wrong_forecast", "observed": {"raining": False}, "forecast_snapshot": {"precipitation": 2.0}},
        {"kind": "bug", "observed": {"raining": True}, "forecast_snapshot": {"rain_probability": 0.8}},  # correct
        {"kind": "wrong_forecast", "observed": {"raining": False}},   # no snapshot: counted by kind
        {"kind": "suggestion", "location_id": ward_cell[0], "observed": {"temperature_feel": "hot"}},
    ]
    for p in posts:
        assert client.post("/feedback", json=p).status_code == 201
    assert client.get("/feedback/summary").status_code == 401
    s = client.get("/feedback/summary", headers=ADMIN).json()
    assert s["total"] == 5 and s["by_kind"] == {"wrong_forecast": 3, "bug": 1, "suggestion": 1}
    assert (s["rain_reports"], s["rain_wrong"], s["rain_wrong_rate"]) == (4, 3, 0.75)
    assert s["verified"] is False and s["temperature_feel"] == {"hot": 1}
    cells = {c["cell_id"]: c for c in s["by_cell"]}
    assert cells["unknown"]["total"] == 4 and cells[ward_cell[1]] == {"cell_id": ward_cell[1], "total": 1, "suggestion": 1}
