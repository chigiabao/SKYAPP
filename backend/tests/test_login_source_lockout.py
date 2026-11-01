"""Failed logins must not deny the account owner access from another source."""
import sqlite3

import pytest
from fastapi.testclient import TestClient

import main
from routers import auth

PASSWORD = "correct-password-123"
EMAIL = "owner@example.com"


@pytest.fixture
def sources(client, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    clock = [1_800_000_000]
    monkeypatch.setattr(auth, "_now", lambda: clock[0])
    attacker = TestClient(main.app, client=("192.0.2.10", 1234))
    owner = TestClient(main.app, client=("192.0.2.20", 5678))
    assert owner.post("/auth/register", json={"email": EMAIL, "password": PASSWORD}).status_code == 201
    return attacker, owner, clock


def attempt(client, password, **kwargs):
    return client.post("/auth/login", json={"email": EMAIL, "password": password}, **kwargs)


def test_owner_can_login_after_another_source_locks_email(sources):
    attacker, owner, _ = sources
    for _ in range(auth.MAX_FAILED):
        assert attempt(attacker, "incorrect").status_code == 401
    assert attempt(attacker, PASSWORD).status_code == 429
    assert attempt(owner, PASSWORD).status_code == 200
    # Successful recovery must not unlock the attacking source.
    assert attempt(attacker, PASSWORD).status_code == 429


def test_forwarded_header_cannot_reset_source_limit(sources):
    attacker, _, clock = sources
    for i in range(auth.MAX_FAILED):
        assert attempt(attacker, "incorrect", headers={"X-Forwarded-For": f"198.51.100.{i}"}).status_code == 401
    assert attempt(attacker, PASSWORD, headers={"X-Forwarded-For": "198.51.100.99"}).status_code == 429
    clock[0] += auth.LOCKOUT_SECONDS + 1
    assert attempt(attacker, PASSWORD).status_code == 200


def test_source_markers_do_not_store_raw_addresses(sources, syn_db):
    attacker, _, _ = sources
    attempt(attacker, "incorrect")
    with sqlite3.connect(syn_db) as conn:
        keys = [row[0] for row in conn.execute("SELECT email FROM login_attempts")]
    assert EMAIL in keys
    assert len(keys) == 2
    assert all("192.0.2." not in key for key in keys)


def test_other_source_wrong_password_still_limited(sources):
    attacker, owner, _ = sources
    for _ in range(auth.MAX_FAILED):
        attempt(attacker, "incorrect")
    for _ in range(auth.MAX_FAILED):
        assert attempt(owner, "also-incorrect").status_code == 429
    assert attempt(owner, PASSWORD).status_code == 429


def test_source_marker_cannot_be_used_as_an_email(sources, syn_db):
    attacker, owner, _ = sources
    assert attempt(owner, "incorrect").status_code == 401
    with sqlite3.connect(syn_db) as conn:
        marker = conn.execute("SELECT email FROM login_attempts WHERE email != ?", (EMAIL,)).fetchone()[0]
    for _ in range(auth.MAX_FAILED):
        response = attacker.post("/auth/login", json={"email": marker, "password": "incorrect"})
        assert response.status_code == 422
    assert attempt(owner, PASSWORD).status_code == 200


def test_account_deletion_clears_only_its_own_failed_sources(sources, syn_db):
    attacker, owner, _ = sources
    session = attempt(owner, PASSWORD).json()
    for _ in range(auth.MAX_FAILED):
        attempt(attacker, "incorrect")
    assert attacker.post("/auth/login", json={"email": "other@example.com", "password": "incorrect"}).status_code == 401
    response = owner.request("DELETE", "/me", json={"password": PASSWORD},
                             headers={"Authorization": f"Bearer {session['token']}"})
    assert response.status_code == 204
    with sqlite3.connect(syn_db) as conn:
        keys = {row[0] for row in conn.execute("SELECT email FROM login_attempts")}
    assert keys == {"other@example.com",
                    f"source:{auth._token_hash('other@example.com')}:" + auth._token_hash("other@example.com\0" + "192.0.2.10")}
    assert owner.post("/auth/register", json={"email": EMAIL, "password": PASSWORD}).status_code == 201
    assert attempt(attacker, PASSWORD).status_code == 200
