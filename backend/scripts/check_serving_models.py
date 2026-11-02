"""Validate packaged serving models without opening a database or training anything."""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import ai_model
import long_range_model_v2 as long_range


def check_models() -> dict:
    if not ai_model._load_v3():
        raise RuntimeError(f"Global V3 model unavailable: {ai_model._v3.get('error')}")
    if ai_model._v3.get("ext") is None:
        raise RuntimeError("V3 intervals/extension models are missing or incompatible")
    meta, models, _, _ = long_range._load(*long_range.artifact_revision())
    if set(models) != set(long_range.TARGETS):
        raise RuntimeError("Long-range model is missing serving targets")
    if long_range.interval_layer(meta["model_version"]) is None:
        raise RuntimeError("Long-range interval artifact is missing or incompatible")
    cells_path = Path(__file__).resolve().parents[1] / "data/locations/cells.json"
    cells = json.loads(cells_path.read_text(encoding="utf-8"))
    expected = {ai_model.canonical_cell_id(c["cell_id"]) for c in cells}
    if not expected.issubset(ai_model._v3["static"]) or not expected.issubset(meta["cell_static"]):
        raise RuntimeError("Packaged models do not cover every configured weather cell")
    return {"v3": ai_model._v3["meta"]["model_version"],
            "long_range": meta["model_version"], "cells": len(expected)}


if __name__ == "__main__":
    print(json.dumps(check_models(), sort_keys=True))
