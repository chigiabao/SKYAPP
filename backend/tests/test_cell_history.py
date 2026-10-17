"""Per-cell climatology from data/history/cells_history.db (merged with weather.db), tsn fallback otherwise."""
import sqlite3
from datetime import datetime, timedelta

from routers import weather as weather_router

OTHER = "om-10.3691-107.0976"   # Vung Tau cell (series_id == cell_id)
WARD = "phuong-vung-tau"
HIST_COLS = ["temperature", "humidity", "dew_point", "apparent_temperature", "precipitation", "weather_code",
             "cloud_cover", "surface_pressure", "pressure_msl", "wind_speed", "wind_direction", "wind_gusts"]


def _write_history(path, cell_id, years=(2022, 2023), temp=40.0):
    """cells_history.db with the backfill script's `hourly` schema: full calendar years of one cell."""
    path.parent.mkdir(parents=True, exist_ok=True)
    rows, t = [], datetime(years[0], 1, 1)
    while t.year <= years[-1]:
        rows.append((cell_id, t.strftime("%Y-%m-%d %H:%M:%S"), temp, 80.0, 24.0, 44.0, 0.0, 2.0, 60.0,
                     1008.0, 1010.0, 10.0, 180.0, 20.0))
        t += timedelta(hours=1)
    cols = ", ".join(f'"{c}" REAL' for c in HIST_COLS)
    with sqlite3.connect(path) as con:
        con.execute(f"CREATE TABLE hourly (cell_id TEXT NOT NULL, timestamp TEXT NOT NULL, {cols}, "
                    "PRIMARY KEY (cell_id, timestamp))")
        con.executemany(f"INSERT INTO hourly VALUES ({', '.join('?' * (2 + len(HIST_COLS)))})", rows)
    con.close()
    weather_router.invalidate_climatology()
    return path


def _hist_path():
    return weather_router.HISTORY_DB_PATH


def test_no_history_file_falls_back_to_tsn(client):
    assert not _hist_path().exists()
    assert weather_router._clim_series(OTHER) == "tsn"
    r = client.get("/weather/hourly", params={"location_id": WARD, "hours": 6})
    assert r.status_code == 200
    assert {i["source"] for i in r.json()} == {"climatology"}


def test_cell_with_history_has_own_climatology(client):
    _write_history(_hist_path(), OTHER)
    assert weather_router._clim_series(OTHER) == OTHER
    hourly, daily = weather_router._climatology(OTHER)
    tsn_hourly, _ = weather_router._climatology("tsn")
    assert abs(hourly.loc[(6, 10, 15), "temperature"] - 40.0) < 1e-6
    assert abs(tsn_hourly.loc[(6, 10, 15), "temperature"] - 40.0) > 1
    assert abs(daily.loc[(6, 10), "temp_max"] - 40.0) < 1e-6
    assert hourly.loc[(6, 10, 15), "rain"] == 0.0               # rain filled from precipitation
    assert hourly["uv_index"].isna().all()                       # not in history: no uv climatology
    r = client.get("/weather/hourly", params={"location_id": WARD, "hours": 6}).json()
    assert {i["source"] for i in r} == {"climatology"}
    assert all(abs(i["temperature"] - 40.0) < 0.05 for i in r)


def test_cell_without_history_rows_falls_back_to_tsn(client):
    _write_history(_hist_path(), "om-0.0000-0.0000")   # file exists, but only for another cell
    assert weather_router._clim_series(OTHER) == "tsn"


def test_short_history_falls_back_to_tsn(client):
    _write_history(_hist_path(), OTHER, years=(2023,))   # ~1 year < 2-year threshold
    assert weather_router._clim_series(OTHER) == "tsn"


def test_weather_db_rows_win_on_duplicate_hours(client, syn_db):
    _write_history(_hist_path(), OTHER, years=(2021, 2022, 2023))
    with sqlite3.connect(syn_db) as con:
        con.execute("INSERT INTO hourly_weather (timestamp, temperature, location_id) "
                    "VALUES ('2022-06-10 15:00:00', 10.0, ?)", (OTHER,))
    con.close()
    weather_router.invalidate_climatology()
    hourly, _ = weather_router._climatology(OTHER)
    assert abs(hourly.loc[(6, 10, 15), "temperature"] - (40.0 * 2 + 10.0) / 3) < 1e-6
