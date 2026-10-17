"""Multi-location contract: location_id on /weather/*, per-series isolation, /weather/map, AI evaluation."""
import sqlite3

from conftest import COLUMNS, synthetic_rows

OTHER = "om-10.3691-107.0976"   # Vung Tau cell (series_id == cell_id)
WARD = "phuong-vung-tau"


def _add_series(db, sid, offset=5.0):
    rows = synthetic_rows()
    for r in rows:
        r["temperature"] = round(r["temperature"] + offset, 1)
    cols = COLUMNS + ["location_id"]
    with sqlite3.connect(db) as con:
        con.executemany(f"INSERT INTO hourly_weather ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
                        [tuple(r[c] for c in COLUMNS) + (sid,) for r in rows])
        con.commit()


def test_unknown_location_404(client):
    for path in ("/weather/current", "/weather/hourly", "/weather/daily", "/weather/ai-forecast"):
        r = client.get(path, params={"location_id": "khong-ton-tai"})
        assert r.status_code == 404, path
        assert "khong-ton-tai" in r.json()["detail"]


def test_default_is_tsn(client):
    a = client.get("/weather/current").json()
    b = client.get("/weather/current", params={"location_id": "tsn"}).json()
    assert a == b


def test_series_are_isolated(client, syn_db):
    _add_series(syn_db, OTHER, offset=5.0)
    tsn = client.get("/weather/current").json()
    ward = client.get("/weather/current", params={"location_id": WARD}).json()
    cell = client.get("/weather/current", params={"location_id": OTHER}).json()
    assert ward == cell
    assert ward["timestamp"] == tsn["timestamp"]
    assert abs(ward["temperature"] - tsn["temperature"] - 5.0) < 0.05


def test_ward_without_data_falls_back_to_tsn_climatology(client):
    # The ward's own series is empty: /hourly still answers from the 10-year tsn climatology.
    r = client.get("/weather/hourly", params={"location_id": WARD, "hours": 6})
    assert r.status_code == 200
    assert {i["source"] for i in r.json()} == {"climatology"}


def test_history_filters_by_location(client, syn_db):
    _add_series(syn_db, OTHER)
    q = {"start_date": "2023-06-10", "end_date": "2023-06-10"}
    assert len(client.get("/weather/history", params=q).json()) == 24
    assert len(client.get("/weather/history", params={**q, "location_id": OTHER}).json()) == 24


def test_map_shape(client, syn_db):
    _add_series(syn_db, OTHER)
    r = client.get("/weather/map", params={"at": "2023-06-20T12:00"})
    assert r.status_code == 200
    cells = r.json()
    assert len(cells) == 67
    keys = {"cell_id", "lat", "lon", "location_ids", "temperature", "weather_code",
            "rain_probability_next_3h", "precipitation_next_3h", "alert"}
    assert all(keys <= set(c) for c in cells)
    vt = next(c for c in cells if c["cell_id"] == OTHER)
    assert WARD in vt["location_ids"] and vt["temperature"] is not None
    assert isinstance(vt["alert"], bool)


def test_map_replay_never_uses_future_beyond_3h(client, syn_db):
    at = "2023-06-20T12:00"
    cells = {c["cell_id"]: c for c in client.get("/weather/map", params={"at": at}).json()}
    tsn_cell = next(c for c in cells.values() if "tsn" in c["location_ids"] or c["cell_id"] == "tsn")
    assert tsn_cell["observed_at"].startswith("2023-06-20T12:00")
    # Replay outlook is the AI forecast issued at `at`, never the hours observed afterwards.
    assert tsn_cell["outlook_source"] == "ai" and tsn_cell["precipitation_next_3h"] is None
    assert 0 <= tsn_cell["rain_probability_next_3h"] <= 1
    assert "tsn" in tsn_cell["location_ids"] and "phuong-tan-son-nhat" in tsn_cell["location_ids"]
    assert tsn_cell["cell_id"] == "om-10.7909-106.6313"


def test_ai_forecast_has_location_and_evaluation(real_client):
    r = real_client.get("/weather/ai-forecast")
    assert r.status_code == 200
    body = r.json()
    assert body["location_id"] == "tsn" and body["cell_id"] == "tsn"
    ev = body["evaluation"]
    assert ev is None or {"temperature_mae_1h", "beats_baselines", "test_period"} <= set(ev)


def test_ai_forecast_other_cell(real_client):
    r = real_client.get("/weather/ai-forecast", params={"location_id": WARD})
    assert r.status_code in (200, 503)
    if r.status_code == 200:
        assert r.json()["cell_id"] == OTHER


def _insert_hour(db, sid, ts, temperature=30.0, weather_code=1.0):
    with sqlite3.connect(db) as con:
        con.execute("INSERT INTO hourly_weather (location_id, timestamp, temperature, weather_code) "
                    "VALUES (?, ?, ?, ?)", (sid, ts, temperature, weather_code))
        con.commit()
    con.close()


def test_health_cells(client, syn_db):
    # Frozen now 2024-06-10 14:23: only OTHER has an hour within 3 h; tsn data ends 2023-06-24.
    _insert_hour(syn_db, OTHER, "2024-06-10 13:00:00")
    with sqlite3.connect(syn_db) as con:
        con.execute("INSERT INTO series_status (series_id, status, error) VALUES ('tsn', 'failed', 'API down')")
        n_cells = con.execute("SELECT COUNT(*) FROM cells").fetchone()[0]
        n_tsn = con.execute("SELECT COUNT(*) FROM cells WHERE series_id = 'tsn'").fetchone()[0]
        con.commit()
    con.close()
    body = client.get("/health").json()
    # Old fields still describe the 'tsn' series, not the newest hour of any cell.
    assert body["latest_timestamp"].startswith("2023-06-24T23:00")
    cells = body["cells"]
    assert cells["total"] == n_cells == 68 and cells["fresh"] == 1 and cells["fresh_hours"] == 3
    stale = {c["cell_id"]: c for c in cells["stale"]}
    assert len(stale) == 67 and OTHER not in stale
    tsn_cells = [c for c in stale.values() if c["series_id"] == "tsn"]
    assert len(tsn_cells) == n_tsn >= 1
    assert tsn_cells[0]["status"] == "failed" and tsn_cells[0]["error"] == "API down"
    assert tsn_cells[0]["latest_timestamp"].startswith("2023-06-24T23:00")
    empty = next(c for c in stale.values() if c["series_id"] not in ("tsn", OTHER))
    assert empty["latest_timestamp"] is None and empty["status"] is None


def test_map_live_uses_latest_nwp_issue(client, syn_db):
    # Live mode (frozen now 14:00): current = latest observed hour, next 3 h = 15..17 h of the newest issue only.
    _insert_hour(syn_db, OTHER, "2024-06-10 14:00:00", temperature=31.2, weather_code=2.0)
    old = [(OTHER, "2024-06-10 06:00:00", f"2024-06-10 {h}:00:00", 0.0, 0.0, 1.0) for h in (15, 16, 17)]
    new = [(OTHER, "2024-06-10 12:00:00", f"2024-06-10 {h}:00:00", p, pp, c)
           for h, p, pp, c in ((14, 50.0, 100.0, 65.0),      # not in the next 3 h
                               (15, 4.0, 60.0, 63.0), (16, 7.0, 80.0, 95.0), (17, 0.5, 30.0, 61.0),
                               (18, 50.0, 100.0, 65.0))]     # after the next 3 h
    with sqlite3.connect(syn_db) as con:
        con.executemany("INSERT INTO nwp_forecast (location_id, issued_at, timestamp, precipitation, "
                        "precipitation_probability, weather_code) VALUES (?, ?, ?, ?, ?, ?)", old + new)
        con.commit()
    con.close()
    r = client.get("/weather/map")
    assert r.status_code == 200
    cells = {c["cell_id"]: c for c in r.json()}
    assert len(cells) == 67
    vt = cells[OTHER]
    assert vt["observed_at"].startswith("2024-06-10T14:00") and vt["temperature"] == 31.2
    assert vt["weather_code"] == 2
    assert vt["precipitation_next_3h"] == 11.5 and vt["rain_probability_next_3h"] == 0.8
    assert vt["alert"] is True    # code 95 and >= 10 mm
    # Cells without any NWP issue: no outlook, no alert.
    tsn_cell = next(c for c in cells.values() if "tsn" in c["location_ids"] or c["cell_id"] == "tsn")
    assert tsn_cell["precipitation_next_3h"] is None and tsn_cell["rain_probability_next_3h"] is None
    assert tsn_cell["observed_at"].startswith("2023-06-24T23:00") and tsn_cell["alert"] is False
