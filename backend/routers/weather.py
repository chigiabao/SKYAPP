"""Weather API endpoints (/weather/...), assembling sub-routers."""
from fastapi import APIRouter

from routers import weather_ai, weather_endpoints, weather_map
from routers.weather_climatology import _climatology_of, _history_span
from routers.weather_map import _replay_ai_rain
from routers.weather_series import _own_issue

router = APIRouter(prefix="/weather", tags=["weather"])
router.include_router(weather_endpoints.router)
router.include_router(weather_ai.router)
router.include_router(weather_map.router)


def invalidate_climatology():
    """Drop the cached climatology so the next request recomputes it (call after ingesting new rows)."""
    _climatology_of.cache_clear()
    _history_span.cache_clear()
    _replay_ai_rain.cache_clear()
    _own_issue.cache_clear()
