"""Network-free ingestion quality checks and scheduler recovery regressions."""
from datetime import datetime, timedelta
from threading import Event, current_thread
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

import ingest
import main
from database import LOCAL_TZ
from test_ingest import NOW, _q, _snapshot, db as db  # reuse the isolated synthetic DB fixture


@pytest.fixture(autouse=True)
def scheduler_state(monkeypatch):
    monkeypatch.setattr(main, '_scheduler_state', {
        'state': 'not_started', 'last_attempt_at': None, 'last_finished_at': None,
        'last_outcome': None, 'next_run_at': None, 'consecutive_failures': 0,
    })


def payload(value=27, times=None):
    return {'hourly': {'time': times or ['2023-06-25T10:00'], 'temperature_2m': [value]}}


@pytest.mark.parametrize('value', [float('nan'), float('inf'), -float('inf'), '1e999', True])
def test_nonfinite_or_boolean_values_are_rejected(value):
    with pytest.raises(ValueError):
        ingest.parse_hourly(payload(value))


@pytest.mark.parametrize('bad', [
    [], {'hourly': 'bad'}, {'hourly': {'time': 'bad'}},
    payload(times=[10]), payload(times=['bad']), payload(times=['2023-06-25T10:30']),
    {'hourly': {'time': ['2023-06-25T10:00'], 'temperature_2m': []}},
    {'hourly': {'time': ['2023-06-25T10:00'], 'temperature_2m': [1, 2]}},
    {'hourly': {'time': ['2023-06-25T10:00'], 'temperature_2m': '27'}},
])
def test_malformed_hourly_payload_is_rejected(bad):
    with pytest.raises((ValueError, TypeError)):
        ingest.parse_hourly(bad)


def test_equivalent_timestamps_are_duplicates_after_timezone_normalization():
    with pytest.raises(ValueError, match='duplicate'):
        ingest.parse_hourly({'hourly': {
            'time': ['2023-06-25T10:00', '2023-06-25T03:00:00+00:00'],
            'temperature_2m': [27, 28],
        }})


def test_null_optional_values_remain_missing_and_zero_is_preserved():
    row = ingest.parse_hourly(payload(0))[0]
    assert row['temperature'] == 0
    assert row['humidity'] is None
    assert ingest.parse_hourly(payload(None)) == []
    assert ingest.parse_hourly(payload(times=['2023-06-25T03:00:00+00:00']))[0]['timestamp'] == '2023-06-25 10:00:00'


@pytest.mark.parametrize('upstream', [{}, payload(None), payload(float('inf')),
    {'hourly': {'time': ['2023-06-25T10:00'], 'relative_humidity_2m': [80]}}])
def test_unusable_response_records_failure_without_overwriting_existing_data(db, monkeypatch, upstream):
    connection = ingest.connect(db)
    connection.close()
    before = _snapshot(db)
    get = Mock(return_value=upstream)
    post = Mock()
    callback = Mock()
    monkeypatch.setattr(ingest, '_get_json', get)
    monkeypatch.setattr(ingest, '_post_ingest', post)
    row = ingest.run_ingest(db_path=db, now=NOW, on_success=callback)
    assert row['status'] == 'error'
    assert row['cells_failed'] == 1 and row['cells_ok'] == 0
    assert _snapshot(db) == before
    assert _q(db, "SELECT status FROM series_status WHERE series_id = 'tsn'") == [('error',)]
    get.assert_called_once()
    post.assert_not_called()
    callback.assert_not_called()


def test_empty_series_does_not_discard_other_series_in_same_batch(monkeypatch):
    good = ingest.parse_hourly(payload())
    monkeypatch.setattr(ingest, 'fetch_historical_batch', lambda *args: [good, []])
    failed = {}
    rows = ingest._fetch_observed(None, [{'series_id': 'a'}, {'series_id': 'b'}],
                                  NOW.date(), NOW.replace(tzinfo=None, minute=0), {}, failed)
    assert rows == {'a': good}
    assert set(failed) == {'b'}


def test_malformed_location_in_http_batch_does_not_discard_valid_location(db, monkeypatch):
    connection = ingest.connect(db)
    with connection:
        connection.execute("INSERT INTO hourly_weather (location_id, timestamp, temperature) "
                           "VALUES ('bad', '2023-06-24 23:00:00', 25)")
    connection.close()
    monkeypatch.setattr(ingest, 'list_series', lambda *args: [
        {'series_id': 'tsn', 'lat': 10.79, 'lon': 106.63, 'elevation': 6},
        {'series_id': 'bad', 'lat': 11.0, 'lon': 107.0, 'elevation': 6},
    ])
    monkeypatch.setattr(ingest, '_get_json', lambda url, params:
                        [payload(), payload(float('nan'))] if url == ingest.HISTORICAL_URL else {})
    monkeypatch.setattr(ingest, '_post_ingest', lambda *args: None)
    row = ingest.run_ingest(db_path=db, now=NOW)
    assert row['status'] == 'partial'
    assert row['cells_ok'] == 1 and row['cells_failed'] == 1
    assert _q(db, "SELECT MAX(timestamp) FROM hourly_weather WHERE location_id = 'tsn'") == [('2023-06-25 10:00:00',)]
    assert _q(db, "SELECT timestamp, temperature FROM hourly_weather WHERE location_id = 'bad'") == [('2023-06-24 23:00:00', 25)]
    assert _q(db, "SELECT status FROM series_status WHERE series_id = 'bad'") == [('error',)]


@pytest.mark.parametrize('fetch,variable', [
    (ingest.fetch_forecast_batch, 'temperature_2m'),
    (ingest.fetch_air_quality_batch, 'us_aqi'),
])
def test_optional_batch_retains_valid_payload_positions(monkeypatch, fetch, variable):
    monkeypatch.setattr(ingest, '_get_json', lambda *args: [
        {'hourly': {'time': ['2023-06-25T10:00'], variable: [27]}},
        {'hourly': {'time': ['2023-06-25T10:00'], variable: [float('inf')]}},
    ])
    result = fetch([{'lat': 10.79, 'lon': 106.63}, {'lat': 11.0, 'lon': 107.0}])
    assert isinstance(result[0], list) and len(result[0]) == 1
    assert isinstance(result[1], ValueError)


class ClockStop:
    def __init__(self, outcomes):
        self.now = datetime(2026, 10, 21, 10, 6, tzinfo=LOCAL_TZ)
        self.outcomes = iter(outcomes)
        self.waits = []
        self.snapshots = []
        self.stopped = False

    def is_set(self):
        return self.stopped

    def wait(self, delay):
        self.waits.append(delay)
        self.snapshots.append(main._scheduler_snapshot())
        self.now += timedelta(seconds=delay)
        return self.stopped

    def run(self, **kwargs):
        outcome = next(self.outcomes)
        if outcome == 'stop':
            self.stopped = True
            outcome = 'ok'
        if isinstance(outcome, Exception):
            raise outcome
        return {'status': outcome, 'rows_inserted': 0, 'rows_updated': 0, 'message': ''}


def run_loop(monkeypatch, outcomes):
    stop = ClockStop(outcomes)
    monkeypatch.setattr(main, 'now_local', lambda: stop.now)
    monkeypatch.setattr(ingest, 'run_ingest', stop.run)
    main._ingest_loop(stop)
    assert main._scheduler_snapshot()['state'] == 'stopped'
    assert main._scheduler_snapshot()['next_run_at'] is None
    return stop


def test_scheduler_limits_early_retry_and_returns_to_hourly_cadence(monkeypatch):
    stop = run_loop(monkeypatch, ['error', 'partial', 'error', 'stop'])
    assert stop.waits == [300, 3240, 300]
    assert [s['consecutive_failures'] for s in stop.snapshots] == [1, 2, 3]
    assert stop.snapshots[0]['next_run_at'] == '2026-10-21T10:11:00+07:00'
    assert main._scheduler_snapshot()['consecutive_failures'] == 0


def test_scheduler_survives_exception_and_does_not_wait_after_stop(monkeypatch):
    stop = run_loop(monkeypatch, [RuntimeError('upstream unavailable'), 'stop'])
    assert stop.waits == [300]
    assert stop.snapshots[0]['last_outcome'] == 'error'


def test_scheduler_busy_is_not_counted_as_failed_ingestion(monkeypatch):
    stop = run_loop(monkeypatch, [ingest.IngestBusy(), 'ok', 'stop'])
    assert stop.waits == [60, 3480]
    assert stop.snapshots[0]['consecutive_failures'] == 0


def test_busy_across_hour_boundary_does_not_spend_new_cycles_retry(monkeypatch):
    stop = run_loop(monkeypatch, ['error', *[ingest.IngestBusy() for _ in range(54)], 'error', 'stop'])
    assert stop.waits[-1] == 300
    assert stop.snapshots[-1]['next_run_at'] == '2026-10-21T11:10:00+07:00'
    assert stop.snapshots[-1]['consecutive_failures'] == 2


def test_scheduler_health_snapshot_cannot_mutate_internal_state(client):
    main._set_scheduler(state='waiting', last_outcome='partial', consecutive_failures=1)
    response = client.get('/health').json()
    assert response['scheduler']['state'] == 'waiting'
    assert response['scheduler']['last_outcome'] == 'partial'
    snapshot = main._scheduler_snapshot()
    snapshot['state'] = 'wrong'
    assert main._scheduler_snapshot()['state'] == 'waiting'


def test_disabled_lifespan_reports_disabled_without_ingesting(monkeypatch):
    monkeypatch.setattr(main, 'init_db', lambda: None)
    monkeypatch.setattr(main, 'execute_one', lambda *args: None)
    run = Mock()
    monkeypatch.setattr(ingest, 'run_ingest', run)
    with TestClient(main.app) as client:
        assert client.get('/live').status_code == 200
        assert main._scheduler_snapshot()['state'] == 'disabled'
    run.assert_not_called()


def test_enabled_lifespan_stops_scheduler_even_when_context_raises(monkeypatch):
    started = Event()
    monkeypatch.setenv('INGEST_ENABLED', '1')
    monkeypatch.setattr(main, 'init_db', lambda: None)
    monkeypatch.setattr(main, 'execute_one', lambda *args: None)
    def run(**kwargs):
        started.set()
        return {'status': 'ok', 'rows_inserted': 0, 'rows_updated': 0, 'message': ''}
    monkeypatch.setattr(ingest, 'run_ingest', run)
    with pytest.raises(RuntimeError, match='test context'):
        with TestClient(main.app):
            assert started.wait(2)
            raise RuntimeError('test context')
    assert main._scheduler_snapshot()['state'] == 'stopped'


def test_shutdown_timeout_stays_stopping_until_the_worker_finishes(monkeypatch):
    started, release = Event(), Event()
    workers = []
    monkeypatch.setenv('INGEST_ENABLED', '1')
    monkeypatch.setattr(main, 'INGEST_SHUTDOWN_SECONDS', 0.01)
    monkeypatch.setattr(main, 'init_db', lambda: None)
    monkeypatch.setattr(main, 'execute_one', lambda *args: None)
    def run(**kwargs):
        workers.append(current_thread())
        started.set()
        assert release.wait(3)
        return {'status': 'ok', 'rows_inserted': 0, 'rows_updated': 0, 'message': ''}
    monkeypatch.setattr(ingest, 'run_ingest', run)
    try:
        with TestClient(main.app):
            assert started.wait(2)
        assert main._scheduler_snapshot()['state'] == 'stopping'
        assert main._scheduler_snapshot()['next_run_at'] is None
    finally:
        release.set()
        for worker in workers:
            worker.join(timeout=2)
    assert main._scheduler_snapshot()['state'] == 'stopped'
    assert len(workers) == 1
