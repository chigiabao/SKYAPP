"""
Compare v3 current (lgbm-hcmc-global-v3-20261023) with v3 backup (lgbm-hcmc-global-v3-20261017)
on identical val_select and test rows.

Rule:
  - Models are compared on identical val_select rows (chronological validation selection window).
  - Selection rule for serving is strictly determined on val_select (in-sample for promotion, NOT test).
  - Test set is evaluated once for unbiased reporting.

Outputs:
  - backend/models/evaluation/compare_v3_20261023.json
  - backend/models/evaluation/compare_v3_20261023.csv
  - Updates backend/models/v3/serving_policy_v3.json with field "selection_rule"
"""
from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import sys

import joblib
import numpy as np
import pandas as pd

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "scripts"))
import ai_model  # noqa: E402
import train_global_v3 as T  # noqa: E402

CURRENT_DIR = BACKEND / "models/v3"
BACKUP_DIR = Path("D:/wether_app/build/model-archive/v3_backup_20261023")
OUT_DIR = BACKEND / "models/evaluation"
DB_PATH = BACKEND / "data/history/cells_history.db"

HORIZONS = [1, 3, 6]


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Loading models and metadata...")
    curr_meta = json.load(open(CURRENT_DIR / "metadata_v3.json", encoding="utf-8"))
    back_meta = json.load(open(BACKUP_DIR / "metadata_v3.json", encoding="utf-8"))
    curr_ext = json.load(open(CURRENT_DIR / "extension_v3.json", encoding="utf-8"))
    back_ext = json.load(open(BACKUP_DIR / "extension_v3.json", encoding="utf-8"))
    curr_policy = json.load(open(CURRENT_DIR / "serving_policy_v3.json", encoding="utf-8"))
    back_policy_path = BACKUP_DIR / "serving_policy_v3.json"
    back_policy = json.load(open(back_policy_path, encoding="utf-8")) if back_policy_path.exists() else {}

    curr_cols = json.load(open(CURRENT_DIR / "feature_columns.json", encoding="utf-8"))
    back_cols = json.load(open(BACKUP_DIR / "feature_columns.json", encoding="utf-8"))
    static = json.load(open(CURRENT_DIR / "cell_static.json", encoding="utf-8"))

    curr_models = {
        k: joblib.load(CURRENT_DIR / f"{n}_model_{h}h.pkl")
        for h in HORIZONS
        for k, n in [(f"temp_{h}h", "temperature"), (f"rain_{h}h", "rain")]
    }
    back_models = {
        k: joblib.load(BACKUP_DIR / f"{n}_model_{h}h.pkl")
        for h in HORIZONS
        for k, n in [(f"temp_{h}h", "temperature"), (f"rain_{h}h", "rain")]
    }

    curr_thr = curr_meta["rain_decision_threshold"]
    back_thr = back_meta["rain_decision_threshold"]

    # 1. Load val_select from SQLite database
    print(f"Loading val_select rows from {DB_PATH}...")
    con = sqlite3.connect(str(DB_PATH))
    val_parts = []
    for _cid, g in T._cell_frames(con, static, quick=False, cells=None):
        _train, _val_es, val_sel, _test = T.split(g)
        val_parts.append(val_sel)
    con.close()

    val_all = pd.concat(val_parts, ignore_index=True)
    val_start = pd.Timestamp("2025-01-01 00:00:00")
    val_end = pd.Timestamp("2025-09-23 23:00:00")
    val_all = val_all[
        (val_all.timestamp >= val_start)
        & (val_all.timestamp + pd.Timedelta(hours=6) <= val_end)
    ]
    print(f"Loaded {len(val_all):,} identical rows for val_select comparison.")

    # Compute val_select metrics by horizon
    val_metrics = {}
    val_cell_rows = []
    for h in HORIZONS:
        k = f"{h}h"
        y_t = val_all[f"temp_target_{k}"].values
        y_r = val_all[f"rain_target_{k}"].values.astype(bool)

        xc = val_all[curr_cols].to_numpy(dtype=np.float32)
        c_pred_t = curr_models[f"temp_{k}"].predict(xc)
        c_pred_r = curr_models[f"rain_{k}"].predict(xc)
        c_t, c_r = ai_model.apply_policy(
            {"rain_calibration": curr_policy.get("rain_calibration", {})},
            h,
            val_all.cell_id.astype(str).values,
            c_pred_t,
            c_pred_r,
            val_all.temperature.values,
            val_all.precipitation.values,
        )

        xb = val_all[back_cols].to_numpy(dtype=np.float32)
        b_pred_t = back_models[f"temp_{k}"].predict(xb)
        b_pred_r = back_models[f"rain_{k}"].predict(xb)
        b_t, b_r = ai_model.apply_policy(
            {"rain_calibration": back_policy.get("rain_calibration", {})},
            h,
            val_all.cell_id.astype(str).values,
            b_pred_t,
            b_pred_r,
            val_all.temperature.values,
            val_all.precipitation.values,
        )

        p_t = val_all.temperature.values
        p_r = (val_all.precipitation.values > ai_model.RAIN_THRESHOLD_MM)

        c_mae = float(np.abs(y_t - c_t).mean())
        b_mae = float(np.abs(y_t - b_t).mean())
        p_mae = float(np.abs(y_t - p_t).mean())

        c_f1 = T.f1(y_r, c_r >= curr_thr[k])
        b_f1 = T.f1(y_r, b_r >= back_thr[k])
        p_f1 = T.f1(y_r, p_r)

        c_brier = float(((c_r - y_r) ** 2).mean())
        b_brier = float(((b_r - y_r) ** 2).mean())

        val_metrics[k] = {
            "temperature_mae": {
                "current": c_mae,
                "backup": b_mae,
                "persistence": p_mae,
                "diff": c_mae - b_mae,
                "winner": "current" if c_mae < b_mae else "backup",
            },
            "rain_f1": {
                "current": c_f1,
                "backup": b_f1,
                "persistence": p_f1,
                "diff": c_f1 - b_f1,
                "winner": "current" if c_f1 > b_f1 else "backup",
            },
            "rain_brier": {
                "current": c_brier,
                "backup": b_brier,
                "diff": c_brier - b_brier,
                "winner": "current" if c_brier < b_brier else "backup",
            },
        }

        # Per cell metrics on val_select
        val_df = pd.DataFrame({
            "cell_id": val_all.cell_id.astype(str).values,
            "y_t": y_t, "y_r": y_r,
            "c_t": c_t, "b_t": b_t, "p_t": p_t,
            "c_r": c_r, "b_r": b_r, "p_r": p_r,
        })
        for cid, grp in val_df.groupby("cell_id"):
            val_cell_rows.append({
                "split": "val_select",
                "horizon": k,
                "cell_id": cid,
                "curr_temp_mae": float(np.abs(grp.y_t - grp.c_t).mean()),
                "back_temp_mae": float(np.abs(grp.y_t - grp.b_t).mean()),
                "curr_rain_f1": T.f1(grp.y_r.values, grp.c_r.values >= curr_thr[k]),
                "back_rain_f1": T.f1(grp.y_r.values, grp.b_r.values >= back_thr[k]),
                "curr_rain_brier": float(((grp.c_r - grp.y_r) ** 2).mean()),
                "back_rain_brier": float(((grp.b_r - grp.y_r) ** 2).mean()),
                "persistence_temp_mae": float(np.abs(grp.y_t - grp.p_t).mean()),
                "persistence_rain_f1": T.f1(grp.y_r.values, grp.p_r.values),
            })

    # 2. Test split comparison from per_cell_metrics.csv
    print("Loading test split metrics from per_cell_metrics.csv...")
    curr_pc = pd.read_csv(CURRENT_DIR / "per_cell_metrics.csv")
    curr_pc = curr_pc[curr_pc["model"] == "full"]
    back_pc = pd.read_csv(BACKUP_DIR / "per_cell_metrics.csv")
    back_pc = back_pc[back_pc["model"] == "full"]

    test_metrics = {}
    test_cell_rows = []
    for h in HORIZONS:
        k = f"{h}h"
        c_h = curr_pc[curr_pc["horizon"] == k].set_index("cell_id")
        b_h = back_pc[back_pc["horizon"] == k].set_index("cell_id")
        cells = sorted(set(c_h.index) & set(b_h.index))
        c_h, b_h = c_h.loc[cells], b_h.loc[cells]

        c_mae = float(c_h["mae_v3"].mean())
        b_mae = float(b_h["mae_v3"].mean())
        p_mae = float(c_h["mae_persistence"].mean())
        cl_mae = float(c_h["mae_climatology"].mean())

        c_f1 = float(c_h["f1_v3"].mean())
        b_f1 = float(b_h["f1_v3"].mean())
        p_f1 = float(c_h["f1_persistence"].mean())
        cl_f1 = float(c_h["f1_climatology"].mean())

        c_brier = float(c_h["brier_v3"].mean())
        b_brier = float(b_h["brier_v3"].mean())
        cl_brier = float(c_h["brier_climatology"].mean())

        c_cov = curr_ext.get("interval", {}).get("test", {}).get(k, {}).get("cov_mean")
        b_cov = back_ext.get("interval", {}).get("test", {}).get(k, {}).get("cov_mean")

        test_metrics[k] = {
            "temperature_mae": {
                "current": c_mae,
                "backup": b_mae,
                "persistence": p_mae,
                "climatology": cl_mae,
                "diff": c_mae - b_mae,
                "winner_on_test": "current" if c_mae < b_mae else "backup",
            },
            "rain_f1": {
                "current": c_f1,
                "backup": b_f1,
                "persistence": p_f1,
                "climatology": cl_f1,
                "diff": c_f1 - b_f1,
                "winner_on_test": "current" if c_f1 > b_f1 else "backup",
            },
            "rain_brier": {
                "current": c_brier,
                "backup": b_brier,
                "climatology": cl_brier,
                "diff": c_brier - b_brier,
                "winner_on_test": "current" if c_brier < b_brier else "backup",
            },
            "interval_coverage": {
                "current": c_cov,
                "backup": b_cov,
                "diff": (c_cov - b_cov) if c_cov and b_cov else None,
            },
        }

        for cid in cells:
            test_cell_rows.append({
                "split": "test",
                "horizon": k,
                "cell_id": cid,
                "curr_temp_mae": float(c_h.loc[cid, "mae_v3"]),
                "back_temp_mae": float(b_h.loc[cid, "mae_v3"]),
                "curr_rain_f1": float(c_h.loc[cid, "f1_v3"]),
                "back_rain_f1": float(b_h.loc[cid, "f1_v3"]),
                "curr_rain_brier": float(c_h.loc[cid, "brier_v3"]),
                "back_rain_brier": float(b_h.loc[cid, "brier_v3"]),
                "persistence_temp_mae": float(c_h.loc[cid, "mae_persistence"]),
                "persistence_rain_f1": float(c_h.loc[cid, "f1_persistence"]),
            })

    # 3. Formulate selection rule based on val_select
    selection_rule = {
        "rule_description": "Per (target, horizon), booster version is selected based on superior metric on val_select. Test metrics are strictly held out for final reporting.",
        "decisions": {},
        "booster_source": {},
    }

    for h in HORIZONS:
        k = f"{h}h"
        temp_win = val_metrics[k]["temperature_mae"]["winner"]
        rain_win = val_metrics[k]["rain_f1"]["winner"]

        selection_rule["decisions"][f"temperature_{k}"] = {
            "selected": temp_win,
            "metric": "mae",
            "val_select_current_mae": val_metrics[k]["temperature_mae"]["current"],
            "val_select_backup_mae": val_metrics[k]["temperature_mae"]["backup"],
            "test_current_mae": test_metrics[k]["temperature_mae"]["current"],
            "test_backup_mae": test_metrics[k]["temperature_mae"]["backup"],
        }
        selection_rule["booster_source"][f"temperature_{k}"] = (
            "v3" if temp_win == "current" else "v3_backup"
        )

        selection_rule["decisions"][f"rain_{k}"] = {
            "selected": rain_win,
            "metric": "f1",
            "val_select_current_f1": val_metrics[k]["rain_f1"]["current"],
            "val_select_backup_f1": val_metrics[k]["rain_f1"]["backup"],
            "test_current_f1": test_metrics[k]["rain_f1"]["current"],
            "test_backup_f1": test_metrics[k]["rain_f1"]["backup"],
        }
        selection_rule["booster_source"][f"rain_{k}"] = (
            "v3" if rain_win == "current" else "v3_backup"
        )

    # Output full comparison JSON
    full_comparison = {
        "models": {
            "current": curr_meta.get("model_version"),
            "backup": back_meta.get("model_version"),
        },
        "val_select_evaluation": val_metrics,
        "test_evaluation": test_metrics,
        "selection_rule": selection_rule,
    }

    json_path = OUT_DIR / "compare_v3_20261023.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(full_comparison, f, indent=2)

    # Output CSV combining val_select and test per-cell data
    csv_path = OUT_DIR / "compare_v3_20261023.csv"
    pd.DataFrame(val_cell_rows + test_cell_rows).to_csv(csv_path, index=False)

    # 4. Update serving_policy_v3.json
    curr_policy["selection_rule"] = selection_rule
    policy_path = CURRENT_DIR / "serving_policy_v3.json"
    with open(policy_path, "w", encoding="utf-8") as f:
        json.dump(curr_policy, f, indent=2)

    print(f"\nWrote results to:\n  - {json_path}\n  - {csv_path}\n  - {policy_path}")
    print("\n=== VAL_SELECT RESULTS & SELECTION DECISIONS ===")
    for k, v in selection_rule["decisions"].items():
        print(f"  {k:16s}: Winner={v['selected']:7s} | Val: curr={v.get('val_select_current_mae') or v.get('val_select_current_f1'):.4f} vs back={v.get('val_select_backup_mae') or v.get('val_select_backup_f1'):.4f} | Test: curr={v.get('test_current_mae') or v.get('test_current_f1'):.4f} vs back={v.get('test_backup_mae') or v.get('test_backup_f1'):.4f}")


if __name__ == "__main__":
    main()
