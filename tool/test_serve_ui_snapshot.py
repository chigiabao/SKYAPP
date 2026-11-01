"""Snapshot backups include committed WAL rows and never overwrite an existing snapshot."""
import os
import sqlite3
import sys

import pytest
import serve_ui_snapshot as snapshot
from serve_ui_snapshot import backup_once


def test_backup_sees_committed_wal_and_keeps_source(tmp_path):
    source = tmp_path / "source.db"
    target = tmp_path / "copy" / "snapshot.db"
    with sqlite3.connect(source) as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE rows (id INTEGER)")
        conn.execute("INSERT INTO rows VALUES (1)")
        conn.commit()
        backup_once(source, target)
        with sqlite3.connect(target) as copied:
            assert copied.execute("SELECT id FROM rows").fetchall() == [(1,)]
        assert conn.execute("SELECT id FROM rows").fetchall() == [(1,)]


def test_backup_does_not_overwrite_or_create_missing_source(tmp_path):
    source = tmp_path / "missing.db"
    target = tmp_path / "snapshot.db"
    backup_once(source, target)
    assert not target.exists()
    with sqlite3.connect(source) as conn:
        conn.execute("CREATE TABLE rows (id INTEGER)")
    backup_once(source, target)
    with sqlite3.connect(target) as conn:
        conn.execute("INSERT INTO rows VALUES (2)")
    backup_once(source, target)
    with sqlite3.connect(target) as conn:
        assert conn.execute("SELECT id FROM rows").fetchall() == [(2,)]


@pytest.mark.parametrize('name', ['weather.db', 'history/cells_history.db'])
@pytest.mark.parametrize('link', ['hardlink', 'symlink'])
def test_cli_rejects_source_alias_before_backup_or_import(tmp_path, monkeypatch, name, link):
    backend = tmp_path / 'backend'
    source = backend / 'data' / name
    source.parent.mkdir(parents=True)
    with sqlite3.connect(source) as conn:
        conn.execute('CREATE TABLE original (id INTEGER)')
        conn.execute('INSERT INTO original VALUES (1)')
    root = tmp_path / 'snapshot'
    root.mkdir()
    alias = root / 'weather.db'
    if link == 'hardlink':
        os.link(source, alias)
    else:
        try:
            alias.symlink_to(source)
        except OSError as exc:
            pytest.skip(f'Symlink creation unavailable: {exc}')
    monkeypatch.setattr(snapshot, 'BACKEND', backend)
    monkeypatch.setattr(sys, 'argv', ['serve_ui_snapshot.py', '--db-dir', str(root), '--ingest-once'])
    monkeypatch.setattr(snapshot, 'backup_once', lambda *args: pytest.fail('backup reached'))
    with pytest.raises(SystemExit) as error:
        snapshot.main()
    assert error.value.code == 2
    with sqlite3.connect(source) as conn:
        assert conn.execute('SELECT id FROM original').fetchall() == [(1,)]


def test_snapshot_paths_rejects_backend_and_crosslinked_destinations(tmp_path, monkeypatch):
    backend = tmp_path / 'backend'
    monkeypatch.setattr(snapshot, 'BACKEND', backend)
    with pytest.raises(ValueError, match='outside'):
        snapshot.snapshot_paths(backend / 'data' / 'snapshot')
    root = tmp_path / 'snapshot'
    history = root / 'history'
    history.mkdir(parents=True)
    (root / 'weather.db').touch()
    os.link(root / 'weather.db', history / 'cells_history.db')
    with pytest.raises(ValueError, match='separate'):
        snapshot.snapshot_paths(root)
