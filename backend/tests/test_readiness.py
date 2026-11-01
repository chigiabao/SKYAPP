"""Readiness is weather availability, not just a working process or SQLite file."""
from datetime import datetime, timedelta
import os
import sqlite3
from pathlib import Path
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

import ai_model
import database
import main
from conftest import point_app_at
from database import LOCAL_TZ
from models import CellsHealth

NOW = datetime(2026, 10, 21, 18, tzinfo=LOCAL_TZ)
CELL = ai_model.canonical_cell_id(main.DEFAULT_LOCATION_ID)


def available_model():
    return {'status': 'available', 'trained_through': '2024-12-24T23:00:00+07:00',
            'cell_ids': [CELL], 'capabilities': {'temperature': {'status': 'available'}}}


def history(latest=NOW):
    return [[(latest - timedelta(hours=i)).isoformat(), 27.0] for i in range(48)]


@pytest.fixture(autouse=True)
def no_forecast_side_effects(monkeypatch):
    def unexpected(*args, **kwargs):
        pytest.fail('Health probes must not initialize, ingest, infer or warm climatology')

    monkeypatch.setattr(main, 'init_db', unexpected)
    monkeypatch.setattr(main, '_ingest_loop', unexpected)
    monkeypatch.setattr(main.weather_climatology, '_climatology', unexpected)
    monkeypatch.setattr(main.long_range_model, 'predict', unexpected)


@pytest.fixture
def ready_client(tmp_path, monkeypatch):
    path = tmp_path / 'health.db'
    path.touch()
    point_app_at(monkeypatch, path)
    monkeypatch.setattr(main, 'now_local', lambda: NOW)
    monkeypatch.setattr(main, 'execute_one', lambda query, *args:
                        [NOW.isoformat()] if 'MAX(timestamp)' in query else None)
    monkeypatch.setattr(main, 'execute_query', lambda *args: history())
    monkeypatch.setattr(main, '_cells_health', lambda now: CellsHealth(
        total=2, fresh=2, fresh_hours=3, stale=[]))
    monkeypatch.setattr(main.long_range_model, 'status', available_model)
    return TestClient(main.app)


def test_live_is_independent_of_forecast_readiness(ready_client, monkeypatch):
    monkeypatch.setattr(main.long_range_model, 'status', lambda: {'status': 'unavailable'})
    assert ready_client.get('/live').json() == {'status': 'alive'}
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert 'forecast_model_unavailable' in response.json()['reasons']


def test_fresh_complete_history_and_model_are_ready(ready_client):
    response = ready_client.get('/ready')
    assert response.status_code == 200
    assert response.json()['ready'] is True
    assert response.json()['reasons'] == []
    assert ready_client.get('/health').json()['status'] == 'healthy'


@pytest.mark.parametrize('age', [42, 3.001, -2, -0.5])
def test_stale_or_future_default_series_is_not_healthy(ready_client, monkeypatch, age):
    latest = NOW - timedelta(hours=age)
    monkeypatch.setattr(main, 'execute_one', lambda query, *args:
                        [latest.isoformat()] if 'MAX(timestamp)' in query else None)
    assert ready_client.get('/health').json()['status'] == 'degraded'
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert 'weather_stale_or_future' in response.json()['reasons']


def test_partial_region_freshness_is_not_ready(ready_client, monkeypatch):
    monkeypatch.setattr(main, '_cells_health', lambda now: CellsHealth(
        total=68, fresh=0, fresh_hours=3, stale=[]))
    body = ready_client.get('/ready').json()
    assert body['ready'] is False
    assert 'incomplete_fresh_coverage' in body['reasons']


def test_insufficient_contiguous_model_input_is_not_ready(ready_client, monkeypatch):
    monkeypatch.setattr(main, 'execute_query', lambda *args: history()[:1])
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert 'forecast_history_incomplete' in response.json()['reasons']


def test_input_before_selection_cutoff_is_not_ready(ready_client, monkeypatch):
    model = available_model()
    model['trained_through'] = NOW.isoformat()
    monkeypatch.setattr(main.long_range_model, 'status', lambda: model)
    body = ready_client.get('/ready').json()
    assert body['ready'] is False
    assert 'forecast_input_before_training_cutoff' in body['reasons']


def test_liveness_never_touches_database_or_models(ready_client, monkeypatch):
    unexpected = Mock(side_effect=AssertionError('liveness dependency accessed'))
    for name in ('execute_one', 'execute_query', '_cells_health'):
        monkeypatch.setattr(main, name, unexpected)
    monkeypatch.setattr(main.long_range_model, 'status', unexpected)
    assert ready_client.get('/live').json() == {'status': 'alive'}
    unexpected.assert_not_called()


@pytest.mark.parametrize('latest', [None, NOW - timedelta(hours=42)])
def test_unusable_weather_does_not_load_models_or_history(ready_client, monkeypatch, latest):
    monkeypatch.setattr(main, 'execute_one', lambda query, *args:
                        [latest.isoformat() if latest else None] if 'MAX(timestamp)' in query else None)
    unexpected = Mock(side_effect=AssertionError('unnecessary forecast work'))
    monkeypatch.setattr(main.long_range_model, 'status', unexpected)
    monkeypatch.setattr(main, 'execute_query', unexpected)
    for endpoint in ('/health', '/ready'):
        response = ready_client.get(endpoint)
        assert response.status_code == (200 if endpoint == '/health' else 503)
        assert response.json()['status'] == 'degraded'
        assert response.json()['model_status'] == 'not_checked'
    unexpected.assert_not_called()


@pytest.mark.parametrize('cells', [None, CellsHealth(total=0, fresh=0, fresh_hours=3, stale=[])])
def test_missing_or_empty_coverage_cannot_be_ready(ready_client, monkeypatch, cells):
    monkeypatch.setattr(main, '_cells_health', lambda now: cells)
    response = ready_client.get('/ready')
    assert response.status_code == 503
    expected = 'fresh_coverage_unavailable' if cells is None else 'incomplete_fresh_coverage'
    assert expected in response.json()['reasons']


@pytest.mark.parametrize('problem', ['gap', 'duplicate', 'half_hour', 'invalid_timestamp'])
def test_invalid_history_never_loads_model(ready_client, monkeypatch, problem):
    rows = history()
    if problem == 'gap':
        rows[-1][0] = (NOW - timedelta(hours=49)).isoformat()
    elif problem == 'duplicate':
        rows[-1][0] = rows[-2][0]
    elif problem == 'half_hour':
        rows[-1][0] = (NOW - timedelta(hours=47, minutes=30)).isoformat()
    else:
        rows[-1][0] = 'not-a-time'
    monkeypatch.setattr(main, 'execute_query', lambda *args: rows)
    unexpected = Mock(side_effect=AssertionError('invalid history must not load model'))
    monkeypatch.setattr(main.long_range_model, 'status', unexpected)
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert any(reason.startswith('forecast_history_') for reason in response.json()['reasons'])
    unexpected.assert_not_called()


@pytest.mark.parametrize('temperature', [None, float('nan'), float('inf'), -float('inf'), 'invalid'])
def test_nonfinite_temperature_is_not_ready(ready_client, monkeypatch, temperature):
    rows = history()
    rows[-1][1] = temperature
    monkeypatch.setattr(main, 'execute_query', lambda *args: rows)
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert 'forecast_history_invalid' in response.json()['reasons']


@pytest.mark.parametrize('problem,reason', [
    ('cell', 'forecast_cell_unsupported'),
    ('temperature', 'forecast_temperature_unsupported'),
    ('cutoff', 'forecast_training_cutoff_unknown'),
])
def test_model_must_support_served_forecast(ready_client, monkeypatch, problem, reason):
    model = available_model()
    if problem == 'cell':
        model['cell_ids'] = ['other-cell']
    elif problem == 'temperature':
        model['capabilities']['temperature']['status'] = 'unsupported'
    else:
        model.pop('trained_through')
    monkeypatch.setattr(main.long_range_model, 'status', lambda: model)
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert reason in response.json()['reasons']


@pytest.fixture
def sqlite_client(tmp_path, monkeypatch):
    path = tmp_path / 'sqlite-health.db'
    point_app_at(monkeypatch, path)
    monkeypatch.setattr(main, 'now_local', lambda: NOW)
    monkeypatch.setattr(main.long_range_model, 'status', available_model)
    with sqlite3.connect(path) as con:
        database.migrate(con)
        con.execute('INSERT INTO cells (cell_id, series_id, lat, lon) VALUES (?, ?, ?, ?)',
                    (CELL, main.DEFAULT_LOCATION_ID, 10.79, 106.63))
        con.executemany('INSERT INTO hourly_weather (timestamp, temperature, location_id) VALUES (?, ?, ?)',
                        [(database.to_local(ts).strftime('%Y-%m-%d %H:%M:%S'), temp, main.DEFAULT_LOCATION_ID)
                         for ts, temp in history()])
    return TestClient(main.app), path


def test_real_sqlite_fresh_history_is_ready_and_read_only(sqlite_client):
    client, path = sqlite_client
    before = path.read_bytes()
    assert client.get('/health').json()['status'] == 'healthy'
    assert client.get('/ready').status_code == 200
    assert path.read_bytes() == before


def test_wal_database_stays_unmodified_by_readiness_reads(sqlite_client):
    client, path = sqlite_client
    con = sqlite3.connect(path)
    assert con.execute('PRAGMA journal_mode=WAL').fetchone()[0] == 'wal'
    con.close()
    before = path.read_bytes()
    assert client.get('/health').json()['status'] == 'healthy'
    assert client.get('/ready').status_code == 200
    wal = Path(str(path) + '-wal')
    assert path.read_bytes() == before
    assert not wal.exists() or wal.stat().st_size == 0   # no committed frames either


def test_init_db_enables_persistent_wal(tmp_path, monkeypatch):
    path = tmp_path / 'fresh.db'
    monkeypatch.setattr(database, 'DATABASE_PATH', path)
    database.init_db()
    con = sqlite3.connect(path)   # a new connection reads the mode stored in the file
    try:
        assert con.execute('PRAGMA journal_mode').fetchone()[0] == 'wal'
    finally:
        con.close()


def test_database_revision_ignores_reads_but_tracks_commits(tmp_path):
    path = tmp_path / 'rev.db'
    con = sqlite3.connect(path)
    con.execute('PRAGMA journal_mode=WAL')
    with con:
        con.execute('CREATE TABLE t (a)')
    con.close()
    wal = Path(str(path) + '-wal')
    # Give the stat-only fallback distinct write times even on Windows' coarse clock.
    stamp = path.stat()
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns - 1_000_000_000))
    idle = database.database_revision(path)
    assert not wal.exists()
    reader = sqlite3.connect(path)   # a reader recreates an empty -wal with a fresh mtime
    reader.execute('SELECT COUNT(*) FROM t').fetchone()
    assert wal.exists() and database.database_revision(path) == idle
    writer = sqlite3.connect(path)
    with writer:
        writer.execute('INSERT INTO t VALUES (1)')
    committed = database.database_revision(path)   # frame sits in the -wal while the reader is open
    assert committed != idle
    writer.close()
    reader.close()   # last close checkpoints into the main file
    assert database.database_revision(path) != idle


def test_weather_data_revision_tracks_only_hourly_weather(tmp_path):
    path = tmp_path / 'rev.db'
    con = sqlite3.connect(path)   # a DB from before the counter: plain table with one hour
    con.execute('CREATE TABLE hourly_weather (timestamp TEXT, temperature REAL)')
    con.execute("INSERT INTO hourly_weather VALUES ('2024-01-01 00:00:00', 1)")
    con.commit()
    assert database.weather_data_revision(path)[0] == 'file'   # unmigrated: safe file-stat fallback
    database.migrate(con)
    database.migrate(con)   # idempotent: one counter row, triggers not duplicated
    assert con.execute('SELECT COUNT(*) FROM data_revision').fetchone()[0] == 1
    start = database.weather_data_revision(path)
    assert start[0] == 'rows'
    with con:   # unrelated writers
        con.execute("INSERT INTO feedback (created_at, kind) VALUES ('2024-01-01', 'bug')")
        con.execute("INSERT INTO api_call_log (day, service, calls) VALUES ('2024-01-01', 'osrm', 1)")
        con.execute('INSERT INTO login_attempts VALUES (?, ?)', ('x', 1))
        con.execute("INSERT INTO air_quality (location_id, timestamp) VALUES ('tsn', '2024-01-01 00:00:00')")
    assert database.weather_data_revision(path) == start
    revisions = [start]
    for sql in ("UPDATE hourly_weather SET temperature = 2 WHERE timestamp = '2024-01-01 00:00:00'",
                "INSERT INTO hourly_weather (timestamp, temperature) VALUES ('2024-01-01 01:00:00', 3)",
                "INSERT INTO hourly_weather (timestamp, temperature) VALUES ('2024-01-01 01:00:00', 4) "
                "ON CONFLICT(location_id, timestamp) DO UPDATE SET temperature = excluded.temperature",
                "DELETE FROM hourly_weather WHERE timestamp = '2024-01-01 01:00:00'"):
        with con:
            con.execute(sql)
        revisions.append(database.weather_data_revision(path))
    assert len(set(revisions)) == len(revisions)
    con.close()


def test_weather_revision_tracks_commits_with_identical_file_timestamps(tmp_path):
    path = tmp_path / 'same-time.db'
    con = sqlite3.connect(path)
    con.execute('CREATE TABLE hourly_weather (timestamp TEXT, temperature REAL)')
    database.migrate(con)
    con.execute("INSERT INTO hourly_weather (timestamp, temperature) VALUES ('2024-01-01 00:00:00', 1)")
    con.commit()
    stamp = path.stat()
    before = database.weather_data_revision(path)
    with con:
        con.execute('UPDATE hourly_weather SET temperature = 2')
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    assert path.stat().st_mtime_ns == stamp.st_mtime_ns
    assert database.weather_data_revision(path) != before
    con.close()


def test_cell_freshness_uses_indexed_lookups_not_weather_scan(sqlite_client, monkeypatch):
    client, _ = sqlite_client
    queries = []

    def capture(query, params=()):
        queries.append((query, params))
        return database.execute_query(query, params)

    monkeypatch.setattr(main, 'execute_query', capture)
    assert client.get('/ready').status_code == 200
    cell_query, params = next((q, p) for q, p in queries if 'FROM cells ORDER BY cell_id' in q)
    plan = database.execute_query('EXPLAIN QUERY PLAN ' + cell_query, params)
    details = ' '.join(row[3] for row in plan)
    assert 'ux_hourly_location_ts' in details
    assert 'SCAN hourly_weather' not in details
    assert all('GROUP BY' not in query for query, _ in queries)
    history_query, params = next((q, p) for q, p in queries if 'SELECT timestamp, temperature' in q)
    assert 'LIMIT ?' in history_query
    assert params == (main.DEFAULT_LOCATION_ID, main.long_range_model.MIN_HISTORY_HOURS)


@pytest.mark.parametrize('age,ready', [(3, True), (3.001, False), (-0.5, False)])
def test_sqlite_freshness_boundary(sqlite_client, age, ready):
    client, path = sqlite_client
    with sqlite3.connect(path) as con:
        con.execute('DELETE FROM hourly_weather')
        latest = NOW - timedelta(hours=age)
        con.executemany('INSERT INTO hourly_weather (timestamp, temperature, location_id) VALUES (?, ?, ?)',
                        [(database.to_local(ts).strftime('%Y-%m-%d %H:%M:%S'), temp, main.DEFAULT_LOCATION_ID)
                         for ts, temp in history(latest)])
    response = client.get('/ready')
    assert response.status_code == (200 if ready else 503)
    assert response.json()['cells']['fresh'] == (1 if ready else 0)


@pytest.mark.parametrize('state', ['missing', 'empty', 'corrupt'])
def test_unusable_sqlite_returns_degraded_without_creating_database(tmp_path, monkeypatch, state):
    path = tmp_path / 'unusable.db'
    if state != 'missing':
        path.write_bytes(b'not sqlite' if state == 'corrupt' else b'')
    point_app_at(monkeypatch, path)
    unexpected = Mock(side_effect=AssertionError('unusable DB must not load model'))
    monkeypatch.setattr(main.long_range_model, 'status', unexpected)
    client = TestClient(main.app)
    response = client.get('/ready')
    assert response.status_code == 503
    assert response.json()['database'] == ('missing' if state == 'missing' else 'unavailable')
    assert client.get('/health').status_code == 200
    assert client.get('/live').json() == {'status': 'alive'}
    if state == 'missing':
        assert not path.exists()
    unexpected.assert_not_called()


@pytest.mark.parametrize('stage', ['latest', 'cells', 'history'])
def test_database_errors_fail_readiness_not_liveness(ready_client, monkeypatch, stage):
    def locked(*args, **kwargs):
        raise sqlite3.OperationalError('database is locked')

    target = {'latest': 'execute_one', 'cells': '_cells_health', 'history': 'execute_query'}[stage]
    monkeypatch.setattr(main, target, locked)
    response = ready_client.get('/ready')
    assert response.status_code == 503
    assert 'database_unavailable' in response.json()['reasons']
    assert ready_client.get('/health').json()['status'] == 'degraded'
    assert ready_client.get('/live').status_code == 200


@pytest.mark.parametrize('stage', ['cells', 'series_status'])
def test_cell_query_lock_is_not_treated_as_a_legacy_schema(sqlite_client, monkeypatch, stage):
    client, _ = sqlite_client

    def query(sql, params=()):
        if ('FROM cells' if stage == 'cells' else 'FROM series_status') in sql:
            raise sqlite3.OperationalError('database is locked')
        return database.execute_query(sql, params)

    monkeypatch.setattr(main, 'execute_query', query)
    response = client.get('/ready')
    assert response.status_code == 503
    assert response.json()['database'] == 'unavailable'
    assert 'database_unavailable' in response.json()['reasons']
    assert client.get('/live').status_code == 200


def test_legacy_single_series_health_stays_compatible(tmp_path, monkeypatch):
    path = tmp_path / 'legacy.db'
    point_app_at(monkeypatch, path)
    with sqlite3.connect(path) as con:
        con.execute('CREATE TABLE hourly_weather (timestamp TEXT, temperature REAL)')
        con.execute('INSERT INTO hourly_weather VALUES (?, ?)', (NOW.isoformat(), 27.0))
    client = TestClient(main.app)
    monkeypatch.setattr(main, 'now_local', lambda: NOW)
    body = client.get('/health').json()
    assert body['database'] == 'ok'
    assert body['latest_timestamp'] == NOW.isoformat()
    assert body['last_ingest'] is None
    assert body['cells'] is None
    assert body['status'] == 'degraded'
    assert client.get('/ready').status_code == 503


def test_missing_optional_ingest_tables_do_not_block_valid_forecast(sqlite_client):
    client, path = sqlite_client
    with sqlite3.connect(path) as con:
        con.execute('DROP TABLE ingest_log')
        con.execute('DROP TABLE series_status')
    response = client.get('/ready')
    assert response.status_code == 200
    assert response.json()['last_ingest'] is None


@pytest.mark.parametrize('series', [main.DEFAULT_LOCATION_ID, 'other'])
def test_malformed_weather_timestamp_degrades_instead_of_crashing(sqlite_client, series):
    client, path = sqlite_client
    with sqlite3.connect(path) as con:
        if series == 'other':
            con.execute('INSERT INTO cells (cell_id, series_id, lat, lon) VALUES (?, ?, ?, ?)',
                        ('other', 'other', 10.8, 106.7))
        con.execute('INSERT INTO hourly_weather (timestamp, location_id) VALUES (?, ?)',
                    ('not-a-time', series))
    response = client.get('/ready')
    assert response.status_code == 503
    assert 'weather_invalid' in response.json()['reasons']
    assert client.get('/live').status_code == 200
