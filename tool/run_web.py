"""Serve Flutter web and the API at one origin, without changing app settings."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser

ROOT = Path(__file__).resolve().parents[1]


def open_when_ready(url: str) -> None:
    for _ in range(120):
        try:
            with urllib.request.urlopen(url + "/live", timeout=1) as response:
                if response.status == 200:
                    webbrowser.open(url)
                    return
        except OSError:
            time.sleep(0.5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--open", action="store_true", help="Open the browser when ready")
    parser.add_argument("--build", action="store_true", help="Rebuild the web bundle first")
    parser.add_argument("--flutter", default=shutil.which("flutter") or "D:/flutter/bin/flutter.bat")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("Port must be between 1 and 65535")
    # Fail before building or starting ingestion; never attach to an unknown server.
    try:
        with socket.socket() as probe:
            probe.bind((args.host, args.port))
    except OSError as exc:
        parser.error(f"Port {args.port} is unavailable; use --port <free-port>: {exc}")
    bundle = ROOT / "build/web/main.dart.js"
    stamp = ROOT / "build/web/.same-origin-build"
    digest = hashlib.sha256(bundle.read_bytes()).hexdigest() if bundle.is_file() else None
    verified = ((ROOT / "build/web/index.html").is_file() and stamp.is_file()
                and stamp.read_text(encoding="ascii") == digest)
    if args.build or not verified:
        subprocess.run([args.flutter, "build", "web", "--release", "--no-tree-shake-icons",
                        "--no-web-resources-cdn", "--no-wasm-dry-run"], cwd=ROOT, check=True)
        stamp.write_text(hashlib.sha256(bundle.read_bytes()).hexdigest(), encoding="ascii")
    os.environ["WEB_DIST"] = str(ROOT / "build/web")
    url_host = "127.0.0.1" if args.host == "0.0.0.0" else args.host
    url = f"http://{url_host}:{args.port}"
    # Web and API share one origin, so browsers need no cross-origin access (never `*` by default).
    os.environ.setdefault("CORS_ORIGINS", ",".join(dict.fromkeys(
        [url, f"http://127.0.0.1:{args.port}", f"http://localhost:{args.port}"])))
    sys.path.insert(0, str(ROOT / "backend"))
    import uvicorn
    from main import app

    print(f"Sky Weather: {url} (web + API). Ctrl+C to stop.", flush=True)
    if args.open:
        threading.Thread(target=open_when_ready, args=(url,), daemon=True).start()
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
