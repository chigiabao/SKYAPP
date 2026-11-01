"""Run the Flutter API contract against real HTTP with an isolated synthetic DB."""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def serve(port: int, directory: str) -> None:
    os.environ["INGEST_ENABLED"] = "0"
    os.environ["RATE_LIMIT_PER_MINUTE"] = "0"
    sys.path.insert(0, str(ROOT / "backend"))
    sys.path.insert(0, str(ROOT / "backend" / "tests"))
    import pytest
    import uvicorn
    import main
    from conftest import freeze_now, point_app_at, synthetic_rows, write_db

    with pytest.MonkeyPatch.context() as patch:
        path = write_db(Path(directory) / "weather.db", synthetic_rows())
        point_app_at(patch, path)
        freeze_now(patch)
        uvicorn.run(main.app, host="127.0.0.1", port=port, lifespan="off")


def run(flutter: str) -> int:
    executable = shutil.which(flutter)
    if executable is None:
        raise RuntimeError(f"Flutter executable not found: {flutter}")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    log_path = ROOT / "build" / "backend-contract-api.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sky-contract-") as directory, log_path.open("w", encoding="utf-8") as log:
        server = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--serve", str(port),
                                   "--fixture-directory", directory],
                                  cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while True:
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"Contract backend failed to start; see {log_path}")
                try:
                    with urllib.request.urlopen(base + "/live", timeout=1) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.1)
            environment = {**os.environ, "CONTRACT_BACKEND": base}
            result = subprocess.run([executable, "test", "--no-pub", "test/backend_contract_test.dart"],
                                    cwd=ROOT, env=environment, check=False, timeout=300)
            return result.returncode
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--serve", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--fixture-directory", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.serve is not None:
        if args.fixture_directory is None:
            parser.error("--serve requires --fixture-directory")
        serve(args.serve, args.fixture_directory)
    else:
        raise SystemExit(run(args.flutter))
