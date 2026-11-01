"""Focused startup checks, without a real server or database."""
import socket
import sys
import hashlib
import os
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from tool import run_web


@pytest.mark.parametrize('verified', [False, True])
def test_only_reuses_verified_same_origin_bundle(tmp_path, monkeypatch, verified):
    web = tmp_path / 'build/web'
    web.mkdir(parents=True)
    (web / 'index.html').write_text('web', encoding='ascii')
    bundle = web / 'main.dart.js'
    bundle.write_bytes(b'old bundle')
    stamp = web / '.same-origin-build'
    if verified:
        stamp.write_text(hashlib.sha256(bundle.read_bytes()).hexdigest(), encoding='ascii')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    monkeypatch.setattr(run_web, 'ROOT', tmp_path)
    monkeypatch.setattr(sys, 'argv', ['run_web.py', '--port', str(port)])
    monkeypatch.setitem(sys.modules, 'main', SimpleNamespace(app=object()))
    import uvicorn
    serve = Mock()
    monkeypatch.setattr(uvicorn, 'run', serve)
    monkeypatch.setenv('WEB_DIST', '')
    monkeypatch.setenv('CORS_ORIGINS', 'placeholder')   # recorded so the value set by main() is undone
    monkeypatch.delenv('CORS_ORIGINS')
    build = Mock(side_effect=lambda *args, **kwargs: bundle.write_bytes(b'same-origin bundle'))
    monkeypatch.setattr(run_web.subprocess, 'run', build)
    run_web.main()
    assert build.call_count == (0 if verified else 1)
    if not verified:
        assert not any('API_BASE_URL' in arg for arg in build.call_args.args[0])
    assert stamp.read_text(encoding='ascii') == hashlib.sha256(bundle.read_bytes()).hexdigest()
    serve.assert_called_once()
    # Same-origin launcher: CORS is limited to its own origin, never the API default `*`.
    assert os.environ['CORS_ORIGINS'] == f'http://127.0.0.1:{port},http://localhost:{port}'


def test_busy_port_fails_before_build_or_import(monkeypatch):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        monkeypatch.setattr(sys, 'argv', ['run_web.py', '--port', str(listener.getsockname()[1]), '--build'])
        build = Mock()
        monkeypatch.setattr(run_web.subprocess, 'run', build)
        with pytest.raises(SystemExit) as error:
            run_web.main()
        assert error.value.code == 2
        build.assert_not_called()


def test_browser_opens_only_after_api_ready(monkeypatch):
    response = Mock()
    response.status = 200
    response.__enter__ = Mock(return_value=response)
    response.__exit__ = Mock(return_value=False)
    monkeypatch.setattr(run_web.urllib.request, 'urlopen', Mock(return_value=response))
    opened = Mock()
    monkeypatch.setattr(run_web.webbrowser, 'open', opened)
    run_web.open_when_ready('http://127.0.0.1:8000')
    opened.assert_called_once_with('http://127.0.0.1:8000')


def test_invalid_port_fails(monkeypatch):
    monkeypatch.setattr(sys, 'argv', ['run_web.py', '--port', '0'])
    with pytest.raises(SystemExit) as error:
        run_web.main()
    assert error.value.code == 2
