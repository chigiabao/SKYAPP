"""Render demo packaging checks; no network, real DB writes, or model training."""
from datetime import timedelta
import json
from pathlib import Path
from unittest.mock import Mock

import pytest

import ai_model
import database
import ingest
from scripts import check_serving_models as check
from test_ingest import FakeAPI, NOW, NOW_HOUR, _q

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("configured, expected", [(None, 90), ("3", 3)])
def test_empty_database_backfill_is_bounded(tmp_path, monkeypatch, configured, expected):
    path = tmp_path / "weather.db"
    conn = ingest.connect(path)
    conn.close()
    api = FakeAPI()
    monkeypatch.delenv("INGEST_BACKFILL_DAYS", raising=False)
    if configured is not None:
        monkeypatch.setenv("INGEST_BACKFILL_DAYS", configured)
    monkeypatch.setenv("EXTERNAL_FORECAST_ENABLED", "0")
    monkeypatch.setattr(ingest, "_get_json", api)
    monkeypatch.setattr(ingest, "_post_ingest", lambda *args: None)
    row = ingest.run_ingest(db_path=path, now=NOW)
    assert row["status"] == "ok", row["message"]
    hours = _q(path, "SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM hourly_weather")[0]
    assert hours == (expected * 24 + 1, (ingest.current_hour(NOW) -
                    timedelta(days=expected)).strftime(ingest.TS_FMT), NOW_HOUR)
    assert len(ai_model.load_history_from_db(str(path))) == ai_model.MIN_HISTORY_HOURS
    assert _q(path, "SELECT COUNT(*) FROM nwp_forecast")[0][0] == 0


@pytest.mark.parametrize("configured", ["", "bad", "2", "91", "-1", "3.5"])
def test_invalid_backfill_never_calls_network_or_changes_weather(tmp_path, monkeypatch, configured):
    path = tmp_path / "weather.db"
    monkeypatch.setenv("INGEST_BACKFILL_DAYS", configured)
    request = Mock()
    monkeypatch.setattr(ingest, "_get_json", request)
    row = ingest.run_ingest(db_path=path, now=NOW)
    assert row["status"] == "error"
    assert _q(path, "SELECT COUNT(*) FROM hourly_weather")[0][0] == 0
    request.assert_not_called()


def test_render_cold_start_covers_all_series_then_keeps_revision_overlap(tmp_path, monkeypatch):
    path = tmp_path / "weather.db"
    monkeypatch.setattr(database, "DATABASE_PATH", path)
    database.init_db()
    api = FakeAPI()

    def batch_api(url, params):
        payload = api(url, params)
        count = len(str(params["latitude"]).split(","))
        return payload if count == 1 else [payload] * count

    monkeypatch.setenv("INGEST_BACKFILL_DAYS", "3")
    monkeypatch.setenv("EXTERNAL_FORECAST_ENABLED", "0")
    monkeypatch.setattr(ingest, "_get_json", batch_api)
    monkeypatch.setattr(ingest, "_throttle", lambda *args: None)
    monkeypatch.setattr(ingest, "_post_ingest", lambda *args: None)
    row = ingest.run_ingest(db_path=path, now=NOW)
    assert row["status"] == "ok", row["message"]
    assert (row["cells_ok"], row["cells_failed"]) == (67, 0)
    assert _q(path, "SELECT COUNT(DISTINCT location_id), COUNT(*), MAX(timestamp) FROM hourly_weather")[0] == (
        67, 67 * 73, NOW_HOUR)
    api.calls.clear()
    again = ingest.run_ingest(db_path=path, now=NOW)
    assert (again["rows_inserted"], again["rows_updated"]) == (0, 0)
    historical = [p for kind, p in api.calls if kind == "historical"]
    assert sum(len(str(p["latitude"]).split(",")) for p in historical) == 67
    assert all(p["start_date"] == (NOW - timedelta(hours=48)).date().isoformat() for p in historical)


@pytest.fixture
def packaged_models(monkeypatch):
    cells = json.loads((ROOT / "data/locations/cells.json").read_text(encoding="utf-8"))
    static = {ai_model.canonical_cell_id(c["cell_id"]): {} for c in cells}
    meta = {"model_version": "synthetic-long", "cell_static": static}
    monkeypatch.setattr(check.ai_model, "_v3", {"meta": {"model_version": "synthetic-v3"},
                                               "static": static, "ext": {"synthetic": True}})
    monkeypatch.setattr(check.ai_model, "_load_v3", lambda: True)
    monkeypatch.setattr(check.long_range, "_load", lambda *args: (meta, dict.fromkeys(check.long_range.TARGETS), {}, {}))
    monkeypatch.setattr(check.long_range, "interval_layer", lambda *args: {"synthetic": True})
    return meta


def test_packaged_models_cover_all_weather_series(packaged_models):
    assert check.check_models() == {"v3": "synthetic-v3", "long_range": "synthetic-long", "cells": 67}


def test_model_check_fails_closed_when_v3_missing(monkeypatch):
    monkeypatch.setattr(check.ai_model, "_load_v3", lambda: False)
    monkeypatch.setattr(check.ai_model, "_v3", {"error": "missing artifact"})
    with pytest.raises(RuntimeError, match="Global V3"):
        check.check_models()


@pytest.mark.parametrize("missing", ["extension", "intervals", "cells", "targets"])
def test_model_check_rejects_partial_package(packaged_models, monkeypatch, missing):
    if missing == "extension":
        check.ai_model._v3["ext"] = None
    elif missing == "intervals":
        monkeypatch.setattr(check.long_range, "interval_layer", lambda *args: None)
    elif missing == "cells":
        packaged_models["cell_static"] = {}
    else:
        monkeypatch.setattr(check.long_range, "_load", lambda *args: (packaged_models, {}, {}, {}))
    with pytest.raises(RuntimeError):
        check.check_models()


def test_render_dockerfile_packages_serving_artifacts_without_private_state():
    docker = (ROOT / "Dockerfile.render").read_text(encoding="utf-8")
    ignore = (ROOT / "Dockerfile.render.dockerignore").read_text(encoding="utf-8")
    assert 'CMD ["python", "main.py"]' in docker
    assert "RUN python scripts/check_serving_models.py" in docker
    for setting in ("INGEST_BACKFILL_DAYS=3", "EXTERNAL_FORECAST_ENABLED=0", "MAINTENANCE_ENABLED=0",
                    "OMP_NUM_THREADS=1", "OPENBLAS_NUM_THREADS=1", "MKL_NUM_THREADS=1"):
        assert setting in docker
    for folder in ("models/v3", "models/long_range_v2", "models/long_range_v2_intervals"):
        assert f"COPY --chown=app:app {folder} /app/{folder}" in docker
        assert f"!{folder}/" in ignore.splitlines()
        assert f"{folder}/*" in ignore.splitlines()
    for excluded in ("*.db", "data/history/", ".env", ".env.*", "tests/"):
        assert excluded in ignore.splitlines()
    assert "COPY --chown=app:app . /app" not in docker
    assert "models/" in (ROOT / ".dockerignore").read_text().splitlines()


def test_render_model_allowlist_is_exact_and_contains_no_training_or_experimental_artifacts():
    horizons = (1, 3, 6)
    legacy = {"models/feature_columns.json", "models/model_metadata.json"} | {
        f"models/{target}_model_{h}h.pkl" for h in horizons for target in ("temperature", "rain")}
    v3 = {f"models/v3/{name}.json" for name in (
        "feature_columns", "cell_static", "metadata_v3", "serving_policy_v3", "extension_v3", "evaluation_v3")} | {
        f"models/v3/{target}_model_{h}h.pkl" for h in horizons for target in (
            "temperature", "rain", "temperature_q05", "temperature_q95",
            "humidity", "wind_speed", "wind_gusts", "precipitation_mm")}
    long_range = {f"models/long_range_v2/{name}.json" for name in (
        "metadata", "climatology", "serving_policy", "evaluation")} | {
        f"models/long_range_v2/{target}{suffix}.txt"
        for target in ("temperature", "humidity", "precipitation_mm", "wind_speed", "cloud_cover", "rain_probability")
        for suffix in ("", "_short")}
    intervals = {f"models/long_range_v2_intervals/{name}.json" for name in ("metadata", "intervals")}
    expected = legacy | v3 | long_range | intervals
    rules = (ROOT / "Dockerfile.render.dockerignore").read_text(encoding="utf-8").splitlines()
    allowed = {rule[1:] for rule in rules if rule.startswith("!")}
    parents = {"models/v3/", "models/long_range_v2/", "models/long_range_v2_intervals/"}
    assert allowed == expected | parents
    assert "models/*" in rules
    assert all((ROOT / name).is_file() for name in expected)
    docker = (ROOT / "Dockerfile.render").read_text(encoding="utf-8")
    assert "models/*.json" not in docker and "models/*.pkl" not in docker
    assert all(name in docker for name in legacy)
