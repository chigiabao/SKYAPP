"""Run the whole long-range v2.1 training on this machine instead of Google Colab.

Same chain as notebooks/colab_train_v21/train_long_range_v21_colab.ipynb, with resume:
  smoke (3 cells) -> dev -> final -> spatial -> test (exactly once, ledger) -> verify -> install.
Each finished step is skipped on the next run, so it is safe to stop (Ctrl+C) and start again.

Data is read straight from backend/data/history/cells_history.db (opened read-only by the trainer).
Runs live in D:\\wether_app\\v21_runs (outside the project). The verified artifact is copied to
backend/models/long_range_v21 only at the end; the routers keep serving v2 until you switch them.

  python backend/scripts/run_v21_local.py                # from sky_weather_app/
  python backend/scripts/run_v21_local.py --threads 6    # more cores (>4 passes --colab to the trainer)
  python backend/scripts/run_v21_local.py --smoke-only   # 3-cell check (~2-5 min), no real training
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
TRAINER = BACKEND / "scripts" / "train_long_range_v21.py"
DEFAULT_DATA = BACKEND / "data" / "history" / "cells_history.db"
DEFAULT_RUNS = BACKEND.parents[1] / "v21_runs"
INSTALL = BACKEND / "models" / "long_range_v21"
PROGRAM = "long_range_v21"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def manifest_ok(folder: Path) -> bool:
    lines = (folder / "MANIFEST.sha256").read_text(encoding="utf-8").splitlines()
    return all((folder / rel).is_file() and sha(folder / rel) == digest
               for digest, rel in (line.split("  ", 1) for line in lines if line.strip()))


def ledger_status(ledger: Path) -> list[str]:
    if not ledger.exists():
        return []
    entries = (json.loads(line) for line in ledger.read_text(encoding="utf-8").splitlines() if line.strip())
    return [e.get("status") for e in entries if e.get("program") == PROGRAM]


class Runner:
    def __init__(self, data: Path, threads: int, log: Path):
        self.base = [sys.executable, str(TRAINER), "--data", str(data), "--threads", str(threads)]
        if threads > 4:
            self.base.append("--colab")  # the trainer caps laptops at 4 threads unless told otherwise
        self.log = log

    def __call__(self, step: str, *args: str) -> None:
        cmd = [*self.base, *args]
        print(f"\n=== {step}: {' '.join(cmd)}", flush=True)
        start = time.time()
        flags = subprocess.BELOW_NORMAL_PRIORITY_CLASS if os.name == "nt" else 0  # keep the laptop usable
        with open(self.log, "a", encoding="utf-8") as log:
            log.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} {step}: {' '.join(cmd)}\n")
            log.flush()
            proc = subprocess.Popen(cmd, cwd=BACKEND.parent, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, encoding="utf-8", errors="replace", creationflags=flags)
            for line in proc.stdout:
                print(line, end="", flush=True)
                log.write(line)
            code = proc.wait()
        minutes = (time.time() - start) / 60
        if code != 0:
            raise SystemExit(f"{step} thất bại (mã {code}) sau {minutes:.1f} phút. Xem log: {self.log}")
        print(f"=== {step} xong sau {minutes:.1f} phút", flush=True)


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")  # Windows consoles default to cp1252
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data", type=Path, default=DEFAULT_DATA)
    p.add_argument("--runs", type=Path, default=DEFAULT_RUNS)
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("--skip-smoke", action="store_true")
    p.add_argument("--smoke-only", action="store_true", help="only run the 3-cell smoke chain, then stop")
    p.add_argument("--no-install", action="store_true", help="do not copy the artifact into backend/models")
    args = p.parse_args()

    if not args.data.exists():
        raise SystemExit(f"Không thấy dữ liệu: {args.data}")
    runs = args.runs
    runs.mkdir(parents=True, exist_ok=True)
    dev, art, spatial = runs / "dev", runs / "long_range_v21", runs / "spatial"
    ledger = runs / "ledger" / "test_ledger.jsonl"
    ledger.parent.mkdir(exist_ok=True)
    run = Runner(args.data, args.threads, runs / "train.log")

    if not args.skip_smoke and not (runs / "smoke.ok").exists():
        smoke = runs / "smoke"
        if smoke.exists():
            shutil.rmtree(smoke)
        s_art, s_ledger = smoke / "art", smoke / "ledger.jsonl"  # own ledger: never the real one
        run("smoke dev", "--phase", "dev", "--smoke", "--cells", "3", "--out", str(smoke / "dev"))
        run("smoke final", "--phase", "final", "--smoke", "--cells", "3",
            "--selection", str(smoke / "dev" / "dev_selection.json"), "--ledger", str(s_ledger), "--out", str(s_art))
        run("smoke spatial", "--phase", "spatial", "--smoke", "--out", str(s_art),
            "--spatial-dir", str(smoke / "spatial"))
        run("smoke test", "--phase", "test", "--smoke", "--out", str(s_art),
            "--spatial-dir", str(smoke / "spatial"), "--ledger", str(s_ledger))
        shutil.rmtree(smoke)
        (runs / "smoke.ok").write_text(time.strftime("%Y-%m-%d %H:%M:%S"), encoding="utf-8")
    if args.smoke_only:
        print("Smoke OK. Chạy lại không có --smoke-only để huấn luyện đầy đủ.")
        return

    if (dev / "dev_selection.json").exists():
        print("Đã có dev_selection.json -> bỏ qua dev")
    else:
        if dev.exists():
            shutil.rmtree(dev)  # unfinished dev run: no selection file was written
        run("dev", "--phase", "dev", "--out", str(dev))

    if (art / "MANIFEST.sha256").exists():
        if not manifest_ok(art):
            raise SystemExit(f"{art} không khớp MANIFEST.sha256: đổi tên thư mục đó rồi chạy lại")
        print("Đã có artifact final (MANIFEST khớp) -> bỏ qua final")
    else:
        if art.exists():
            raise SystemExit(f"{art} còn dở dang từ lần trước: đổi tên thư mục đó rồi chạy lại")
        run("final", "--phase", "final", "--selection", str(dev / "dev_selection.json"),
            "--ledger", str(ledger), "--out", str(art))

    run("spatial", "--phase", "spatial", "--out", str(art), "--spatial-dir", str(spatial))  # resumes per fold

    status = ledger_status(ledger)
    if "completed" in status:
        print("Test đã được chấm (ledger: completed) -> không chấm lại")
    elif "started" in status:
        raise SystemExit("Ledger ghi test đã BẮT ĐẦU nhưng chưa xong. Theo quy tắc chấm một lần, không chấm lại; "
                         "xem notebooks/colab_train_v21/README.md mục 'Sự cố khi chấm test'.")
    else:
        run("test", "--phase", "test", "--out", str(art), "--spatial-dir", str(spatial), "--ledger", str(ledger))

    run("verify", "--phase", "verify", "--out", str(art))

    if args.no_install:
        return
    if INSTALL.exists():
        print(f"{INSTALL} đã tồn tại -> không ghi đè. Xoá/đổi tên thư mục đó nếu muốn cài bản mới.")
    else:
        shutil.copytree(art, INSTALL)
        print(f"Đã chép artifact vào {INSTALL}. App vẫn dùng v2 cho tới khi đổi import sang long_range_model_v21.")


if __name__ == "__main__":
    main()
