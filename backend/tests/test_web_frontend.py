"""The compiled web bundle and API share an origin; tests never run ingestion."""
import os
from pathlib import Path
import subprocess
import sys

BACKEND = Path(__file__).resolve().parents[1]


def test_web_and_api_share_server_without_lifespan(tmp_path):
    (tmp_path / "index.html").write_text("<title>Sky Weather</title>", encoding="utf-8")
    (tmp_path / "flutter_bootstrap.js").write_text("// bundle", encoding="utf-8")
    secret = tmp_path.parent / "private.txt"
    secret.write_text("not public", encoding="utf-8")
    result = subprocess.run([sys.executable, "-c", '''
from fastapi.testclient import TestClient
from main import app
client = TestClient(app)
root = client.get('/')
assert root.status_code == 200 and '<title>Sky Weather</title>' in root.text
assert root.headers['content-type'].startswith('text/html')
assert root.headers['cache-control'] == 'no-cache'
assert client.get('/flutter_bootstrap.js').text == '// bundle'
assert client.get('/live').json() == {'status': 'alive'}
for _ in range(5):
    assert client.get('/flutter_bootstrap.js').status_code == 200
assert client.get('/still-not-an-api').status_code == 404
assert client.get('/still-not-an-api').status_code == 429
'''], cwd=BACKEND, env={**os.environ, "WEB_DIST": str(tmp_path), "INGEST_ENABLED": "0",
                       "RATE_LIMIT_PER_MINUTE": "1"}, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_web_missing_assets_and_traversal(tmp_path):
    (tmp_path / "index.html").write_text("<title>Sky Weather</title>", encoding="utf-8")
    (tmp_path.parent / "private.txt").write_text("not public", encoding="utf-8")
    result = subprocess.run([sys.executable, "-c", '''
from fastapi.testclient import TestClient
from main import app
client = TestClient(app)
assert client.get('/missing.js').status_code == 404
assert client.get('/%2e%2e/private.txt').status_code == 404
assert client.get('/admin/not-a-route').status_code == 404
'''], cwd=BACKEND, env={**os.environ, "WEB_DIST": str(tmp_path), "INGEST_ENABLED": "0"},
        capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_invalid_web_dist_fails_clearly(tmp_path):
    result = subprocess.run([sys.executable, "-c", "import main"], cwd=BACKEND,
                            env={**os.environ, "WEB_DIST": str(tmp_path), "INGEST_ENABLED": "0"},
                            capture_output=True, text=True, timeout=30)
    assert result.returncode != 0
    assert "WEB_DIST must contain a compiled Flutter web index.html" in result.stderr
