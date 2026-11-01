"""Read-only export of cells_history.db for Google Colab training of long-range v2.1.

  python scripts/export_colab_data.py --out D:\\wether_app\\colab_upload        (all 67 cells)
  python scripts/export_colab_data.py --out %TEMP%\\smoke --cells 3            (smoke)

Writes (outside the repo; the user uploads the folder to Google Drive himself, nothing is sent here):
  data/cells.json            cell_id, lat, lon, elevation, source, first/last hour, DB row count
  data/hourly_<cell>.npz     contiguous hourly arrays from the first to the last DB hour, 12 columns as
                             int16 x10 (-32768 = NaN); a column that does not round-trip exactly is stored
                             as float64 and flagged in the manifest
  data/manifest.json         DB size/mtime, per-file sha256, canonical array sha256, row/NaN counts,
                             per-year audit (mean/std/NaN per variable, pooled over cells), code sha256
  code.zip (+ .sha256)       backend modules + models/v3, models/long_range, models/long_range_v2
  train_long_range_v21_colab.ipynb, README.md, requirements-colab.txt (copied from notebooks/colab_train_v21/)
The DB is opened with ?mode=ro, PRAGMA query_only and one BEGIN snapshot. No network, no DB writes.
Parquet is not used because pyarrow is not installed locally (npz needs only numpy).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "scripts"))
from train_long_range import connect  # noqa: E402
from train_long_range_v21 import DATA_COLUMNS, canonical_sha, decode_npz, sha256_file  # noqa: E402

SENTINEL = np.iinfo(np.int16).min
CODE_FILES = ("long_range_model.py", "long_range_model_v2.py", "long_range_model_v21.py", "ai_model.py",
              "scripts/train_long_range.py", "scripts/train_long_range_v2.py", "scripts/train_long_range_v21.py",
              "scripts/export_colab_data.py")
MODEL_DIRS = ("models/v3", "models/long_range", "models/long_range_v2")
COLAB_FILES = ("train_long_range_v21_colab.ipynb", "README.md", "requirements-colab.txt")


def encode(values: np.ndarray):
    """(array, dtype label): int16 x10 if every finite value round-trips exactly, else float64."""
    finite = np.isfinite(values)
    scaled = np.round(np.where(finite, values, 0.0) * 10.0)
    if (np.abs(scaled[finite]) < 32767).all() and (scaled[finite] / 10.0 == values[finite]).all():
        out = scaled.astype(np.int16)
        out[~finite] = SENTINEL
        return out, "int16x10"
    return values.astype(np.float64), "float64"


def export_cell(con, cid, index, out_dir: Path):
    columns = ",".join(f'"{c}"' for c in DATA_COLUMNS)
    raw = pd.read_sql_query(f"SELECT timestamp,{columns} FROM hourly WHERE cell_id=? ORDER BY timestamp", con,
                            params=(cid,))
    raw["timestamp"] = pd.to_datetime(raw.timestamp)
    if raw.timestamp.duplicated().any():
        raise ValueError(f"duplicate timestamps: {cid}")
    frame = raw.set_index("timestamp").reindex(index)
    arrays, kinds = {}, {}
    original = {}
    for c in DATA_COLUMNS:
        v = frame[c].to_numpy(dtype=np.float64)
        original[c] = v
        arrays[c], kinds[c] = encode(v)
    path = out_dir / f"hourly_{cid}.npz"
    np.savez_compressed(path, start=np.array(index[0].strftime("%Y-%m-%dT%H:%M")), n_hours=np.array(len(index)),
                        **arrays)
    with np.load(path, allow_pickle=False) as npz:
        decoded = decode_npz(npz)
    for c in DATA_COLUMNS:  # exact round trip (NaN positions and bits of every finite value)
        a, b = original[c], decoded[c]
        if not (np.array_equal(np.isnan(a), np.isnan(b)) and np.array_equal(a[~np.isnan(a)], b[~np.isnan(b)])):
            raise AssertionError(f"round trip failed for {cid}/{c}")
    years = index.year.to_numpy()
    audit = {}
    for c in DATA_COLUMNS:
        v = original[c]
        ok = np.isfinite(v)
        audit[c] = {int(y): (int(ok[years == y].sum()), float(v[(years == y) & ok].sum()),
                             float((v[(years == y) & ok] ** 2).sum()), int((~ok[years == y]).sum()))
                    for y in np.unique(years)}
    frame_out = pd.DataFrame({"timestamp": index, **decoded})
    info = {"rows_in_db": int(len(raw)), "nan": {c: int(np.isnan(original[c]).sum()) for c in DATA_COLUMNS},
            "dtype": kinds, "sha256": sha256_file(path), "bytes": path.stat().st_size,
            "canonical_sha256": canonical_sha({cid: frame_out})}
    return info, audit


def build_code_zip(path: Path):
    files = [BACKEND / f for f in CODE_FILES]
    for d in MODEL_DIRS:
        files += sorted(p for p in (BACKEND / d).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in files:
            z.write(f, "backend/" + f.relative_to(BACKEND).as_posix())
    digest = sha256_file(path)
    path.with_suffix(".zip.sha256").write_text(f"{digest}  {path.name}\n", encoding="utf-8")
    return {"file": path.name, "sha256": digest, "bytes": path.stat().st_size, "members": len(files)}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data", type=Path, default=BACKEND / "data/history/cells_history.db")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--cells", type=int, default=0, help="smoke: first N cells only")
    p.add_argument("--no-code", action="store_true", help="skip code.zip and the notebooks/colab_train_v21/ copies")
    args = p.parse_args(argv)
    data_dir = args.out / "data"
    if data_dir.exists() and any(data_dir.iterdir()):
        p.error(f"{data_dir} exists and is not empty; exports are never overwritten")
    if args.out.resolve().is_relative_to(ROOT.resolve()):
        p.error("export must live outside the project folder")
    data_dir.mkdir(parents=True, exist_ok=True)
    stat = args.data.stat()
    with connect(args.data) as con:
        first, last = con.execute("SELECT MIN(timestamp), MAX(timestamp) FROM hourly").fetchone()
        cells = pd.read_sql_query("SELECT cell_id,lat,lon,elevation,source FROM cells ORDER BY cell_id", con)
        coverage = pd.read_sql_query("SELECT cell_id, MIN(timestamp) AS first_hour, MAX(timestamp) AS last_hour, "
                                     "COUNT(*) AS rows FROM hourly GROUP BY cell_id", con).set_index("cell_id")
        if args.cells:
            cells = cells.head(args.cells)
        index = pd.date_range(pd.Timestamp(first), pd.Timestamp(last), freq="h")
        files, totals = {}, {}
        for i, cid in enumerate(cells.cell_id):
            info, audit = export_cell(con, cid, index, data_dir)
            files[f"hourly_{cid}.npz"] = info
            for c, years in audit.items():
                for y, (n, s, s2, nan) in years.items():
                    t = totals.setdefault(c, {}).setdefault(y, [0, 0.0, 0.0, 0])
                    t[0] += n
                    t[1] += s
                    t[2] += s2
                    t[3] += nan
            print(f"[{i + 1}/{len(cells)}] {cid}: {info['bytes'] / 1e6:.2f} MB", flush=True)
    year_audit = {c: {y: {"mean": round(s / n, 4) if n else None,
                          "std": round(float(np.sqrt(max(s2 / n - (s / n) ** 2, 0))), 4) if n else None,
                          "nan": nan} for y, (n, s, s2, nan) in sorted(ys.items())} for c, ys in totals.items()}
    records = []
    for r in cells.itertuples():
        cov = coverage.loc[r.cell_id]
        records.append({"cell_id": r.cell_id, "lat": float(r.lat), "lon": float(r.lon),
                        "elevation": float(r.elevation), "source": r.source, "first_hour": cov.first_hour,
                        "last_hour": cov.last_hour, "rows": int(cov.rows)})
    (data_dir / "cells.json").write_text(json.dumps(records, indent=1), encoding="utf-8")
    files["cells.json"] = {"sha256": sha256_file(data_dir / "cells.json"),
                           "bytes": (data_dir / "cells.json").stat().st_size}
    flagged = {f: [c for c, k in v["dtype"].items() if k != "int16x10"] for f, v in files.items() if "dtype" in v}
    manifest = {"created_at": datetime.now(timezone.utc).isoformat(),
                "db": {"path": str(args.data.resolve()), "bytes": stat.st_size,
                       "mtime": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()},
                "first_hour": str(index[0]), "last_hour": str(index[-1]), "n_hours": len(index),
                "columns": list(DATA_COLUMNS), "encoding": "int16 = round(value*10), -32768 = NaN; decode /10.0",
                "float64_fallback": {f: c for f, c in flagged.items() if c}, "files": files,
                "canonical_sha256_all": hashlib.sha256("".join(files[f]["canonical_sha256"] for f in sorted(files)
                                                               if "canonical_sha256" in files[f]).encode()).hexdigest(),
                "year_audit": year_audit,
                "export_code_sha256": sha256_file(Path(__file__).resolve())}
    if not args.no_code:
        manifest["code_zip"] = build_code_zip(args.out / "code.zip")
        for name in COLAB_FILES:
            src = ROOT / "notebooks" / "colab_train_v21" / name
            if src.exists():
                shutil.copy2(src, args.out / name)
    (data_dir / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    size = sum(f.stat().st_size for f in data_dir.iterdir())
    print(json.dumps({"out": str(args.out), "cells": len(records), "data_mb": round(size / 1e6, 1),
                      "code_zip_mb": round(manifest.get("code_zip", {}).get("bytes", 0) / 1e6, 1),
                      "float64_fallback": manifest["float64_fallback"]}, indent=1))


if __name__ == "__main__":
    main()
