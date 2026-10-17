"""Optional accounts (routers/auth.py) and cross-device sync / privacy endpoints (routers/sync.py)."""
import hashlib
import sqlite3

import pytest

from routers import auth

PW = "matkhau-dung-123"
PLACE = "phuong-an-dong"       # real location ids from data/locations/locations.json
PLACE2 = "dac-khu-con-dao"


class Clock:
    def __init__(self, t=1_800_000_000):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr(auth, "_now", c)
    monkeypatch.setattr(auth, "BCRYPT_ROUNDS", 4)   # fast hashing in tests
    monkeypatch.setattr(auth, "_dummy_hash", None)
    return c


@pytest.fixture
def api(client, clock):
    return client


def register(api, email="an@example.com", password=PW):
    return api.post("/auth/register", json={"email": email, "password": password})


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def doc(places=(PLACE,), **extra):
    d = {"saved_places": [{"id": p, "label": None, "custom_name": f"Chỗ {i}", "order": i}
                          for i, p in enumerate(places)],
         "settings": {"units": {"temperature": "c"}, "theme": "dark", "priority_metrics": ["rain", "uv"],
                      "alert_thresholds": {"rain_mm": 10}, "quiet_hours": {"start": "22:00", "end": "06:30"}},
         "activities": [{"name": "Chạy bộ", "weekday": 1, "time": "05:30"}]}
    d.update(extra)
    return d


def put(api, token, base_version, data):
    return api.put("/me/data", json={"base_version": base_version, "data": data}, headers=bearer(token))


# --- register / login ------------------------------------------------------------------------------------

def test_register_login_logout(api, syn_db):
    r = register(api, "  An@Example.com ")
    assert r.status_code == 201
    body = r.json()
    assert body["email"] == "an@example.com" and len(body["token"]) >= 40
    assert body["expires_at"] == auth._now() + 30 * 86400
    with sqlite3.connect(syn_db) as con:
        pw_hash, = con.execute("SELECT password_hash FROM users").fetchone()
        stored, = con.execute("SELECT token_hash FROM sessions").fetchone()
    assert pw_hash.startswith("$2") and PW not in pw_hash
    assert stored == hashlib.sha256(body["token"].encode()).hexdigest()   # only the hash is stored

    r = api.post("/auth/login", json={"email": "AN@example.com", "password": PW})
    assert r.status_code == 200
    token = r.json()["token"]
    assert api.get("/me", headers=bearer(token)).json()["email"] == "an@example.com"
    assert api.post("/auth/logout", headers=bearer(token)).status_code == 204
    assert api.get("/me", headers=bearer(token)).status_code == 401
    assert api.get("/me", headers=bearer(body["token"])).status_code == 200   # other session untouched


@pytest.mark.parametrize("email,password", [
    ("not-an-email", PW), ("a@b", PW), ("x" * 250 + "@example.com", PW), ("an@example.com", "short7!"),
    ("an@example.com", "x" * 129)])
def test_register_validation(api, email, password):
    assert register(api, email, password).status_code == 422


def test_register_duplicate(api):
    assert register(api).status_code == 201
    r = register(api, "AN@example.com")
    assert r.status_code == 409 and "email" in r.json()["detail"]


def test_wrong_password_generic_and_lockout(api, clock):
    register(api)
    wrong = api.post("/auth/login", json={"email": "an@example.com", "password": "sai-mat-khau"})
    unknown = api.post("/auth/login", json={"email": "ghost@example.com", "password": "sai-mat-khau"})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json() == {"detail": auth.MSG_BAD_LOGIN}   # no email enumeration
    for _ in range(4):
        assert api.post("/auth/login", json={"email": "an@example.com", "password": "sai"}).status_code == 401
    # 5 failures in 15 minutes: even the right password is refused
    r = api.post("/auth/login", json={"email": "an@example.com", "password": PW})
    assert r.status_code == 429 and "15 phút" in r.json()["detail"]
    # other accounts are not affected
    register(api, "binh@example.com")
    assert api.post("/auth/login", json={"email": "binh@example.com", "password": PW}).status_code == 200
    clock.t += 15 * 60 + 1
    assert api.post("/auth/login", json={"email": "an@example.com", "password": PW}).status_code == 200


def test_successful_login_resets_failures(api):
    register(api)
    for _ in range(4):
        api.post("/auth/login", json={"email": "an@example.com", "password": "sai-mat-khau"})
    assert api.post("/auth/login", json={"email": "an@example.com", "password": PW}).status_code == 200
    for _ in range(4):
        api.post("/auth/login", json={"email": "an@example.com", "password": "sai-mat-khau"})
    assert api.post("/auth/login", json={"email": "an@example.com", "password": PW}).status_code == 200


# --- tokens ----------------------------------------------------------------------------------------------

def test_token_required_and_expiry(api, clock, syn_db):
    assert api.get("/me/data").status_code == 401
    assert api.get("/me/data", headers=bearer("bogus")).status_code == 401
    assert api.get("/me/data", headers={"Authorization": "Basic abc"}).status_code == 401
    token = register(api).json()["token"]
    clock.t += 30 * 86400 - 1
    assert api.get("/me/data", headers=bearer(token)).status_code == 200
    clock.t += 1
    r = api.get("/me/data", headers=bearer(token))
    assert r.status_code == 401 and r.headers["www-authenticate"] == "Bearer"
    with sqlite3.connect(syn_db) as con:
        assert con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0   # expired session removed


def test_expired_sessions_purged_on_login(api, clock, syn_db):
    register(api, "a@example.com")
    clock.t += 31 * 86400
    register(api, "b@example.com")
    with sqlite3.connect(syn_db) as con:
        assert con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 1


def test_inactive_accounts_deleted_after_two_years(api, clock, syn_db):
    token = register(api, "old@example.com").json()["token"]
    put(api, token, 0, doc())
    clock.t += 2 * 365 * 86400 + 1
    register(api, "new@example.com")   # any login/register runs the purge
    with sqlite3.connect(syn_db) as con:
        assert [r[0] for r in con.execute("SELECT email FROM users")] == ["new@example.com"]
        assert con.execute("SELECT COUNT(*) FROM user_data").fetchone()[0] == 0


def test_cors_allows_bearer_header(api):
    r = api.options("/me/data", headers={"Origin": "https://app.example", "Access-Control-Request-Method": "PUT",
                                         "Access-Control-Request-Headers": "authorization,content-type"})
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == "*"
    assert "authorization" in r.headers["access-control-allow-headers"].lower()
    assert "access-control-allow-credentials" not in r.headers


# --- sync ------------------------------------------------------------------------------------------------

def test_sync_roundtrip_and_conflict(api):
    token = register(api).json()["token"]
    assert api.get("/me/data", headers=bearer(token)).json() == {"version": 0, "data": None, "updated_at": None}
    r = put(api, token, 0, doc())
    assert r.status_code == 200 and r.json()["version"] == 1
    got = api.get("/me/data", headers=bearer(token)).json()
    assert got["version"] == 1 and got["data"]["saved_places"][0]["id"] == PLACE
    assert got["data"]["settings"]["quiet_hours"] == {"start": "22:00", "end": "06:30"}

    # second device saves on top of v1 -> v2
    assert put(api, token, 1, doc((PLACE, PLACE2))).json()["version"] == 2
    # first device is still on v1 -> 409 with the current document to merge
    r = put(api, token, 1, doc(()))
    assert r.status_code == 409
    cur = r.json()["current"]
    assert cur["version"] == 2 and [p["id"] for p in cur["data"]["saved_places"]] == [PLACE, PLACE2]
    assert put(api, token, 0, doc()).status_code == 409   # "create" when a document already exists
    assert put(api, token, 2, doc(())).json()["version"] == 3


def test_sync_accepts_app_preferences_and_tombstones(api):
    """App >= 1.1: settings.preferences (units, home metrics), per-place alert overrides and place
    tombstones ride in `settings` (extra keys allowed) and round-trip unchanged."""
    token = register(api).json()["token"]
    d = doc()
    d["settings"].update({
        "preferences": {"version": 1, "units": {"wind": "ms", "pressure": "hpa", "precip": "mm", "distance": "km"},
                        "metricOrder": ["wind", "uv"], "hiddenMetrics": [], "textScale": 1.15,
                        "highContrast": False, "reduceMotion": True},
        "alerts": {"rainProbability": 60, "places": {PLACE: {"enabled": False, "thresholds": {"wind": 50}}}},
        "deleted_places": {PLACE2: 1_700_000_000_000},
        "places_added_at": {PLACE: 1_690_000_000_000},
    })
    assert put(api, token, 0, d).status_code == 200
    got = api.get("/me/data", headers=bearer(token)).json()["data"]["settings"]
    for k in ("preferences", "alerts", "deleted_places", "places_added_at"):
        assert got[k] == d["settings"][k]


def test_sync_rejects_fake_location_and_bad_schema(api):
    token = register(api).json()["token"]
    r = put(api, token, 0, doc((PLACE, "phuong-khong-ton-tai")))
    assert r.status_code == 422 and r.json()["detail"]["unknown_location_ids"] == ["phuong-khong-ton-tai"]
    assert put(api, token, 0, doc((PLACE, PLACE))).status_code == 422                     # duplicate place
    assert put(api, token, 0, {**doc(), "unknown_key": 1}).status_code == 422
    bad_qh = doc()
    bad_qh["settings"]["quiet_hours"] = {"start": "25:00", "end": "06:00"}
    assert put(api, token, 0, bad_qh).status_code == 422
    assert put(api, token, 0, doc(activities=[{"name": "Đi học", "lat": 10.8, "lon": 106.7}])).status_code == 422
    assert put(api, token, 0, doc(habits={"morning_run": 0.8})).status_code == 422          # no consent
    assert put(api, token, 0, doc(habits={"morning_run": 0.8}, habits_consent=True)).status_code == 200
    r = api.put("/me/data", content=b"{not json", headers={**bearer(token), "Content-Type": "application/json"})
    assert r.status_code == 422


def test_sync_size_limit(api):
    token = register(api).json()["token"]
    big = doc(activities=[{"note": "x" * 1000} for _ in range(300)])   # ~300 KB
    assert put(api, token, 0, big).status_code == 413
    assert api.get("/me/data", headers=bearer(token)).json()["version"] == 0


def test_users_cannot_see_each_other(api):
    a = register(api, "a@example.com").json()["token"]
    b = register(api, "b@example.com").json()["token"]
    put(api, a, 0, doc((PLACE,)))
    assert api.get("/me/data", headers=bearer(b)).json()["data"] is None
    assert put(api, b, 0, doc((PLACE2,))).json()["version"] == 1   # b's own document, a's untouched
    assert api.get("/me/data", headers=bearer(a)).json()["data"]["saved_places"][0]["id"] == PLACE
    assert api.delete("/me/data", headers=bearer(b)).status_code == 204
    assert api.get("/me/data", headers=bearer(a)).json()["version"] == 1
    export = api.get("/me/export", headers=bearer(b)).json()
    assert export["account"]["email"] == "b@example.com" and export["sync"]["data"] is None


# --- privacy ---------------------------------------------------------------------------------------------

def test_export(api):
    token = register(api).json()["token"]
    put(api, token, 0, doc(habits={"morning_run": 0.8}, habits_consent=True))
    r = api.get("/me/export", headers=bearer(token))
    assert r.status_code == 200
    assert "attachment" in r.headers["content-disposition"]
    body = r.json()
    assert body["account"]["email"] == "an@example.com" and len(body["sessions"]) == 1
    assert body["sync"]["data"]["habits"] == {"morning_run": 0.8}
    assert "password_hash" not in str(body) and "token_hash" not in str(body)


def test_delete_data_only(api):
    token = register(api).json()["token"]
    put(api, token, 0, doc())
    assert api.delete("/me/data", headers=bearer(token)).status_code == 204
    assert api.get("/me/data", headers=bearer(token)).json()["version"] == 0
    assert api.get("/me", headers=bearer(token)).status_code == 200


def test_delete_account(api, syn_db):
    token = register(api).json()["token"]
    put(api, token, 0, doc())
    r = api.request("DELETE", "/me", json={"password": "sai-mat-khau"}, headers=bearer(token))
    assert r.status_code == 403
    r = api.request("DELETE", "/me", json={"password": PW}, headers=bearer(token))
    assert r.status_code == 204
    assert api.get("/me", headers=bearer(token)).status_code == 401
    assert api.post("/auth/login", json={"email": "an@example.com", "password": PW}).status_code == 401
    with sqlite3.connect(syn_db) as con:
        for table in ("users", "sessions", "user_data"):
            assert con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0
    assert register(api).status_code == 201   # the email can be reused


def test_privacy_policy(api):
    r = api.get("/privacy")
    assert r.status_code == 200
    text = " ".join(r.json().values())
    assert "2 năm" in text and "30 ngày" in text and "IP" in text


def test_weather_still_public(api):
    assert api.get("/locations").status_code == 200
