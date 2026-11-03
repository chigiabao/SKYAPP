# Current weather and reference metrics

Live current weather retains own-AI temperature, humidity, wind speed, clouds,
precipitation, rain probability and weather code. The model input cutoff,
issued_at and model_version are unchanged.

The current response may additionally contain apparent_temperature, uv_index,
visibility, surface_pressure and pressure_msl from hourly_weather, and us_aqi,
pm2_5 and pm10 from air_quality. These are Open-Meteo reference model outputs,
not predictions from the team's models and not station observations.

Only the same series and timestamps in [target hour - 1 hour, target hour] are
eligible. The latest row is used independently for weather and air quality.
Missing fields remain null. Each populated reference field has a field_sources
entry with source (open_meteo or open_meteo_cams) and its own timestamp.
The top-level source=ai describes the weather predictions; field_sources
overrides it for the listed supplemental fields.

Hourly/future forecasts remain own-AI only. Supplementation creates a copy and
never modifies cached predictions. If own AI is unavailable, current still
returns 503; supplemental references are not a weather fallback. Replay is
unchanged.

Updated Flutter clients display provider and reference date/time in the
conditions cards and desktop snapshot. Reference feels-like is omitted from
the AI headline to avoid an unlabeled mixed source. Legacy clients can read
the restored numeric fields, but need a new app build to display provenance.

No model retraining or improved forecast accuracy is implied by this change.
