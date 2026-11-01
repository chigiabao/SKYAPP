"""Recovery integration and TLS tests; email delivery is always a test fake."""
import hashlib
import smtplib
import ssl
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest

import database
import password_reset as reset
from routers import auth

EMAIL = "owner@example.com"
PASSWORD = "old-password-123"
NEW_PASSWORD = "new-password-456"
REQUEST = "/auth/password-reset/request"
CONFIRM = "/auth/password-reset/confirm"


@pytest.fixture
def recovery(client, monkeypatch):
    now = [1_800_000_000]
    monkeypatch.setattr(auth, "_now", lambda: now[0])
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)
    monkeypatch.setattr(auth, "_dummy_hash", None)
    for key, value in {"SMTP_HOST": "smtp.example.com", "SMTP_FROM": "noreply@example.com",
                       "SMTP_PORT": "587", "SMTP_SECURITY": "starttls",
                       "SMTP_USERNAME": "test-user", "SMTP_PASSWORD": "fake-smtp-secret"}.items():
        monkeypatch.setenv(key, value)
    mail = []
    monkeypatch.setattr(reset, "send_email", lambda config, email, token: mail.append((email, token)))
    session = client.post("/auth/register", json={"email": EMAIL, "password": PASSWORD}).json()
    return client, now, mail, session


def issue(recovery, email=EMAIL):
    api, _, mail, _ = recovery
    response = api.post(REQUEST, json={"email": email})
    assert response.status_code == 202
    return mail[-1][1]


def confirm(api, token, email=EMAIL, password=NEW_PASSWORD):
    return api.post(CONFIRM, json={"email": email, "token": token, "password": password})


def bearer(token):
    return {"Authorization": "Bearer " + token}


def test_reset_hashes_token_changes_password_revokes_all_sessions(recovery):
    api, _, mail, session = recovery
    other = api.post("/auth/login", json={"email": EMAIL, "password": PASSWORD}).json()
    other_user = api.post("/auth/register", json={"email": "other@example.com", "password": PASSWORD}).json()
    token = issue(recovery, "  OWNER@EXAMPLE.COM  ")
    assert mail[-1][0] == EMAIL and len(token) == 32
    with database.get_db() as conn:
        row = conn.execute("SELECT * FROM password_resets").fetchone()
        assert row["token_hash"] == hashlib.sha256(token.encode()).hexdigest()
        assert token not in str(tuple(row))
        assert PASSWORD not in str(tuple(row))
    response = confirm(api, " " + token + " ")
    assert response.status_code == 204 and response.content == b""
    assert confirm(api, token).status_code == 422
    for old in (session, other):
        assert api.get("/me", headers=bearer(old["token"])).status_code == 401
        assert api.get("/me/data", headers=bearer(old["token"])).status_code == 401
    assert api.get("/me", headers=bearer(other_user["token"])).status_code == 200
    assert api.post("/auth/login", json={"email": EMAIL, "password": PASSWORD}).status_code == 401
    assert api.post("/auth/login", json={"email": EMAIL, "password": NEW_PASSWORD}).status_code == 200
    with database.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM password_resets").fetchone()[0] == 0
        stored = conn.execute("SELECT password_hash FROM users WHERE email = ?", (EMAIL,)).fetchone()[0]
        assert stored != NEW_PASSWORD and auth.check_password(NEW_PASSWORD, stored)


def test_request_and_invalid_token_do_not_enumerate_accounts(recovery):
    api, _, mail, _ = recovery
    known = api.post(REQUEST, json={"email": EMAIL})
    unknown = api.post(REQUEST, json={"email": "unknown@example.com"})
    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json() == {"message": reset.MSG_REQUEST}
    assert len(mail) == 1 and mail[0][1] not in known.text
    bad = confirm(api, "wrong")
    missing = confirm(api, "wrong", email="unknown@example.com")
    assert bad.status_code == missing.status_code == 422
    assert bad.json() == missing.json() == {"detail": reset.MSG_INVALID}


@pytest.mark.parametrize("name,value", [
    ("SMTP_HOST", ""), ("SMTP_FROM", ""), ("SMTP_FROM", "sender\nBcc: victim@example.com"),
    ("SMTP_PORT", "invalid"), ("SMTP_PORT", "0"), ("SMTP_SECURITY", "plain"),
    ("SMTP_USERNAME", ""), ("SMTP_PASSWORD", ""),
])
def test_unconfigured_smtp_fails_for_every_address(recovery, monkeypatch, name, value):
    api, _, mail, _ = recovery
    monkeypatch.setenv(name, value)
    known = api.post(REQUEST, json={"email": EMAIL})
    unknown = api.post(REQUEST, json={"email": "unknown@example.com"})
    assert known.status_code == unknown.status_code == 503
    assert known.json() == unknown.json() == {"detail": reset.MSG_UNAVAILABLE}
    assert not mail
    with database.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM password_resets").fetchone()[0] == 0


@pytest.mark.parametrize("failure", [smtplib.SMTPException, OSError, ssl.SSLCertVerificationError])
def test_delivery_failure_is_generic_and_invalidates_token(recovery, monkeypatch, caplog, capsys, failure):
    api, _, _, _ = recovery
    captured = []

    def fail(config, email, token):
        captured.append(token)
        raise failure("private failure " + token + config.password)

    monkeypatch.setattr(reset, "send_email", fail)
    known = api.post(REQUEST, json={"email": EMAIL})
    unknown = api.post(REQUEST, json={"email": "unknown@example.com"})
    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()
    assert len(captured) == 1
    assert confirm(api, captured[0]).status_code == 422
    output = capsys.readouterr()
    assert captured[0] not in known.text + caplog.text + output.out + output.err
    assert "fake-smtp-secret" not in caplog.text + output.out + output.err


def test_expiry_is_enforced_at_boundary(recovery):
    api, now, _, session = recovery
    token = issue(recovery)
    now[0] += reset.TOKEN_SECONDS
    assert confirm(api, token).status_code == 422
    assert api.get("/me", headers=bearer(session["token"])).status_code == 200


def test_new_request_invalidates_previous_token(recovery):
    api, _, _, _ = recovery
    first = issue(recovery)
    second = issue(recovery)
    assert first != second
    assert confirm(api, first).status_code == 422
    assert confirm(api, second).status_code == 204


def test_five_failed_attempts_disable_token_until_new_request(recovery):
    api, _, _, _ = recovery
    token = issue(recovery)
    for _ in range(reset.MAX_ATTEMPTS):
        assert confirm(api, "wrong-token").status_code == 422
    assert confirm(api, token).status_code == 422
    assert confirm(api, issue(recovery)).status_code == 204


def test_email_request_limit_uses_normalized_email_and_keeps_generic_response(recovery):
    api, now, mail, _ = recovery
    for _ in range(reset.EMAIL_REQUEST_LIMIT + 2):
        assert api.post(REQUEST, json={"email": " OWNER@example.com "}).json() == {"message": reset.MSG_REQUEST}
    assert len(mail) == reset.EMAIL_REQUEST_LIMIT
    now[0] += reset.REQUEST_WINDOW
    issue(recovery)
    assert len(mail) == reset.EMAIL_REQUEST_LIMIT + 1


def test_source_request_limit_includes_unknown_addresses_and_hashes_markers(recovery):
    api, _, mail, _ = recovery
    for i in range(reset.SOURCE_REQUEST_LIMIT):
        assert api.post(REQUEST, json={"email": f"unknown{i}@example.com"}).status_code == 202
    assert api.post(REQUEST, json={"email": EMAIL}).status_code == 202
    assert not mail
    with database.get_db() as conn:
        markers = conn.execute("SELECT key_hash FROM password_reset_attempts").fetchall()
        assert markers and all(len(row[0]) == 64 and EMAIL not in row[0] for row in markers)
        assert len(markers) == reset.SOURCE_REQUEST_LIMIT * 2
    for i in range(3):
        api.post(REQUEST, json={"email": f"blocked{i}@example.com"})
    with database.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM password_reset_attempts").fetchone()[0] == len(markers)


def test_email_request_limit_cannot_be_bypassed_by_switching_source(recovery, monkeypatch):
    api, _, mail, _ = recovery
    monkeypatch.setattr(reset, "client_ip_from_request", lambda request: request.headers.get("x-test-source"))
    for i in range(reset.EMAIL_REQUEST_LIMIT + 2):
        response = api.post(REQUEST, json={"email": EMAIL}, headers={"x-test-source": str(i)})
        assert response.status_code == 202
    assert len(mail) == reset.EMAIL_REQUEST_LIMIT


def test_confirmation_limits_cover_unknown_accounts_and_different_sources(recovery, monkeypatch):
    api, _, _, _ = recovery
    monkeypatch.setattr(reset, "client_ip_from_request", lambda request: request.headers.get("x-test-source", "test"))
    for i in range(reset.EMAIL_CONFIRM_LIMIT):
        response = api.post(CONFIRM, json={"email": "unknown@example.com", "token": "bad", "password": NEW_PASSWORD},
                            headers={"x-test-source": str(i)})
        assert response.status_code == 422
    assert confirm(api, "bad", email="unknown@example.com").status_code == 429
    # The preceding email-limited request also counts once against this source.
    for i in range(reset.SOURCE_CONFIRM_LIMIT - 1):
        assert confirm(api, "bad", email=f"unknown{i}@example.com").status_code == 422
    assert confirm(api, "bad", email="last@example.com").status_code == 429


@pytest.mark.parametrize("changes", [
    {"password": "short"}, {"password": "x" * 129}, {"token": "x" * 129}, {"token": ""},
    {"token": ["sensitive-token"]}, {"password": ["sensitive-password"]},
])
def test_validation_does_not_echo_secret_inputs_or_consume_good_token(recovery, changes):
    api, _, _, _ = recovery
    token = issue(recovery)
    body = {"email": EMAIL, "token": token, "password": NEW_PASSWORD, **changes}
    response = api.post(CONFIRM, json=body)
    assert response.status_code == 422
    assert token not in response.text and NEW_PASSWORD not in response.text
    assert "sensitive-" not in response.text and "x" * 129 not in response.text
    assert confirm(api, token).status_code == 204


def test_account_deletion_cascades_reset_record(recovery):
    api, _, _, session = recovery
    token = issue(recovery)
    assert api.request("DELETE", "/me", json={"password": PASSWORD}, headers=bearer(session["token"])).status_code == 204
    with database.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM password_resets").fetchone()[0] == 0
    assert confirm(api, token).status_code == 422


def test_concurrent_confirmation_can_only_succeed_once(recovery, monkeypatch):
    api, _, _, _ = recovery
    token = issue(recovery)
    gate = Barrier(2)
    original = auth.hash_password

    def hash_together(password):
        gate.wait(timeout=10)
        return original(password)

    monkeypatch.setattr(auth, "hash_password", hash_together)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(confirm, api, token) for _ in range(2)]
        statuses = sorted(f.result(timeout=15).status_code for f in futures)
    assert statuses == [204, 422]


def test_resend_during_bcrypt_prevents_stale_confirmation(recovery, monkeypatch):
    api, _, _, _ = recovery
    token = issue(recovery)
    original = auth.hash_password

    def resend(password):
        issue(recovery)
        return original(password)

    monkeypatch.setattr(auth, "hash_password", resend)
    assert confirm(api, token).status_code == 422
    monkeypatch.setattr(auth, "hash_password", original)
    assert api.post("/auth/login", json={"email": EMAIL, "password": PASSWORD}).status_code == 200


def test_success_clears_login_lockouts(recovery):
    api, _, _, _ = recovery
    for _ in range(auth.MAX_FAILED):
        api.post("/auth/login", json={"email": EMAIL, "password": "wrong"})
    assert confirm(api, issue(recovery)).status_code == 204
    assert api.post("/auth/login", json={"email": EMAIL, "password": NEW_PASSWORD}).status_code == 200


@pytest.mark.parametrize("security", ["starttls", "ssl"])
def test_smtp_validates_certificates_and_never_authenticates_before_tls(monkeypatch, security):
    events = []

    class FakeSmtp:
        def __init__(self, host, port, timeout, context=None):
            assert host == "smtp.example.com" and timeout == 10
            if security == "ssl":
                verify(context)
            else:
                assert context is None

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def ehlo(self):
            events.append("ehlo")

        def starttls(self, context):
            verify(context)
            events.append("tls")

        def login(self, username, password):
            assert security == "ssl" or "tls" in events
            assert username == "fake-user" and password == "fake-secret"
            events.append("login")

        def send_message(self, message):
            assert events[-1] == "login"
            assert message["To"] == EMAIL
            assert "fake-recovery-token" in message.get_content()
            events.append("send")
            return {}

    def verify(context):
        assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED

    monkeypatch.setattr(reset.smtplib, "SMTP", FakeSmtp)
    monkeypatch.setattr(reset.smtplib, "SMTP_SSL", FakeSmtp)
    config = reset.SmtpConfig("smtp.example.com", 465 if security == "ssl" else 587,
                              "noreply@example.com", security, "fake-user", "fake-secret")
    assert "fake-secret" not in repr(config)
    reset.send_email(config, EMAIL, "fake-recovery-token")
    assert events[-1] == "send"


def test_starttls_unavailable_never_falls_back_to_plaintext(monkeypatch):
    class NoTls:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def ehlo(self):
            pass

        def starttls(self, **kwargs):
            raise smtplib.SMTPNotSupportedError("TLS unavailable")

        def login(self, *args):
            pytest.fail("Plaintext login must never happen")

        def send_message(self, *args):
            pytest.fail("Plaintext delivery must never happen")

    monkeypatch.setattr(reset.smtplib, "SMTP", NoTls)
    config = reset.SmtpConfig("smtp.example.com", 587, "noreply@example.com", "starttls", "fake", "fake")
    with pytest.raises(smtplib.SMTPNotSupportedError):
        reset.send_email(config, EMAIL, "fake-token")
