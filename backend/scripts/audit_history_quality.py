"""Read-only, per-cell audit of modeled training history; never fills missing values."""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3

import numpy as np
import pandas as pd

BACKEND = Path(__file__).resolve().parents[1]
DEFAULT_DB = BACKEND / 'data/history/cells_history.db'
RANGES = {
    'temperature': (-90, 65), 'humidity': (0, 100), 'dew_point': (-100, 65),
    'apparent_temperature': (-100, 90), 'precipitation': (0, 1000),
    'cloud_cover': (0, 100), 'surface_pressure': (300, 1100),
    'pressure_msl': (800, 1100), 'wind_speed': (0, 400),
    'wind_direction': (0, 360), 'wind_gusts': (0, 500),
}
WMO_CODES = {0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77,
             80, 81, 82, 85, 86, 95, 96, 99}


def audit_frame(frame):
    times = pd.to_datetime(frame['timestamp'], format='%Y-%m-%d %H:%M:%S', errors='coerce')
    valid = times.dropna().sort_values()
    unique = pd.DatetimeIndex(valid.unique())
    expected = pd.date_range(unique.min(), unique.max(), freq='h') if len(unique) else pd.DatetimeIndex([])
    missing = expected.difference(unique)
    gaps = []
    for stamp in missing:
        if gaps and stamp == gaps[-1][1] + pd.Timedelta(hours=1):
            gaps[-1][1] = stamp
            gaps[-1][2] += 1
        else:
            gaps.append([stamp, stamp, 1])
    fields = {}
    complete = np.ones(len(frame), dtype=bool)
    for name in [*RANGES, 'weather_code']:
        raw = frame[name]
        values = pd.to_numeric(raw, errors='coerce')
        finite = values.notna() & np.isfinite(values)
        complete &= finite.to_numpy()
        finite_values = values[finite]
        invalid_range = (~finite_values.isin(WMO_CODES) if name == 'weather_code'
                         else ~finite_values.between(*RANGES[name]))
        fields[name] = {
            'missing': int(raw.isna().sum()),
            'invalid_numeric': int((raw.notna() & ~finite).sum()),
            'range_flags': int(invalid_range.sum()),
            'zero': int((finite_values == 0).sum()),
            'min': float(finite_values.min()) if len(finite_values) else None,
            'max': float(finite_values.max()) if len(finite_values) else None,
        }
    rain = pd.to_numeric(frame['precipitation'], errors='coerce')
    seasons = {}
    for (year, month), indices in frame.groupby([times.dt.year, times.dt.month]).groups.items():
        values = rain.loc[indices]
        good = values.notna() & np.isfinite(values) & (values >= 0)
        seasons[f'{int(year):04d}-{int(month):02d}'] = {
            'rows': len(indices), 'rain_known': int(good.sum()),
            'wet_hours_ge_0_1mm': int((values[good] >= 0.1).sum()),
            'heavy_hours_ge_10mm': int((values[good] >= 10).sum()),
        }
    return {
        'rows': len(frame), 'first_hour': str(unique.min()) if len(unique) else None,
        'last_hour': str(unique.max()) if len(unique) else None,
        'invalid_timestamps': int(times.isna().sum()),
        'unaligned_timestamps': int((valid != valid.dt.floor('h')).sum()),
        'duplicate_timestamps': int(valid.duplicated().sum()),
        'missing_hours': len(missing), 'longest_gap_hours': max((g[2] for g in gaps), default=0),
        'first_gaps': [{'start': str(a), 'end': str(b), 'hours': n} for a, b, n in gaps[:20]],
        'complete_feature_rows_before_lags': int(complete.sum()),
        'fields': fields, 'monthly_rain': seasons,
    }


def audit(path):
    result = {'created_at': datetime.now(timezone.utc).isoformat(), 'database': str(path.resolve()),
              'source_kind': 'historical_weather_model_output_not_station_observations',
              'range_policy': 'Broad plausibility flags for review only; no automatic deletion or imputation.',
              'cells': {}}
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as con:
        con.execute('PRAGMA query_only=ON')
        con.execute('BEGIN')
        result['sqlite_quick_check'] = [r[0] for r in con.execute('PRAGMA quick_check')]
        for (cell,) in con.execute('SELECT DISTINCT cell_id FROM hourly ORDER BY cell_id').fetchall():
            frame = pd.read_sql_query('SELECT * FROM hourly WHERE cell_id=? ORDER BY timestamp', con, params=(cell,))
            result['cells'][cell] = audit_frame(frame)
    cells = list(result['cells'].values())
    result['summary'] = {
        'cells': len(cells), 'rows': sum(c['rows'] for c in cells),
        'first_hour': min((c['first_hour'] for c in cells), default=None),
        'last_hour': max((c['last_hour'] for c in cells), default=None),
        'min_last_hour': min((c['last_hour'] for c in cells), default=None),
        **{key: sum(c[key] for c in cells) for key in
           ('invalid_timestamps', 'unaligned_timestamps', 'duplicate_timestamps', 'missing_hours',
            'complete_feature_rows_before_lags')},
        'missing_values': sum(v['missing'] for c in cells for v in c['fields'].values()),
        'invalid_numeric': sum(v['invalid_numeric'] for c in cells for v in c['fields'].values()),
        'range_flags': sum(v['range_flags'] for c in cells for v in c['fields'].values()),
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=DEFAULT_DB)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.db)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
