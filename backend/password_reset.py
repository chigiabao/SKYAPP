"""Email-only recovery; never log recovery tokens, SMTP secrets or delivery errors."""
import hashlib
import hmac
import json
import os
import secrets
import smtplib
import ssl
from dataclasses import dataclass, field
from email.message import EmailMessage

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

import database
from rate_limit import client_ip_from_request
from routers import auth

router = APIRouter(tags=["account"])
TOKEN_SECONDS = 15 * 60
REQUEST_WINDOW = 3600
EMAIL_REQUEST_LIMIT = 3
SOURCE_REQUEST_LIMIT = 10
MAX_ATTEMPTS = 5
EMAIL_CONFIRM_LIMIT = 10
SOURCE_CONFIRM_LIMIT = 30
MAX_BODY_BYTES = 4096
MSG_REQUEST = "Nếu email có tài khoản, mã khôi phục sẽ được gửi. Mã có hiệu lực 15 phút."
MSG_INVALID = "Mã khôi phục không hợp lệ hoặc đã hết hạn."
MSG_UNAVAILABLE = "Khôi phục mật khẩu qua email chưa khả dụng. Vui lòng thử lại sau."
MSG_LIMITED = "Quá nhiều yêu cầu khôi phục. Vui lòng thử lại sau 15 phút."


@dataclass(frozen=True)
class SmtpConfig:
    host: str
    port: int
    sender: str
    security: str
    username: str = field(repr=False)
    password: str = field(repr=False)


def smtp_config() -> SmtpConfig:
    host = os.environ.get("SMTP_HOST", "").strip()
    sender = os.environ.get("SMTP_FROM", "").strip()
    security = os.environ.get("SMTP_SECURITY", "starttls").strip().lower()
    username = os.environ.get("SMTP_USERNAME", "")
    password = os.environ.get("SMTP_PASSWORD", "")
    try:
        port = int(os.environ.get("SMTP_PORT", "465" if security == "ssl" else "587"))
        if (not host or any(c.isspace() for c in host) or not auth._EMAIL_RE.fullmatch(sender)
                or len(sender) > auth.EMAIL_MAX or security not in {"ssl", "starttls"}
                or not 1 <= port <= 65535 or bool(username) != bool(password)):
            raise ValueError
    except ValueError:
        raise HTTPException(status_code=503, detail=MSG_UNAVAILABLE) from None
    return SmtpConfig(host, port, sender, security, username, password)


def send_email(config: SmtpConfig, email: str, token: str) -> None:
    message = EmailMessage()
    message["From"] = config.sender
    message["To"] = email
    message["Subject"] = "Sky Weather password recovery"
    message.set_content(
        "Your Sky Weather password recovery code is:\n\n" + token
        + "\n\nEnter it in the app within 15 minutes. It can be used once."
        + "\nIf you did not request this, ignore this email.\n"
    )
    context = ssl.create_default_context()
    if config.security == "ssl":
        client = smtplib.SMTP_SSL(config.host, config.port, timeout=10, context=context)
    else:
        client = smtplib.SMTP(config.host, config.port, timeout=10)
    with client:
        if config.security == "starttls":
            client.ehlo()
            client.starttls(context=context)
            client.ehlo()
        if config.username:
            client.login(config.username, config.password)
        if client.send_message(message):
            raise smtplib.SMTPException("Delivery refused")


def _deliver(config: SmtpConfig, email: str, token: str) -> None:
    token_hash = auth._token_hash(token)
    with database.get_db() as conn:
        active = conn.execute("SELECT 1 FROM password_resets WHERE token_hash = ? AND expires_at > ?",
                              (token_hash, auth._now())).fetchone()
    if not active:
        return
    try:
        send_email(config, email, token)
    except (OSError, smtplib.SMTPException, ValueError):
        # Delivery failures must not change the public response or leave usable undelivered tokens.
        with database.get_db() as conn:
            conn.execute("DELETE FROM password_resets WHERE token_hash = ?", (token_hash,))
            conn.commit()


def _limits(conn, email: str, request: Request, phase: str, now: int) -> bool:
    conn.execute("DELETE FROM password_resets WHERE expires_at <= ?", (now,))
    conn.execute("DELETE FROM password_reset_attempts WHERE attempted_at <= ?", (now - REQUEST_WINDOW,))
    window = REQUEST_WINDOW if phase == "request" else TOKEN_SECONDS
    # Check the source first so blocked sources cannot allocate unlimited per-email markers.
    limits = (("source", client_ip_from_request(request),
               SOURCE_REQUEST_LIMIT if phase == "request" else SOURCE_CONFIRM_LIMIT),
              ("email", email, EMAIL_REQUEST_LIMIT if phase == "request" else EMAIL_CONFIRM_LIMIT))
    for scope, value, limit in limits:
        key = hashlib.sha256(f"{phase}\0{scope}\0{value}".encode()).hexdigest()
        count = conn.execute("SELECT COUNT(*) FROM password_reset_attempts "
                             "WHERE key_hash = ? AND attempted_at > ?", (key, now - window)).fetchone()[0]
        if count >= limit:
            return True
        conn.execute("INSERT INTO password_reset_attempts (key_hash, attempted_at) VALUES (?, ?)",
                     (key, now))
    return False


class ResetRequest(BaseModel):
    email: str = Field(..., max_length=254)


class ResetConfirm(ResetRequest):
    token: str = Field(..., min_length=1, max_length=128)
    password: str = Field(..., max_length=128)


async def _reset_body(request: Request, model):
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_BODY_BYTES:
            raise HTTPException(status_code=413, detail="Request body too large.")
        body.extend(chunk)
    # FastAPI's default validation details echo rejected inputs, including secrets.
    try:
        return model.model_validate(json.loads(body))
    except (ValueError, TypeError, RecursionError):
        raise HTTPException(status_code=422, detail=MSG_INVALID) from None


async def _request_body(request: Request) -> ResetRequest:
    return await _reset_body(request, ResetRequest)


async def _confirm_body(request: Request) -> ResetConfirm:
    return await _reset_body(request, ResetConfirm)


@router.post("/auth/password-reset/request", status_code=202)
def request_reset(request: Request, background_tasks: BackgroundTasks,
                  body: ResetRequest = Depends(_request_body)):
    config = smtp_config()  # Check before looking up any address, including unknown accounts.
    email = auth.normalize_email(body.email)
    now = auth._now()
    token = secrets.token_urlsafe(24)
    with database.get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        blocked = _limits(conn, email, request, "request", now)
        user = conn.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if user and not blocked:
            conn.execute("INSERT INTO password_resets (user_id, token_hash, expires_at, attempts) "
                         "VALUES (?, ?, ?, 0) ON CONFLICT(user_id) DO UPDATE SET "
                         "token_hash = excluded.token_hash, expires_at = excluded.expires_at, attempts = 0",
                         (user["id"], auth._token_hash(token), now + TOKEN_SECONDS))
        conn.commit()
    # Always schedule the same task. SMTP runs after the HTTP response, not on the lookup path.
    background_tasks.add_task(_deliver, config, email, token)
    return {"message": MSG_REQUEST}


def _valid(row, token_hash: str, now: int) -> bool:
    return (row is not None and row["expires_at"] > now and row["attempts"] < MAX_ATTEMPTS
            and hmac.compare_digest(row["token_hash"], token_hash))


@router.post("/auth/password-reset/confirm", status_code=204)
def confirm_reset(request: Request, body: ResetConfirm = Depends(_confirm_body)):
    email = auth.normalize_email(body.email)
    auth._check_password_rules(body.password)
    token_hash = auth._token_hash(body.token.strip())
    now = auth._now()
    with database.get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        blocked = _limits(conn, email, request, "confirm", now)
        row = conn.execute("SELECT r.* FROM password_resets r JOIN users u ON u.id = r.user_id "
                           "WHERE u.email = ?", (email,)).fetchone()
        if blocked:
            conn.commit()
            raise HTTPException(status_code=429, detail=MSG_LIMITED)
        if not _valid(row, token_hash, now):
            if row:
                conn.execute("UPDATE password_resets SET attempts = attempts + 1 WHERE user_id = ?",
                             (row["user_id"],))
            conn.commit()
            raise HTTPException(status_code=422, detail=MSG_INVALID)
        conn.commit()
    password_hash = auth.hash_password(body.password)
    with database.get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        latest = conn.execute("SELECT * FROM password_resets WHERE user_id = ?", (row["user_id"],)).fetchone()
        # Recheck after bcrypt: concurrent reset, resend, deletion, expiry or failed attempts win.
        if not _valid(latest, token_hash, auth._now()):
            raise HTTPException(status_code=422, detail=MSG_INVALID)
        conn.execute("UPDATE users SET password_hash = ?, last_active_at = ? WHERE id = ?",
                     (password_hash, auth._now(), row["user_id"]))
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (row["user_id"],))
        conn.execute("DELETE FROM password_resets WHERE user_id = ?", (row["user_id"],))
        conn.execute("DELETE FROM login_attempts WHERE email = ? OR email LIKE ?",
                     (email, f"source:{auth._token_hash(email)}:%"))
        conn.commit()
    return Response(status_code=204)
