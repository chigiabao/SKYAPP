"""The API must start before the first weather ingestion, without invented readings."""
import sqlite3

import pytest
from fastapi.testclient import TestClient

import database
import main
from conftest import point_app_at
from routers import weather_climatology


@pytest.mark.parametrize("existing", [False, True])
def test_start_without_weather(tmp_path, monkeypatch, existing):
    path = tmp_path / "new-install" / "weather.db"
    if existing:
        path.parent.mkdir()
        with sqlite3.connect(path) as conn:
            database.migrate(conn)
    point_app_at(monkeypatch, path)

    def unexpected_warmup():
        pytest.fail("An empty weather table cannot warm climatology")

    monkeypatch.setattr(weather_climatology, "_climatology", unexpected_warmup)
    with TestClient(main.app) as client:
        assert path.exists()
        body = client.get("/health").json()
        assert body["status"] == "degraded"
        assert body["database"] == "ok"
        assert body["latest_timestamp"] is None
        assert body["data_age_hours"] is None
        assert body["cells"]["fresh"] == 0
        assert len(client.get("/locations").json()) == 169
        assert client.get("/weather/current").status_code == 404


def test_existing_weather_still_warms_climatology(syn_db, monkeypatch):
    warmed = []
    monkeypatch.setattr(weather_climatology, "_climatology", lambda: warmed.append(True))
    with TestClient(main.app) as client:
        assert warmed == [True]
        assert client.get("/health").json()["database"] == "ok"
        assert client.get("/live").json()["status"] == "alive"
        assert client.get("/ready").status_code == 503
