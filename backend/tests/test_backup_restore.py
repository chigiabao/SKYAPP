"""Exercise the documented SQLite WAL backup/restore on disposable databases."""
import sqlite3
from contextlib import closing


def test_online_wal_backup_restores_committed_data(tmp_path):
    source = tmp_path / "source.db"
    backup = tmp_path / "backup.db"
    restored = tmp_path / "restored.db"
    with closing(sqlite3.connect(source)) as writer:
        assert writer.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        writer.execute("CREATE TABLE readings (id INTEGER PRIMARY KEY, value REAL)")
        writer.execute("INSERT INTO readings VALUES (1, 27.5)")
        writer.commit()
        assert source.with_name("source.db-wal").exists()
        with closing(sqlite3.connect(source)) as snapshot, closing(sqlite3.connect(backup)) as target:
            snapshot.backup(target)
        writer.execute("INSERT INTO readings VALUES (2, 30.0)")
        writer.commit()
        with closing(sqlite3.connect(backup)) as saved, closing(sqlite3.connect(restored)) as target:
            saved.backup(target)
            assert target.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            assert target.execute("SELECT * FROM readings").fetchall() == [(1, 27.5)]
        assert writer.execute("SELECT COUNT(*) FROM readings").fetchone()[0] == 2
