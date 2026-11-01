"""Audit regressions: bounded reset parsing and private default access logs."""
import asyncio
import io
import logging

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from uvicorn.logging import AccessFormatter

import main  # noqa: F401 - installs the application access-log filter
import password_reset as reset


@pytest.mark.parametrize("path", ["request", "confirm"])
@pytest.mark.parametrize("declared_length", [None, "1", "999999"])
def test_reset_limits_actual_stream_before_json_parse(monkeypatch, path, declared_length):
    app = FastAPI()
    app.include_router(reset.router)
    consumed = []

    def forbidden_parse(*args, **kwargs):
        pytest.fail("Oversized body reached the JSON parser")

    async def body():
        for chunk in [b" " * reset.MAX_BODY_BYTES, b"x", b"not consumed"]:
            consumed.append(chunk)
            yield chunk

    async def send():
        headers = {"Content-Type": "application/json"}
        if declared_length is not None:
            headers["Content-Length"] = declared_length
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as api:
            return await api.post(f"/auth/password-reset/{path}", content=body(), headers=headers)

    monkeypatch.setattr(reset.json, "loads", forbidden_parse)
    response = asyncio.run(send())
    assert response.status_code == 413 and len(consumed) == 2


@pytest.mark.parametrize("path", ["request", "confirm"])
def test_reset_byte_boundary_and_invalid_json_do_not_echo_input(path):
    app = FastAPI()
    app.include_router(reset.router)
    with TestClient(app) as api:
        boundary = api.post(f"/auth/password-reset/{path}", content=b" " * (reset.MAX_BODY_BYTES - 2) + b"[]")
        assert boundary.status_code == 422
        malformed = api.post(f"/auth/password-reset/{path}", content=b'{"secret":"private-token",')
        assert malformed.status_code == 422 and "private-token" not in malformed.text


@pytest.mark.parametrize("target", [
    "/route?from_lat=10.790912345&from_lon=106.631312345",
    "/route/?from_lat=10.790912345&to_lon=106.631312345",
    "/api/route?from_lat=10.790912345&to_lon=106.631312345",
    "/route?%66rom_lat=10.790912345&to_lon=106.631312345",
])
def test_default_uvicorn_access_logger_redacts_query_before_formatting(target):
    output = io.StringIO()
    handler = logging.StreamHandler(output)
    handler.setFormatter(AccessFormatter('%(client_addr)s - "%(request_line)s" %(status_code)s', use_colors=False))
    logger = logging.getLogger("uvicorn.access")
    logger.addHandler(handler)
    try:
        record = logger.makeRecord(logger.name, logging.INFO, __file__, 0, '%s - "%s %s HTTP/%s" %d',
                                   ("127.0.0.1:1234", "GET", target, "1.1", 405), None)
        logger.handle(record)
    finally:
        logger.removeHandler(handler)
    logged = output.getvalue()
    assert "GET " + target.split("?", 1)[0] + " HTTP/1.1" in logged
    assert "405" in logged
    assert "10.790912345" not in logged and "106.631312345" not in logged and "?" not in logged
