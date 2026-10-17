"""/weather/map time frames (offset_hours), wind fields, observed vs forecast source, /weather/map/meta."""
import sqlite3
import time

OTHER = "om-10.3691-107.0976"   # Vung Tau cell (series_id == cell_id)
NWP_COLS = ("location_id", "issued_at", "timestamp", "temperature", "weather_code", "precipitation",
            "precipitation_probability", "wind_speed", "wind_direction", "wind_gusts")


def _nwp(db, rows):
    with sqlite3.connect(db) as con:
        con.executemany(f"INSERT INTO nwp_forecast ({', '.join(NWP_COLS)}) VALUES ({', '.join('?' * len(NWP_COLS))})",
                        rows)
        con.commit()
    con.close()


def _seed(db):
    # Frozen now = 2024-06-10 14:00. Old issue (06:00) must never be used; new issue (12:00) runs to 20:00.
    with sqlite3.connect(db) as con:
        con.execute("INSERT INTO hourly_weather (location_id, timestamp, temperature, weather_code, precipitation, "
                    "wind_speed, wind_direction, wind_gusts) VALUES (?, '2024-06-10 14:00:00', 31.2, 2, 0.0, "
                    "12.34, 225.4, 30.06)", (OTHER,))
        con.commit()
    con.close()
    old = [(OTHER, "2024-06-10 06:00:00", f"2024-06-10 {h}:00:00", 20.0, 0, 0.0, 0.0, 1.0, 0.0, 2.0)
           for h in range(15, 21)]
    new = [(OTHER, "2024-06-10 12:00:00", f"2024-06-10 {h}:00:00", 25.0 + h / 10, 63 if h == 16 else 3,
            float(h - 14), 10.0 * (h - 14), 5.0 + h, 90.0, 20.0 + h) for h in range(13, 21)]
    _nwp(db, old + new)


def test_offset0_observed_with_wind(client, syn_db):
    _seed(syn_db)
    cells = {c["cell_id"]: c for c in client.get("/weather/map").json()}
    vt = cells[OTHER]
    assert vt["source"] == "observed" and vt["observed_at"].startswith("2024-06-10T14:00")
    assert vt["valid_time"] == "2024-06-10T14:00:00+07:00"
    assert (vt["wind_speed"], vt["wind_direction"], vt["wind_gusts"]) == (12.3, 225.0, 30.1)
    assert vt["temperature"] == 31.2 and vt["precipitation"] == 0.0
    # Outlook = 15..17 h of the newest issue: 1+2+3 mm, max prob 0.3.
    assert vt["precipitation_next_3h"] == 6.0 and vt["rain_probability_next_3h"] == 0.3
    # Cells without data: numbers and source null (old fields unchanged).
    empty = next(c for c in cells.values() if c["observed_at"] is None)
    assert empty["source"] is None and empty["wind_speed"] is None and empty["temperature"] is None


def test_offset_uses_hour_t_of_latest_nwp(client, syn_db):
    _seed(syn_db)
    r = client.get("/weather/map", params={"offset_hours": 2})
    assert r.status_code == 200
    cells = {c["cell_id"]: c for c in r.json()}
    assert len(cells) == 67
    vt = cells[OTHER]   # t = 16:00 of the 12:00 issue
    assert vt["source"] == "forecast" and vt["valid_time"] == "2024-06-10T16:00:00+07:00"
    assert vt["observed_at"] is None
    assert vt["temperature"] == 26.6 and vt["weather_code"] == 63 and vt["precipitation"] == 2.0
    assert (vt["wind_speed"], vt["wind_direction"], vt["wind_gusts"]) == (21.0, 90.0, 36.0)
    # Outlook t+1..t+3 = 17..19 h: 3+4+5 mm, max prob 0.5; >= 10 mm -> alert.
    assert vt["precipitation_next_3h"] == 12.0 and vt["rain_probability_next_3h"] == 0.5
    assert vt["outlook_source"] == "forecast" and vt["alert"] is True
    # Cells with no NWP row at t: no frame.
    other = [c for c in cells.values() if c["cell_id"] != OTHER]
    assert all(c["source"] is None and c["temperature"] is None for c in other)


def test_offset_beyond_issue_is_empty(client, syn_db):
    _seed(syn_db)
    vt = {c["cell_id"]: c for c in client.get("/weather/map", params={"offset_hours": 10}).json()}[OTHER]
    assert vt["source"] is None and vt["temperature"] is None and vt["precipitation_next_3h"] is None


def test_meta(client, syn_db):
    assert client.get("/weather/map/meta").json()["max_offset_hours"] == 0   # no NWP issue yet
    _seed(syn_db)
    meta = client.get("/weather/map/meta").json()
    assert meta == {"now": "2024-06-10T14:00:00+07:00", "max_offset_hours": 6,
                    "issued_at": "2024-06-10T12:00:00+07:00"}
    items = client.get("/weather/map").json()
    assert {c["max_offset_hours"] for c in items} == {6}


def test_meta_capped_at_72(client, syn_db):
    _nwp(syn_db, [(OTHER, "2024-06-10 12:00:00", "2024-06-20 00:00:00") + (None,) * 7])
    assert client.get("/weather/map/meta").json()["max_offset_hours"] == 72


def test_replay_with_offset_rejected(client, syn_db):
    at = "2023-06-20T12:00"
    r = client.get("/weather/map", params={"at": at, "offset_hours": 1})
    assert r.status_code == 400 and "xem lại" in r.json()["detail"]
    ok = client.get("/weather/map", params={"at": at, "offset_hours": 0})
    assert ok.status_code == 200
    assert client.get("/weather/map/meta", params={"at": at}).json()["max_offset_hours"] == 0


def test_offset_bounds(client, syn_db):
    for bad in (-1, 73, "x"):
        assert client.get("/weather/map", params={"offset_hours": bad}).status_code == 422
    for good in (0, 72):
        assert client.get("/weather/map", params={"offset_hours": good}).status_code == 200


def test_real_db_frame_speed(real_client):
    for off in (0, 1, 24, 72):
        real_client.get("/weather/map", params={"offset_hours": off})   # warm
        t = time.perf_counter()
        r = real_client.get("/weather/map", params={"offset_hours": off})
        assert r.status_code == 200 and len(r.json()) == 67
        assert time.perf_counter() - t < 0.3
