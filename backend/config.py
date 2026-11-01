"""Shared serving policy constants (imported by main and routers, so routers never import main)."""

CELL_FRESH_HOURS = 3   # /health and live AI: a series is fresh if it has an hour within this many hours of now
