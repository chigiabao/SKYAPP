"""
Pydantic models for API request/response.
"""
from pydantic import BaseModel, Field
from typing import List, Optional
from datetime import datetime


class WeatherFieldSource(BaseModel):
    source: str
    timestamp: datetime


class WeatherData(BaseModel):
    """Weather data for a single hour."""
    timestamp: datetime
    temperature: Optional[float] = None
    humidity: Optional[float] = None
    dew_point: Optional[float] = None
    apparent_temperature: Optional[float] = None
    precipitation_probability: Optional[float] = None
    precipitation: Optional[float] = None
    rain: Optional[float] = None
    weather_code: Optional[int] = None
    visibility: Optional[float] = None
    cloud_cover: Optional[float] = None
    surface_pressure: Optional[float] = None
    pressure_msl: Optional[float] = None
    wind_speed: Optional[float] = None
    wind_direction: Optional[float] = None
    wind_gusts: Optional[float] = None
    # Own AI probabilities on live /current and /hourly; event flags for historical reference hours.
    rain_probability: Optional[float] = None
    precipitation_median: Optional[float] = None
    # "observed" | "ai" | "forecast" (legacy reference) | "climatology" (replay)
    source: Optional[str] = None
    # AI provenance: input ends at issued_at, strictly before the current-hour target.
    issued_at: Optional[datetime] = None
    model_version: Optional[str] = None
    # Overrides the row source for supplementary current metrics only.
    field_sources: dict[str, WeatherFieldSource] = Field(default_factory=dict)
    uv_index: Optional[float] = None
    # Open-Meteo Air Quality (CAMS) at the same hour; null for climatology hours
    us_aqi: Optional[float] = None
    pm2_5: Optional[float] = None
    pm10: Optional[float] = None
    # Own long-range AI hours only: calibrated range (interval_level, e.g. 0.8 = 80 % range, NOT 80 %
    # accuracy); null where the horizon band failed its coverage gate or no interval artifact exists.
    temperature_p10: Optional[float] = None
    temperature_p90: Optional[float] = None
    humidity_p10: Optional[float] = None
    humidity_p90: Optional[float] = None
    wind_speed_p10: Optional[float] = None
    wind_speed_p90: Optional[float] = None
    cloud_cover_p10: Optional[float] = None
    cloud_cover_p90: Optional[float] = None
    precipitation_p90: Optional[float] = None  # one-sided upper bound (mm/h)
    interval_level: Optional[float] = None


class DailySummary(BaseModel):
    """Daily weather summary."""
    date: str
    temperature_min: Optional[float] = None
    temperature_max: Optional[float] = None
    temperature_avg: Optional[float] = None
    humidity_avg: Optional[float] = None
    precipitation_total: Optional[float] = None
    weather_code: Optional[int] = None
    wind_speed_max: Optional[float] = None
    cloud_cover_avg: Optional[float] = None
    rain_day_probability: Optional[float] = None
    precipitation_median: Optional[float] = None
    wind_gusts_max: Optional[float] = None
    # "ai" can include already-known analysis hours today.
    source: Optional[str] = None
    uv_index_max: Optional[float] = None
    us_aqi_max: Optional[float] = None
    # "high" | "medium" | "low" (see routers.weather._day_confidence) and a short Vietnamese note.
    confidence: Optional[str] = None
    skill_note: Optional[str] = None


class LocationInfo(BaseModel):
    """Location information."""
    latitude: float = 10.7909
    longitude: float = 106.6313
    name: str = "Ho Chi Minh City"
    timezone: str = "Asia/Ho_Chi_Minh"


class StaleCell(BaseModel):
    """A grid cell whose series has no data in the last CELL_FRESH_HOURS hours."""
    cell_id: str
    series_id: str
    latest_timestamp: Optional[datetime] = None
    status: Optional[str] = None     # series_status of the last ingest run ('ok' / 'failed'), if known
    error: Optional[str] = None


class CellsHealth(BaseModel):
    """Freshness of the per-cell weather series."""
    total: int
    fresh: int                       # cells with an hour in the last CELL_FRESH_HOURS hours
    fresh_hours: int
    stale: List[StaleCell] = []


class HealthCheck(BaseModel):
    """API health check response."""
    status: str
    database: str
    timestamp: datetime
    latest_timestamp: Optional[datetime] = None
    data_age_hours: Optional[float] = None
