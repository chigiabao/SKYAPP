"""Operational hardening: SQLite busy timeout, uvicorn entrypoint, docs toggle, admin behind proxy,
long-range input validation."""
import runpy
from pathlib import Path

import numpy as np
import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

import database
import long_range_model as M
from routers.admin import require_admin
from test_long_range_model import CELL, artifact, history  # noqa: F401  (artifact is a fixture)

MAIN = str(Path(__file__).resolve().parents[1] / "main.py")


def test_every_connection_waits_instead_of_database_locked(tmp_path, monkeypatch):
    monkeypatch.setattr(database, "DATABASE_PATH", tmp_path / "w.db")
    database.init_db()
    with database.get_db() as conn:
        assert conn.execute("PRAGMA busy_timeout").fetchone()[0] == 30000
        assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1


def _run_main(monkeypatch, **env):
    import uvicorn
    calls = []
    monkeypatch.setattr(uvicorn, "run", lambda target, **kw: calls.append((target, kw)))
    for key in ("HOST", "PORT", "RELOAD", "ENABLE_DOCS"):
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    ns = runpy.run_path(MAIN, run_name="__main__")
    return ns, calls


def test_uvicorn_defaults_to_localhost_without_reload(monkeypatch):
    ns, calls = _run_main(monkeypatch)
    target, kw = calls[0]
    assert target is ns["app"]
    assert kw == {"host": "127.0.0.1", "port": 8000, "reload": False}


def test_uvicorn_reload_uses_import_string(monkeypatch):
    _, calls = _run_main(monkeypatch, RELOAD="1", HOST="0.0.0.0", PORT="9001")
    assert calls[0] == ("main:app", {"host": "0.0.0.0", "port": 9001, "reload": True})


def test_docs_can_be_disabled(monkeypatch):
    on, _ = _run_main(monkeypatch)
    client = TestClient(on["app"])
    assert client.get("/openapi.json").status_code == 200
    off, _ = _run_main(monkeypatch, ENABLE_DOCS="0")
    client = TestClient(off["app"])
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404
    assert client.get("/").json()["docs"] is None


@pytest.fixture
def admin_app():
    app = FastAPI()

    @app.get("/x", dependencies=[Depends(require_admin)])
    def x():
        return {"ok": True}
    return TestClient(app, client=("127.0.0.1", 50000))


@pytest.mark.parametrize("header", [{"X-Forwarded-For": "203.0.113.9"}, {"X-Real-IP": "203.0.113.9"},
                                    {"Forwarded": "for=203.0.113.9"}])
def test_proxied_localhost_admin_needs_token(admin_app, monkeypatch, header):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    assert admin_app.get("/x").status_code == 200          # direct localhost still works
    assert admin_app.get("/x", headers=header).status_code == 403
    monkeypatch.setenv("ADMIN_TOKEN", "test-admin-token-0123456789abcdef")
    assert admin_app.get("/x", headers={**header, "X-Admin-Token": "test-admin-token-0123456789abcdef"}).status_code == 200


@pytest.mark.parametrize("column", ["humidity", "precipitation", "wind_speed", "cloud_cover", "pressure_msl"])
def test_non_finite_feature_history_is_rejected(artifact, column):  # noqa: F811
    hist = history()
    hist.loc[94, column] = np.nan
    with pytest.raises(ValueError, match=f"^invalid_history: .*{column}"):
        M.predict(hist, CELL)
    with pytest.raises(ValueError, match=f"^invalid_history: .*{column}"):
        M.predict(hist.drop(columns=[column]), CELL)
