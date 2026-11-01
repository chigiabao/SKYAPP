"""Deleting sync data must not recycle revisions held by other devices."""
import sqlite3

import pytest

from routers import auth

NOW = 1_800_000_000
PASSWORD = "sync-delete-password"
DOCUMENT = {
    "saved_places": [{"id": "phuong-an-dong"}],
    "settings": {"theme": "dark"},
    "activities": [{"name": "morning run"}],
    "habits_consent": True,
    "habits": {"morning_run": 0.8},
}


@pytest.fixture
def headers(client, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_now", lambda: NOW)
    response = client.post("/auth/register", json={
        "email": "sync-delete@example.com", "password": PASSWORD,
    })
    assert response.status_code == 201
    return {"Authorization": f"Bearer {response.json()['token']}"}


def put(client, headers, version, data):
    return client.put("/me/data", headers=headers, json={"base_version": version, "data": data})


@pytest.mark.parametrize("version", [-1, 2**63, 10**100])
def test_sync_rejects_versions_outside_signed_int64(client, headers, version):
    assert put(client, headers, version, {}).status_code == 422
    assert client.get("/me/data", headers=headers).json()["version"] == 0


@pytest.mark.parametrize("version", [2**63 - 2, 2**63 - 1])
def test_sync_int64_boundary_returns_conflict_not_server_error(client, headers, version):
    assert put(client, headers, version, {}).status_code == 409


def test_delete_erases_payload_but_retains_revision(client, headers, syn_db, monkeypatch):
    assert put(client, headers, 0, DOCUMENT).status_code == 200
    monkeypatch.setattr(auth, "_now", lambda: NOW + 60)

    response = client.delete("/me/data", headers=headers)
    assert response.status_code == 204 and response.content == b""
    tombstone = {"version": 2, "data": None, "updated_at": NOW + 60}
    assert client.get("/me/data", headers=headers).json() == tombstone
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT version, data, updated_at FROM user_data").fetchall() == [
            (2, "null", NOW + 60),
        ]
    exported = client.get("/me/export", headers=headers).json()
    assert exported["sync"] == tombstone
    assert len(exported["sessions"]) == 1
    assert client.get("/me", headers=headers).status_code == 200


@pytest.mark.parametrize("saved_version", [1, 3])
def test_stale_version_cannot_overwrite_later_data(client, headers, saved_version):
    for base in range(saved_version):
        assert put(client, headers, base, DOCUMENT).status_code == 200
    assert client.delete("/me/data", headers=headers).status_code == 204
    deleted = client.get("/me/data", headers=headers).json()
    fresh = put(client, headers, deleted["version"], {"settings": {"theme": "light"}})
    assert fresh.status_code == 200

    stale = put(client, headers, saved_version, DOCUMENT)
    assert stale.status_code == 409
    assert stale.json()["current"] == fresh.json()
    assert fresh.json()["version"] > deleted["version"] > saved_version
    assert client.get("/me/data", headers=headers).json() == fresh.json()


@pytest.mark.parametrize("saved_first", [False, True])
def test_repeated_delete_advances_revision_even_when_empty(client, headers, saved_first):
    version = 0
    if saved_first:
        assert put(client, headers, 0, DOCUMENT).status_code == 200
        version = 1

    for expected in range(version + 1, version + 4):
        response = client.delete("/me/data", headers=headers)
        assert response.status_code == 204 and response.content == b""
        tombstone = {"version": expected, "data": None, "updated_at": NOW}
        assert client.get("/me/data", headers=headers).json() == tombstone
        for stale_version in range(expected):
            stale = put(client, headers, stale_version, DOCUMENT)
            assert stale.status_code == 409
            assert stale.json()["current"] == tombstone
        assert client.get("/me/data", headers=headers).json() == tombstone

    resumed = put(client, headers, expected, DOCUMENT)
    assert resumed.status_code == 200
    assert resumed.json()["version"] == expected + 1


def test_client_reset_to_zero_can_retry_from_tombstone(client, headers):
    assert put(client, headers, 0, DOCUMENT).status_code == 200
    assert client.delete("/me/data", headers=headers).status_code == 204

    # AccountProvider resets to zero on delete, then retries 409 using current.version.
    stale = put(client, headers, 0, DOCUMENT)
    assert stale.status_code == 409
    current = stale.json()["current"]
    assert current == {"version": 2, "data": None, "updated_at": NOW}
    resumed = put(client, headers, current["version"], DOCUMENT)
    assert resumed.status_code == 200
    assert resumed.json()["version"] == 3
    assert resumed.json()["data"]["habits"] == DOCUMENT["habits"]


def test_account_deletion_removes_revision_tombstone(client, headers, syn_db):
    assert client.delete("/me/data", headers=headers).status_code == 204
    assert client.get("/me/data", headers=headers).json()["version"] == 1
    response = client.request("DELETE", "/me", headers=headers, json={"password": PASSWORD})
    assert response.status_code == 204
    assert client.get("/me/data", headers=headers).status_code == 401
    with sqlite3.connect(syn_db) as conn:
        for table in ("user_data", "sessions", "users"):
            assert conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0
