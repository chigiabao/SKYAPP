"""
In-memory per-IP token-bucket rate limit for the public API (pure ASGI middleware, no dependency).

Each client IP gets a bucket of `per_minute` tokens refilled continuously at per_minute/60 per second;
a request spends one token, an empty bucket answers 429 with Retry-After. Health probes are never limited.
The client IP is the socket peer; with trust_proxy the right-most X-Forwarded-For entry is used instead
(the one appended by our own reverse proxy - left-most entries are client-controlled and spoofable).
State is per process: with several workers/replicas each keeps its own buckets.
The login endpoint keeps its own DB-backed lockout; this limiter only adds a coarse outer bound.
"""
import json
import math
from collections import OrderedDict
import threading
import time

import os

EXEMPT_PATHS = frozenset({"/live", "/health", "/ready"})
MAX_TRACKED_CLIENTS = 10_000


def client_ip_from_scope(scope: dict, trust_proxy: bool = False) -> str:
    """Extract client IP from an ASGI scope; with trust_proxy=True, uses the right-most X-Forwarded-For hop."""
    if trust_proxy:
        for name, value in scope.get("headers") or ():
            if name.lower() == b"x-forwarded-for":
                hops = [h.strip() for h in value.decode("latin-1").split(",") if h.strip()]
                if hops:
                    return hops[-1]
    client = scope.get("client")
    return client[0] if client else "?"


def client_ip_from_request(request, trust_proxy: bool | None = None) -> str:
    """Extract client IP from a Request or scope; with trust_proxy, uses right-most X-Forwarded-For hop."""
    if trust_proxy is None:
        trust_proxy = os.environ.get("TRUST_PROXY", "").strip().lower() in ("1", "true", "yes")

    if hasattr(request, "scope"):
        return client_ip_from_scope(request.scope, trust_proxy=trust_proxy)
    if isinstance(request, dict):
        return client_ip_from_scope(request, trust_proxy=trust_proxy)

    if trust_proxy:
        headers = getattr(request, "headers", None)
        if headers:
            xff = headers.get("x-forwarded-for") or headers.get("X-Forwarded-For")
            if xff:
                hops = [h.strip() for h in xff.split(",") if h.strip()]
                if hops:
                    return hops[-1]

    client = getattr(request, "client", None)
    return getattr(client, "host", None) or "?"


class RateLimitMiddleware:
    def __init__(self, app, per_minute: int, trust_proxy: bool = False, clock=time.monotonic,
                 exempt_paths=EXEMPT_PATHS):
        self.app = app
        self.capacity = float(per_minute)
        self.rate = per_minute / 60.0   # tokens per second
        self.trust_proxy = trust_proxy
        self.clock = clock
        self.exempt_paths = frozenset(exempt_paths)
        # ip -> (tokens, last_refill), least recently used first (move_to_end on every request).
        self._buckets: OrderedDict[str, tuple[float, float]] = OrderedDict()
        self._lock = threading.Lock()

    def client_ip(self, scope) -> str:
        return client_ip_from_scope(scope, trust_proxy=self.trust_proxy)

    def _take(self, ip: str) -> float:
        """Spend one token; returns 0 when allowed, else seconds until a token is available."""
        now = self.clock()
        with self._lock:
            if ip not in self._buckets and len(self._buckets) >= MAX_TRACKED_CLIENTS:
                # Reclaim the least recently used bucket once it has fully refilled (forgetting it is then
                # lossless); otherwise every tracked client was active within one refill period.
                candidate, (tokens, last) = next(iter(self._buckets.items()))
                wait = (self.capacity - tokens) / self.rate - (now - last)
                if wait > 0:
                    return wait
                del self._buckets[candidate]
            tokens, last = self._buckets.get(ip, (self.capacity, now))
            if ip in self._buckets:
                self._buckets.move_to_end(ip)
            tokens = min(self.capacity, tokens + (now - last) * self.rate)
            if tokens >= 1:
                self._buckets[ip] = (tokens - 1, now)
                wait = 0.0
            else:
                self._buckets[ip] = (tokens, now)
                wait = (1 - tokens) / self.rate
        return wait

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path") in self.exempt_paths:
            await self.app(scope, receive, send)
            return
        wait = self._take(self.client_ip(scope))
        if not wait:
            await self.app(scope, receive, send)
            return
        body = json.dumps({"detail": "Quá nhiều yêu cầu, vui lòng thử lại sau ít giây."}).encode()
        await send({"type": "http.response.start", "status": 429, "headers": [
            (b"content-type", b"application/json"), (b"content-length", str(len(body)).encode()),
            (b"retry-after", str(max(1, math.ceil(wait))).encode())]})
        await send({"type": "http.response.body", "body": body})
