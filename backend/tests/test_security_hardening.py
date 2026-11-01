"""Security regressions using synthetic databases and in-process ASGI requests only."""
import asyncio
import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Event

import pytest
from fastapi.testclient import TestClient

import database
import main
from routers import auth, sync

EMAIL = "security@example.com"
PASSWORD = "security-password-123"
NOW = 1_800_000_000


@pytest.fixture
def account(client, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    monkeypatch.setattr(auth, "_now", lambda: NOW)
    response = client.post("/auth/register", json={"email": EMAIL, "password": PASSWORD})
    assert response.status_code == 201
    return {"Authorization": f"Bearer {response.json()['token']}"}


def put(client, headers, version=0, data=None):
    return client.put("/me/data", headers=headers, json={
        "base_version": version, "data": data if data is not None else {"settings": {"theme": "dark"}},
    })


def login(client, password=PASSWORD):
    return client.post("/auth/login", json={"email": EMAIL, "password": password})


def stream_put(headers, chunks, before_receive=None, extra_headers=()):
    """TestClient combines iterator chunks; drive ASGI directly to observe actual receive calls."""
    consumed = []
    messages = []

    async def receive():
        if before_receive is not None:
            before_receive(len(consumed))
        index = len(consumed)
        assert index < len(chunks), "Request consumed beyond the supplied stream"
        consumed.append(chunks[index])
        return {"type": "http.request", "body": chunks[index], "more_body": index < len(chunks) - 1}

    async def send(message):
        messages.append(message)

    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "PUT",
        "scheme": "http", "path": "/me/data", "raw_path": b"/me/data", "query_string": b"",
        "root_path": "", "server": ("testserver", 80), "client": ("testclient", 50000),
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()] + list(extra_headers),
    }
    asyncio.run(main.app(scope, receive, send))
    status = next(m["status"] for m in messages if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in messages if m["type"] == "http.response.body")
    return status, json.loads(body) if body else None, consumed


def legacy_accounts(path):
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL, created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL);
        CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
            created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
        CREATE TABLE user_data (user_id INTEGER PRIMARY KEY, version INTEGER NOT NULL,
            data TEXT NOT NULL, updated_at INTEGER NOT NULL);
        CREATE INDEX custom_sessions_expiry ON sessions(expires_at);
        INSERT INTO users VALUES (7, 'legacy@example.com', 'legacy-hash', 10, 20);
        INSERT INTO sessions VALUES ('legacy-token', 7, 30, 40);
        INSERT INTO user_data VALUES (7, 9, '{"private":"keep me"}', 50);
    """)
    return conn


def test_legacy_migration_preserves_rows_indexes_and_cascades(tmp_path, monkeypatch):
    path = tmp_path / "legacy.db"
    with legacy_accounts(path) as conn:
        before = {table: conn.execute(f"SELECT * FROM {table}").fetchall()
                  for table in ("users", "sessions", "user_data")}
        database.migrate(conn)
        database.migrate(conn)
        for table, rows in before.items():
            assert conn.execute(f"SELECT * FROM {table}").fetchall() == rows
        assert conn.execute("SELECT name FROM sqlite_master WHERE name = 'custom_sessions_expiry'").fetchone()
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("INSERT INTO users VALUES (NULL, 'next@example.com', 'hash', 60, 60)").lastrowid == 8
    conn.close()
    monkeypatch.setattr(database, "DATABASE_PATH", path)
    with database.get_db() as conn:
        assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
        for table, sql in (
            ("sessions", "INSERT INTO sessions VALUES ('orphan', 999, 0, 1)"),
            ("user_data", "INSERT INTO user_data VALUES (999, 1, '{}', 0)"),
        ):
            with pytest.raises(sqlite3.IntegrityError):
                conn.execute(sql)
            fk = conn.execute(f"PRAGMA foreign_key_list({table})").fetchone()
            assert fk[2:5] == ("users", "user_id", "id") and fk[6] == "CASCADE"
        conn.execute("DELETE FROM users WHERE id = 7")
        conn.commit()
        assert conn.execute("SELECT * FROM sessions").fetchall() == []
        assert conn.execute("SELECT * FROM user_data").fetchall() == []


@pytest.mark.parametrize("table", ["sessions", "user_data"])
@pytest.mark.parametrize("enforce", [False, True])
def test_legacy_orphans_abort_migration_without_data_loss(tmp_path, table, enforce):
    with legacy_accounts(tmp_path / "orphans.db") as conn:
        if table == "sessions":
            conn.execute("INSERT INTO sessions VALUES ('orphan', 999, 0, 1)")
        else:
            conn.execute("INSERT INTO user_data VALUES (999, 1, '{}', 0)")
        conn.commit()
        conn.execute(f"PRAGMA foreign_keys = {int(enforce)}")
        before = {name: conn.execute(f"SELECT * FROM {name}").fetchall()
                  for name in ("users", "sessions", "user_data")}
        with pytest.raises(sqlite3.IntegrityError):
            database.migrate(conn)
        for name, rows in before.items():
            assert conn.execute(f"SELECT * FROM {name}").fetchall() == rows
            if name != "users":
                assert conn.execute(f"PRAGMA foreign_key_list({name})").fetchall() == []
        assert not conn.execute("SELECT name FROM sqlite_master WHERE name LIKE '%_with_foreign_key'").fetchall()


@pytest.mark.parametrize("method", ["PUT", "DELETE"])
def test_session_recheck_and_sync_write_share_one_transaction(client, account, syn_db, monkeypatch, method):
    entered, release = Event(), Event()
    original = auth.require_session

    def pause_after_recheck(conn, user):
        result = original(conn, user)
        entered.set()
        assert release.wait(10), "Timed out waiting for the competing writer"
        return result

    monkeypatch.setattr(auth, "require_session", pause_after_recheck)

    def request():
        return put(client, account) if method == "PUT" else client.delete("/me/data", headers=account)

    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(request)
        try:
            assert entered.wait(10), "Session revalidation was not reached"
            with sqlite3.connect(syn_db, timeout=0.1) as conn:
                with pytest.raises(sqlite3.OperationalError, match="locked"):
                    conn.execute("DELETE FROM sessions")
        finally:
            release.set()
        assert pending.result(timeout=10).status_code == (200 if method == "PUT" else 204)
    monkeypatch.setattr(auth, "require_session", original)
    assert client.request("DELETE", "/me", headers=account, json={"password": PASSWORD}).status_code == 204
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT COUNT(*) FROM user_data").fetchone()[0] == 0


@pytest.mark.parametrize("revocation", ["account", "logout", "expiry"])
@pytest.mark.parametrize("saved", [False, True])
def test_streamed_put_rechecks_auth_after_body_wait(client, account, syn_db, monkeypatch, revocation, saved):
    if saved:
        assert put(client, account).status_code == 200
    entered, release = Event(), Event()

    def pause(index):
        if index == 0:
            entered.set()
            assert release.wait(10), "Timed out waiting for revocation"

    body = json.dumps({"base_version": int(saved), "data": {"activities": [{"private": "new"}]}}).encode()
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(stream_put, account, [body], pause)
        try:
            assert entered.wait(10), "Request did not reach its body read"
            if revocation == "account":
                response = client.request("DELETE", "/me", headers=account, json={"password": PASSWORD})
                assert response.status_code == 204
            elif revocation == "logout":
                assert client.post("/auth/logout", headers=account).status_code == 204
            else:
                monkeypatch.setattr(auth, "_now", lambda: NOW + auth.SESSION_SECONDS)
        finally:
            release.set()
        status, body, _ = pending.result(timeout=10)
    assert status == 401 and body == {"detail": auth.MSG_AUTH}
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT COUNT(*) FROM user_data").fetchone()[0] == (int(saved) if revocation != "account" else 0)
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []


@pytest.mark.parametrize("method,path", [("DELETE", "/me/data"), ("GET", "/me/data"),
                                         ("GET", "/me/export"), ("GET", "/me"), ("DELETE", "/me")])
@pytest.mark.parametrize("revocation", ["account", "session"])
def test_stale_dependency_cannot_access_or_write(client, account, syn_db, method, path, revocation):
    token = account["Authorization"].split()[1]
    with database.get_db() as conn:
        uid = conn.execute("SELECT id FROM users WHERE email = ?", (EMAIL,)).fetchone()[0]
        stale = auth.CurrentUser(id=uid, email=EMAIL, token_hash=auth._token_hash(token))
        if revocation == "account":
            auth.delete_user(conn, uid)
        else:
            conn.execute("DELETE FROM sessions WHERE user_id = ?", (uid,))
        conn.commit()
    main.app.dependency_overrides[auth.current_user] = lambda: stale
    try:
        response = client.request(method, path, headers=account,
                                  json={"password": PASSWORD} if path == "/me" and method == "DELETE" else None)
    finally:
        main.app.dependency_overrides.pop(auth.current_user)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT COUNT(*) FROM user_data").fetchone()[0] == 0


@pytest.mark.parametrize("location", ["threshold", "extension", "activity", "habits"])
@pytest.mark.parametrize("number", ["NaN", "Infinity", "-Infinity", "1e309", "-1e309"])
def test_nonfinite_numbers_never_commit(client, account, syn_db, location, number):
    original = put(client, account).json()
    data = {
        "threshold": '{"settings":{"alert_thresholds":{"rain":NUMBER}}}',
        "extension": '{"settings":{"future":{"nested":[{"value":NUMBER}]}}}',
        "activity": '{"activities":[{"future":[{"value":NUMBER}]}]}',
        "habits": '{"habits_consent":true,"habits":{"future":[{"value":NUMBER}]}}',
    }[location].replace("NUMBER", number)
    response = client.put("/me/data", headers=account,
                          content='{"base_version":1,"data":' + data + '}')
    assert response.status_code == 422
    assert client.get("/me/data", headers=account).json() == original
    assert client.get("/me/export", headers=account).json()["sync"] == original
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT version FROM user_data").fetchone()[0] == 1


@pytest.mark.parametrize("number", ["NaN", "Infinity", "-Infinity", "1e309"])
def test_string_coerced_nonfinite_thresholds_rejected(client, account, number):
    assert put(client, account, data={"settings": {"alert_thresholds": {"rain": number}}}).status_code == 422
    assert client.get("/me/data", headers=account).json()["version"] == 0


@pytest.mark.parametrize("payload", [b"", b"{broken", b"[]", b"null", b"\xff",
                                     b'{"base_version":0,"data":{}} trailing',
                                     b'{"base_version":0,"data":{"settings":{"future":"\\ud800"}}}',
                                     b"[" * 2000 + b"0" + b"]" * 2000,
                                     b'{"base_version":0,"data":{"settings":{"future":' + b"[" * 65 + b"0" + b"]" * 65 + b"}}}"])
def test_malformed_and_deep_json_fail_gracefully(client, account, payload):
    response = client.put("/me/data", headers=account, content=payload)
    assert response.status_code == 422
    assert client.get("/me/data", headers=account).json()["version"] == 0


def test_finite_nested_extensions_round_trip(client, account):
    nested = {"a": [{"b": [1e308, -1e308, 0, True, None, "Infinity"]}]}
    data = {"settings": {"extension": nested}, "activities": [nested],
            "habits_consent": True, "habits": nested}
    response = put(client, account, data=data)
    assert response.status_code == 200
    assert response.json()["data"]["settings"]["extension"] == nested
    assert client.get("/me/export", headers=account).json()["sync"] == response.json()


@pytest.mark.parametrize("corrupt", ['{"settings":{"extra":Infinity}}', '{"x":1e309}', 'not JSON',
                                     '[' * 2000 + '0' + ']' * 2000])
@pytest.mark.parametrize("recovery", ["replace", "delete"])
def test_corrupt_rows_are_recoverable_without_silent_changes(client, account, syn_db, corrupt, recovery):
    with sqlite3.connect(syn_db) as conn:
        uid = conn.execute("SELECT id FROM users WHERE email = ?", (EMAIL,)).fetchone()[0]
        conn.execute("INSERT INTO user_data VALUES (?, 7, ?, ?)", (uid, corrupt, NOW))
    for response in (client.get("/me/data", headers=account), client.get("/me/export", headers=account),
                     put(client, account, version=0)):
        assert response.status_code == 409 and response.json()["detail"]["version"] == 7
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT version, data FROM user_data").fetchone() == (7, corrupt)
    if recovery == "delete":
        assert client.delete("/me/data", headers=account).status_code == 204
        assert client.get("/me/data", headers=account).json() == {"version": 8, "data": None, "updated_at": NOW}
        assert client.get("/me/export", headers=account).status_code == 200
        return
    repaired = put(client, account, version=7)
    assert repaired.status_code == 200 and repaired.json()["version"] == 8
    assert client.get("/me/export", headers=account).json()["sync"] == repaired.json()
    assert client.delete("/me/data", headers=account).status_code == 204
    assert client.get("/me/data", headers=account).json()["version"] == 9


@pytest.mark.parametrize("content_length", [None, b"1", b"999999999"])
def test_stream_limit_stops_receiving_near_cap(client, account, content_length):
    chunk = b"x" * (64 * 1024)
    headers = [] if content_length is None else [(b"content-length", content_length)]
    status, _, consumed = stream_put(account, [chunk] * 20, extra_headers=headers)
    assert status == 413
    assert len(consumed) == sync.MAX_BODY_BYTES // len(chunk) + 1
    assert client.get("/me/data", headers=account).json()["version"] == 0


def test_stream_limit_counts_bytes_and_allows_exact_limit(client, account):
    body = json.dumps({"base_version": 0, "data": {"settings": {"extra": "ok"}}}).encode()
    body += b" " * (sync.MAX_BODY_BYTES - len(body))
    status, payload, consumed = stream_put(account, [body[:100], body[100:]])
    assert status == 200 and payload["version"] == 1 and len(consumed) == 2
    status, _, consumed = stream_put(account, [body, b" ", b"never read"])
    assert status == 413 and len(consumed) == 2


def test_stream_limit_counts_utf8_bytes_not_characters(client, account):
    text = '{"base_version":0,"data":{"settings":{"future":"' + '\u00e9' * (sync.MAX_BODY_BYTES // 2) + '"}}}'
    body = text.encode("utf-8")
    assert len(text) < sync.MAX_BODY_BYTES < len(body)
    chunks = [body[i:i + 65536] for i in range(0, len(body), 65536)] + [b"never read"]
    status, _, consumed = stream_put(account, chunks)
    assert status == 413 and len(consumed) == 5


@pytest.mark.parametrize("operation", ["login", "unknown_login", "delete"])
def test_bcrypt_does_not_hold_sqlite_write_lock(client, account, syn_db, monkeypatch, operation):
    entered, release = Event(), Event()
    original = auth.check_password

    def paused_check(password, stored):
        entered.set()
        assert release.wait(10), "Timed out waiting for independent writer"
        return original(password, stored)

    monkeypatch.setattr(auth, "check_password", paused_check)

    def request():
        if operation == "delete":
            return client.request("DELETE", "/me", headers=account, json={"password": PASSWORD})
        email = EMAIL if operation == "login" else "unknown@example.com"
        return client.post("/auth/login", json={"email": email, "password": PASSWORD})

    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(request)
        try:
            assert entered.wait(10), "Password check was not reached"
            with sqlite3.connect(syn_db, timeout=0.1) as conn:
                conn.execute("UPDATE users SET last_active_at = last_active_at + 1")
            assert put(client, account).status_code == 200
        finally:
            release.set()
        response = pending.result(timeout=10)
    assert response.status_code == {"login": 200, "unknown_login": 401, "delete": 204}[operation]


@pytest.mark.parametrize("change", ["delete", "recreate", "password"])
def test_login_rechecks_account_identity_after_bcrypt(client, account, syn_db, monkeypatch, change):
    original = auth.check_password

    def changed_while_checking(password, stored):
        valid = original(password, stored)
        with database.get_db() as conn:
            uid = conn.execute("SELECT id FROM users WHERE email = ?", (EMAIL,)).fetchone()[0]
            if change in ("delete", "recreate"):
                auth.delete_user(conn, uid)
            else:
                conn.execute("UPDATE users SET password_hash = ? WHERE id = ?", (auth.hash_password("new-password"), uid))
            conn.commit()
        if change == "recreate":
            assert client.post("/auth/register", json={"email": EMAIL, "password": PASSWORD}).status_code == 201
        return valid

    monkeypatch.setattr(auth, "check_password", changed_while_checking)
    assert login(client).status_code == 401
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == (0 if change == "delete" else 1)


@pytest.mark.parametrize("revocation", ["logout", "delete", "expiry"])
def test_delete_account_rechecks_session_after_password_check(client, account, monkeypatch, revocation):
    original = auth.check_password

    def revoke_while_checking(password, stored):
        valid = original(password, stored)
        if revocation == "logout":
            assert client.post("/auth/logout", headers=account).status_code == 204
        elif revocation == "delete":
            with database.get_db() as conn:
                uid = conn.execute("SELECT id FROM users WHERE email = ?", (EMAIL,)).fetchone()[0]
                auth.delete_user(conn, uid)
                conn.commit()
        else:
            monkeypatch.setattr(auth, "_now", lambda: NOW + auth.SESSION_SECONDS)
        return valid

    monkeypatch.setattr(auth, "check_password", revoke_while_checking)
    response = client.request("DELETE", "/me", headers=account, json={"password": PASSWORD})
    assert response.status_code == 401
    if revocation != "delete":
        with database.get_db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1


def test_concurrent_failed_logins_enforce_source_limit_atomically(client, account, syn_db, monkeypatch):
    count = auth.MAX_FAILED + 3
    barrier = Barrier(count)
    original = auth.check_password

    def simultaneous_check(password, stored):
        barrier.wait(timeout=10)
        return original(password, stored)

    monkeypatch.setattr(auth, "check_password", simultaneous_check)
    with ThreadPoolExecutor(max_workers=count) as pool:
        responses = list(pool.map(lambda _: login(client, "incorrect"), range(count)))
    assert sorted(r.status_code for r in responses) == [401] * auth.MAX_FAILED + [429] * 3
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT COUNT(*) FROM login_attempts WHERE email = ?", (EMAIL,)).fetchone()[0] == auth.MAX_FAILED
        assert conn.execute("SELECT COUNT(*) FROM login_attempts WHERE email LIKE 'source:%'").fetchone()[0] == auth.MAX_FAILED
    monkeypatch.setattr(auth, "check_password", lambda *_: pytest.fail("Locked source must not run bcrypt"))
    assert login(client).status_code == 429
    monkeypatch.setattr(auth, "check_password", original)
    owner = TestClient(main.app, client=("192.0.2.20", 1234))
    assert login(owner).status_code == 200
    assert login(client).status_code == 429


def test_correct_login_cannot_bypass_source_lock_created_during_bcrypt(client, account, syn_db, monkeypatch):
    original = auth.check_password

    def lock_while_checking(password, stored):
        source = f"source:{auth._token_hash(EMAIL)}:" + auth._token_hash(f"{EMAIL}\0testclient")
        with sqlite3.connect(syn_db) as conn:
            conn.executemany("INSERT INTO login_attempts VALUES (?, ?)", [(source, NOW)] * auth.MAX_FAILED)
        return original(password, stored)

    monkeypatch.setattr(auth, "check_password", lock_while_checking)
    assert login(client).status_code == 429
    with sqlite3.connect(syn_db) as conn:
        assert conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 1


def test_trusted_proxy_identifies_rightmost_hop_and_isolates_sources(syn_db, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    monkeypatch.setattr(auth, "_now", lambda: NOW)
    monkeypatch.setenv("TRUST_PROXY", "1")
    proxy_client = TestClient(main.app, client=("10.0.0.1", 8080))

    # Register user first
    reg = proxy_client.post(
        "/auth/register",
        json={"email": "proxy_user@example.com", "password": PASSWORD},
        headers={"X-Forwarded-For": "203.0.113.1"},
    )
    assert reg.status_code == 201

    # Attacker through proxy with spoofed first hop, rightmost is 198.51.100.50
    for _ in range(auth.MAX_FAILED):
        r = proxy_client.post(
            "/auth/login",
            json={"email": "proxy_user@example.com", "password": "wrong"},
            headers={"X-Forwarded-For": "1.2.3.4, 198.51.100.50"},
        )
        assert r.status_code == 401

    # Attacker IP is now locked
    r = proxy_client.post(
        "/auth/login",
        json={"email": "proxy_user@example.com", "password": PASSWORD},
        headers={"X-Forwarded-For": "5.6.7.8, 198.51.100.50"},
    )
    assert r.status_code == 429

    # Legitimate owner from 203.0.113.1 is NOT locked
    r = proxy_client.post(
        "/auth/login",
        json={"email": "proxy_user@example.com", "password": PASSWORD},
        headers={"X-Forwarded-For": "203.0.113.1"},
    )
    assert r.status_code == 200


def test_untrusted_proxy_ignores_spoofed_x_forwarded_for(syn_db, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    monkeypatch.setattr(auth, "_now", lambda: NOW)
    monkeypatch.delenv("TRUST_PROXY", raising=False)
    client_a = TestClient(main.app, client=("192.0.2.100", 1234))

    reg = client_a.post(
        "/auth/register",
        json={"email": "spoof_user@example.com", "password": PASSWORD},
    )
    assert reg.status_code == 201

    # Attacker tries to spoof X-Forwarded-For on each attempt
    for i in range(auth.MAX_FAILED):
        r = client_a.post(
            "/auth/login",
            json={"email": "spoof_user@example.com", "password": "wrong"},
            headers={"X-Forwarded-For": f"10.0.0.{i}"},
        )
        assert r.status_code == 401

    # Peer socket IP (192.0.2.100) is locked despite varied headers
    r = client_a.post(
        "/auth/login",
        json={"email": "spoof_user@example.com", "password": PASSWORD},
        headers={"X-Forwarded-For": "10.0.0.99"},
    )
    assert r.status_code == 429


def test_register_rate_limited_per_ip(syn_db, monkeypatch):
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    clock = [NOW]
    monkeypatch.setattr(auth, "_now", lambda: clock[0])
    reg_client = TestClient(main.app, client=("192.0.2.222", 9999))

    # 5 allowed registrations
    for i in range(auth.REGISTER_RATE_LIMIT):
        r = reg_client.post(
            "/auth/register",
            json={"email": f"test_reg_{i}@example.com", "password": PASSWORD},
        )
        assert r.status_code == 201

    # 6th attempt is throttled
    r = reg_client.post(
        "/auth/register",
        json={"email": "test_reg_extra@example.com", "password": PASSWORD},
    )
    assert r.status_code == 429
    assert "Quá nhiều" in r.json()["detail"]

    # Different IP is not affected
    other_client = TestClient(main.app, client=("192.0.2.223", 9999))
    r = other_client.post(
        "/auth/register",
        json={"email": "other_ip_reg@example.com", "password": PASSWORD},
    )
    assert r.status_code == 201

    # After 1 hour, original IP can register again
    clock[0] += auth.REGISTER_WINDOW_SECONDS + 1
    r = reg_client.post(
        "/auth/register",
        json={"email": "test_reg_after_window@example.com", "password": PASSWORD},
    )
    assert r.status_code == 201
