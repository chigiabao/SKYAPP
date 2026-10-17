"""
Optional accounts: email + password, used only to sync data between devices (the app works fully without one).

Security:
- Passwords: bcrypt over base64(sha256(password)) (avoids bcrypt's 72-byte cut-off); 8..128 characters.
- Brute force: at most MAX_FAILED failed logins per email per LOCKOUT_SECONDS (counted in login_attempts).
- Sessions: random secrets.token_urlsafe(32) bearer tokens sent as `Authorization: Bearer <token>`; only the
  sha256 of a token is stored; valid SESSION_DAYS days. No cookies, so no CSRF surface on the web.
- Login errors are generic and never say whether the email exists; unknown emails still pay a bcrypt check.

Privacy policy (also served by GET /privacy):
- Stored: email, password hash, creation / last-activity time, session-token hashes, and the sync document
  (saved places, settings, activities, habits only with consent). No IP address, no raw GPS position.
- Retention: sessions expire after 30 days (expired ones are purged); accounts inactive for 2 years are
  deleted together with all their data.
- Deletion: DELETE /me/data deletes the synced data; DELETE /me (password required) deletes the account and
  everything; GET /me/export downloads all of it as JSON.
"""
import base64
import hashlib
import hmac
import re
import secrets
import sqlite3
import time
from typing import Optional

import bcrypt
from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

import database

router = APIRouter(tags=["account"])

SESSION_DAYS = 30
SESSION_SECONDS = SESSION_DAYS * 86400
INACTIVE_SECONDS = 2 * 365 * 86400   # accounts unused for 2 years are deleted
MAX_FAILED = 5
LOCKOUT_SECONDS = 15 * 60
BCRYPT_ROUNDS = 12                   # tests lower this
EMAIL_MAX = 254
PASSWORD_MIN, PASSWORD_MAX = 8, 128
_EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$")

MSG_BAD_LOGIN = "Email hoặc mật khẩu không đúng."
MSG_LOCKED = "Đăng nhập sai quá nhiều lần. Vui lòng thử lại sau 15 phút."
MSG_AUTH = "Phiên đăng nhập không hợp lệ hoặc đã hết hạn. Vui lòng đăng nhập lại."
MSG_REGISTER = "Không thể tạo tài khoản với email này."
MSG_EMAIL = "Email không hợp lệ."
MSG_PASSWORD = f"Mật khẩu phải có từ {PASSWORD_MIN} đến {PASSWORD_MAX} ký tự."

PRIVACY_POLICY = {
    "lưu_gì": ("Email, bản băm mật khẩu, thời điểm tạo và hoạt động gần nhất, bản băm token phiên, "
               "và dữ liệu đồng bộ (địa điểm đã lưu, cài đặt, hoạt động/lịch; thói quen chỉ khi bạn đồng ý). "
               "Không lưu địa chỉ IP và vị trí GPS thô."),
    "bao_lâu": ("Phiên đăng nhập hết hạn sau 30 ngày và được tự xoá. Tài khoản không hoạt động 2 năm "
                "sẽ bị xoá cùng toàn bộ dữ liệu."),
    "xoá_thế_nào": ("DELETE /me/data xoá dữ liệu đồng bộ; DELETE /me (nhập lại mật khẩu) xoá tài khoản và "
                    "toàn bộ dữ liệu; GET /me/export tải về toàn bộ dữ liệu dạng JSON."),
    "không_cần_tài_khoản": "Ứng dụng dùng đầy đủ mà không cần đăng nhập; tài khoản chỉ để đồng bộ giữa các thiết bị.",
}

_bearer = HTTPBearer(auto_error=False)
_dummy_hash: Optional[bytes] = None


def _now() -> int:
    """Unix seconds (patched in tests)."""
    return int(time.time())


def _prehash(password: str) -> bytes:
    return base64.b64encode(hashlib.sha256(password.encode("utf-8")).digest())


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_prehash(password), bcrypt.gensalt(BCRYPT_ROUNDS)).decode("ascii")


def check_password(password: str, stored: Optional[str]) -> bool:
    """Constant-time bcrypt check; with stored=None it still burns a bcrypt round (no email enumeration)."""
    global _dummy_hash
    if stored is None:
        if _dummy_hash is None:
            _dummy_hash = bcrypt.hashpw(b"dummy-password", bcrypt.gensalt(BCRYPT_ROUNDS))
        bcrypt.checkpw(_prehash(password), _dummy_hash)
        return False
    return bcrypt.checkpw(_prehash(password), stored.encode("ascii"))


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def normalize_email(email: str) -> str:
    email = email.strip().lower()
    if len(email) > EMAIL_MAX or not _EMAIL_RE.match(email):
        raise HTTPException(status_code=422, detail=MSG_EMAIL)
    return email


def _check_password_rules(password: str) -> None:
    if not PASSWORD_MIN <= len(password) <= PASSWORD_MAX:
        raise HTTPException(status_code=422, detail=MSG_PASSWORD)


def purge_expired(conn, now: int) -> None:
    """Drop expired sessions, stale login attempts and accounts inactive for 2 years (with all their data)."""
    conn.execute("DELETE FROM sessions WHERE expires_at <= ?", (now,))
    conn.execute("DELETE FROM login_attempts WHERE attempted_at <= ?", (now - LOCKOUT_SECONDS,))
    stale = [r[0] for r in conn.execute("SELECT id FROM users WHERE last_active_at <= ?",
                                        (now - INACTIVE_SECONDS,))]
    for uid in stale:
        delete_user(conn, uid)


def delete_user(conn, user_id: int) -> None:
    conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    conn.execute("DELETE FROM user_data WHERE user_id = ?", (user_id,))
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))


def _new_session(conn, user_id: int, now: int) -> dict:
    token = secrets.token_urlsafe(32)
    conn.execute("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
                 (_token_hash(token), user_id, now, now + SESSION_SECONDS))
    conn.execute("UPDATE users SET last_active_at = ? WHERE id = ?", (now, user_id))
    return {"token": token, "token_type": "bearer", "expires_at": now + SESSION_SECONDS}


class Credentials(BaseModel):
    email: str = Field(..., max_length=EMAIL_MAX)
    password: str = Field(..., max_length=PASSWORD_MAX)


class PasswordConfirm(BaseModel):
    password: str = Field(..., max_length=PASSWORD_MAX)


class CurrentUser(BaseModel):
    id: int
    email: str
    token_hash: str


def current_user(creds: Optional[HTTPAuthorizationCredentials] = Depends(_bearer)) -> CurrentUser:
    """Resolve `Authorization: Bearer <token>` to the user; 401 if missing, unknown or expired."""
    if creds is None or creds.scheme.lower() != "bearer" or not 1 <= len(creds.credentials) <= 128:
        raise HTTPException(status_code=401, detail=MSG_AUTH, headers={"WWW-Authenticate": "Bearer"})
    th = _token_hash(creds.credentials)
    now = _now()
    with database.get_db() as conn:
        row = conn.execute("SELECT s.token_hash, s.expires_at, u.id, u.email, u.last_active_at FROM sessions s "
                           "JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?", (th,)).fetchone()
        if row is None or not hmac.compare_digest(row["token_hash"], th):
            raise HTTPException(status_code=401, detail=MSG_AUTH, headers={"WWW-Authenticate": "Bearer"})
        if row["expires_at"] <= now:
            conn.execute("DELETE FROM sessions WHERE token_hash = ?", (th,))
            conn.commit()
            raise HTTPException(status_code=401, detail=MSG_AUTH, headers={"WWW-Authenticate": "Bearer"})
        if row["last_active_at"] < now - 86400:   # at most one write per day per user
            conn.execute("UPDATE users SET last_active_at = ? WHERE id = ?", (now, row["id"]))
            conn.commit()
    return CurrentUser(id=row["id"], email=row["email"], token_hash=th)


@router.post("/auth/register", status_code=201)
def register(body: Credentials):
    """Create an account and return a session token."""
    email = normalize_email(body.email)
    _check_password_rules(body.password)
    pw_hash = hash_password(body.password)
    now = _now()
    with database.get_db() as conn:
        purge_expired(conn, now)
        try:
            cur = conn.execute("INSERT INTO users (email, password_hash, created_at, last_active_at) "
                               "VALUES (?, ?, ?, ?)", (email, pw_hash, now, now))
        except sqlite3.IntegrityError:
            conn.commit()
            raise HTTPException(status_code=409, detail=MSG_REGISTER)
        session = _new_session(conn, cur.lastrowid, now)
        conn.commit()
    return {**session, "email": email}


@router.post("/auth/login")
def login(body: Credentials):
    """Exchange email + password for a session token. 401 (generic) on failure, 429 after 5 failures/15 min."""
    email = body.email.strip().lower()[:EMAIL_MAX]
    now = _now()
    with database.get_db() as conn:
        purge_expired(conn, now)
        failed = conn.execute("SELECT COUNT(*) FROM login_attempts WHERE email = ? AND attempted_at > ?",
                              (email, now - LOCKOUT_SECONDS)).fetchone()[0]
        if failed >= MAX_FAILED:
            conn.commit()
            raise HTTPException(status_code=429, detail=MSG_LOCKED)
        user = conn.execute("SELECT id, password_hash FROM users WHERE email = ?", (email,)).fetchone()
        if not check_password(body.password, user["password_hash"] if user else None):
            conn.execute("INSERT INTO login_attempts (email, attempted_at) VALUES (?, ?)", (email, now))
            conn.commit()
            raise HTTPException(status_code=401, detail=MSG_BAD_LOGIN)
        conn.execute("DELETE FROM login_attempts WHERE email = ?", (email,))
        session = _new_session(conn, user["id"], now)
        conn.commit()
    return {**session, "email": email}


@router.post("/auth/logout", status_code=204)
def logout(user: CurrentUser = Depends(current_user)):
    """Revoke the current session token."""
    with database.get_db() as conn:
        conn.execute("DELETE FROM sessions WHERE token_hash = ?", (user.token_hash,))
        conn.commit()
    return Response(status_code=204)


@router.get("/me")
def me(user: CurrentUser = Depends(current_user)):
    with database.get_db() as conn:
        row = conn.execute("SELECT email, created_at, last_active_at FROM users WHERE id = ?",
                           (user.id,)).fetchone()
    return dict(row)


@router.delete("/me", status_code=204)
def delete_account(body: PasswordConfirm, user: CurrentUser = Depends(current_user)):
    """Delete the account and all its data; the password must be re-entered."""
    with database.get_db() as conn:
        row = conn.execute("SELECT password_hash FROM users WHERE id = ?", (user.id,)).fetchone()
        if row is None or not check_password(body.password, row["password_hash"]):
            raise HTTPException(status_code=403, detail="Mật khẩu không đúng.")
        delete_user(conn, user.id)
        conn.commit()
    return Response(status_code=204)


@router.get("/privacy")
def privacy():
    """Privacy policy (Vietnamese): what is stored, for how long, how to delete it."""
    return PRIVACY_POLICY
