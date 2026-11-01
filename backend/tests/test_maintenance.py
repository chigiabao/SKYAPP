"""Periodic retention uses synthetic databases only and needs no HTTP requests."""
import sqlite3
import threading
from datetime import datetime, timedelta
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

import main
import maintenance
from conftest import write_db
from routers import monitor


def test_idle_lifespan_runs_retention_without_requests(tmp_path, monkeypatch):
    path = write_db(tmp_path / 'idle.db', [], locations=False)
    with sqlite3.connect(path) as conn:
        from database import migrate
        migrate(conn)
    now = datetime(2026, 11, 2, 1)
    with sqlite3.connect(path) as conn:
        conn.execute("INSERT INTO feedback (created_at, kind, message) VALUES (?, 'other', 'old')",
                     ((now - timedelta(days=monitor.FEEDBACK_RETENTION_DAYS + 1)).isoformat(' '),))
        conn.execute("INSERT INTO feedback (created_at, kind, message) VALUES (?, 'other', 'keep')",
                     (now.isoformat(' '),))
    monkeypatch.setattr(main, 'DATABASE_PATH', path)
    monkeypatch.setattr(main, 'init_db', lambda: None)
    monkeypatch.setattr(main, 'execute_one', lambda *args: None)
    monkeypatch.setenv('MAINTENANCE_ENABLED', '1')
    monkeypatch.setattr(monitor, '_naive_now', lambda value=None: now)
    finished = threading.Event()
    original = monitor.maybe_run_retention

    def run(*args, **kwargs):
        result = original(*args, **kwargs)
        finished.set()
        return result

    monkeypatch.setattr(monitor, 'maybe_run_retention', run)
    with TestClient(main.app):
        assert finished.wait(3)
    with sqlite3.connect(path) as conn:
        assert conn.execute('SELECT message FROM feedback').fetchall() == [('keep',)]


def test_daily_gate_retries_failure_and_respects_database_and_day(tmp_path, monkeypatch):
    one, two = tmp_path / 'one.db', tmp_path / 'two.db'
    now = datetime(2026, 11, 2)
    run = Mock(side_effect=[RuntimeError('locked'), {}, {}, {}])
    monkeypatch.setattr(monitor, 'run_retention', run)
    monkeypatch.setattr(monitor, '_retention_day', {})
    with pytest.raises(RuntimeError):
        monitor.maybe_run_retention(one, now)
    assert monitor.maybe_run_retention(one, now) == {}
    assert monitor.maybe_run_retention(one, now) is None
    assert monitor.maybe_run_retention(two, now) == {}
    assert monitor.maybe_run_retention(one, now + timedelta(days=1)) == {}
    assert run.call_count == 4


def test_loop_recovers_and_stops_between_ticks(monkeypatch):
    calls = []

    class Stop:
        def is_set(self):
            return False

        def wait(self, seconds):
            assert seconds == maintenance.MAINTENANCE_INTERVAL_SECONDS
            return len(calls) == 2

    def run(path):
        calls.append(path)
        if len(calls) == 1:
            raise RuntimeError('temporary')

    monkeypatch.setattr(monitor, 'maybe_run_retention', run)
    maintenance._maintenance_loop(Stop(), 'synthetic.db')
    assert calls == ['synthetic.db', 'synthetic.db']
    stopped = threading.Event()
    stopped.set()
    maintenance._maintenance_loop(stopped)
    assert len(calls) == 2


def test_disabled_worker_does_not_start_thread(monkeypatch):
    monkeypatch.setenv('MAINTENANCE_ENABLED', '0')
    thread = Mock()
    monkeypatch.setattr(maintenance.threading, 'Thread', thread)
    with maintenance.retention_worker():
        pass
    thread.assert_not_called()


def test_worker_shutdown_is_bounded_and_signals_stop(monkeypatch):
    monkeypatch.setenv('MAINTENANCE_ENABLED', '1')
    thread = Mock()
    factory = Mock(return_value=thread)
    monkeypatch.setattr(maintenance.threading, 'Thread', factory)
    with pytest.raises(RuntimeError), maintenance.retention_worker('synthetic.db'):
        raise RuntimeError('context failed')
    stop, path = factory.call_args.kwargs['args']
    assert stop.is_set()
    assert path == 'synthetic.db'
    thread.start.assert_called_once()
    thread.join.assert_called_once_with(timeout=maintenance.MAINTENANCE_SHUTDOWN_SECONDS)
