"""History download validation and honest missing/zero/gap audit."""
import numpy as np
import pandas as pd
import pytest
from datetime import date, datetime, timedelta
import hashlib
import json
import sqlite3
import time

import httpx

from scripts import audit_history_quality as quality
from scripts import backfill_history as backfill


def test_audit_distinguishes_zero_missing_invalid_and_gaps():
    frame = pd.DataFrame({name: [1.0, 1.0, 1.0] for name in [*quality.RANGES, 'weather_code']})
    frame['timestamp'] = ['2026-01-01 00:00:00', '2026-01-01 02:00:00', '2026-01-01 02:00:00']
    frame['precipitation'] = [0, None, -1]
    frame['temperature'] = [25, np.inf, 26]
    result = quality.audit_frame(frame)
    assert result['missing_hours'] == 1
    assert result['duplicate_timestamps'] == 1
    assert result['longest_gap_hours'] == 1
    assert result['fields']['precipitation']['zero'] == 1
    assert result['fields']['precipitation']['missing'] == 1
    assert result['fields']['precipitation']['range_flags'] == 1
    assert result['fields']['temperature']['invalid_numeric'] == 1


def payload(value=0):
    return {'hourly': {'time': ['2026-10-21T00:00Z'],
                       **{name: [value] for name in backfill.VARS.values()}}}


def test_backfill_reuses_finite_timezone_safe_parser():
    rows = backfill.parse(payload())
    assert rows[0][0] == '2026-10-21 07:00:00'
    assert all(value == 0 for value in rows[0][1:])


@pytest.mark.parametrize('value', [np.inf, np.nan, True, None])
def test_backfill_rejects_nonfinite_or_empty_temperature(value):
    with pytest.raises(ValueError):
        backfill.parse(payload(value))


def test_backfill_rejects_inconsistent_arrays_and_duplicate_hours():
    broken = payload()
    broken['hourly']['temperature_2m'] = []
    with pytest.raises(ValueError):
        backfill.parse(broken)
    duplicate = payload()
    duplicate['hourly'] = {name: values * 2 for name, values in duplicate['hourly'].items()}
    with pytest.raises(ValueError, match='duplicate'):
        backfill.parse(duplicate)


def test_download_retains_content_hash_and_source_without_network(tmp_path, monkeypatch):
    body = json.dumps(payload()).encode()
    response = httpx.Response(200, content=body)
    monkeypatch.setattr(backfill.httpx, 'get', lambda *args, **kwargs: response)
    monkeypatch.setattr(backfill, 'HIST_DIR', tmp_path)
    con = sqlite3.connect(':memory:')
    try:
        for statement in backfill.SCHEMA:
            con.execute(statement)
        cell = {'cell_id': 'test-cell', 'lat': 10.7, 'lon': 106.7, 'elevation': 6}
        downloaded = backfill.fetch(con, [cell], date(2026, 10, 21), date(2026, 10, 21), time.time() + 10)
        assert downloaded == [payload()]
        info = json.loads(con.execute('SELECT note FROM request_log').fetchone()[0])
        assert info['sha256'] == hashlib.sha256(body).hexdigest()
        assert (tmp_path / info['raw_file']).read_bytes() == body
        assert info['requested_cells'] == ['test-cell']
        assert info['source_url'] == backfill.URL
    finally:
        con.close()


def test_incomplete_window_cannot_be_marked_complete():
    with pytest.raises(ValueError, match='Incomplete historical window'):
        backfill.validated_rows(payload(), date(2026, 10, 19), date(2026, 10, 21))
    full = payload()
    full['hourly']['time'] = [(datetime(2026, 10, 21) + timedelta(hours=h)).isoformat() for h in range(24)]
    for field in backfill.VARS.values():
        full['hourly'][field] = [0] * 24
    assert len(backfill.validated_rows(full, date(2026, 10, 21), date(2026, 10, 21))) == 24
    full['hourly']['time'][-1] = '2026-10-22T00:00'
    with pytest.raises(ValueError, match='missing=1 extra=1'):
        backfill.validated_rows(full, date(2026, 10, 21), date(2026, 10, 21))
