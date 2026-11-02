# Render Free: Backend Demo

This is a DEMO deployment, not production storage. No VPS is required, but the
backend still runs on Render infrastructure. SQLite accounts, sessions, feedback
and ingested weather can disappear after a restart/redeploy/spin-down. Do not use
real or irreplaceable account data here. Free instances sleep when idle; the first
request may wait for startup and current/past input ingestion. No 24/7 guarantee.

## Render Form

- Language: Docker. Branch: the branch containing these changes.
- Root Directory: backend.
- Dockerfile Path: ./Dockerfile.render (NOT the volume-based ./Dockerfile).
- Docker Build Context Directory, if shown: . (relative to Root Directory).
- Compute: Free ($0), one instance. Do not attach a paid disk or upgrade automatically.
- Health Check Path: /live. Leave Docker Command blank.
- Auto-Deploy: manual/off until the first deployment is verified.

Environment variables (Add from .env; these are not secrets):

```dotenv
INGEST_ENABLED=1
INGEST_BACKFILL_DAYS=3
EXTERNAL_FORECAST_ENABLED=0
MAINTENANCE_ENABLED=0
ENABLE_DOCS=0
OMP_NUM_THREADS=1
OPENBLAS_NUM_THREADS=1
MKL_NUM_THREADS=1
```

Add ADMIN_TOKEN separately using Render's Generate button. Keep the generated
value private; never send it in screenshots/chat, commit it, or embed it in the
mobile application. This operator token is NOT an admin-user login. Leave PORT
unset so Render can supply it. The container binds 0.0.0.0 and honors PORT.

## What Ships

Dockerfile.render has its own Dockerfile.render.dockerignore. It includes only
serving V3, long-range-v2, interval artifacts, legacy TSN fallback, Python runtime
code and location metadata. Private DBs/backups, training history, .env files,
experimental models and training outputs are not packaged. Exactly 56 reviewed
serving artifacts are allowlisted; no model wildcard is re-included. The original Dockerfile
and .dockerignore retain the existing volume-based deployment behavior.

Build-time check_serving_models.py fails if a required model/extension/interval
or configured cell is missing. This only loads existing trusted repo models;
it does not train, promote models, download artifacts or touch a database.

On a new empty database the normal scheduler seeds locations and downloads
3 days of current/past weather for every series (minimum 48 contiguous hours
required by the models). The normal default remains 90 days outside this profile.
Existing data uses the normal 48-hour revision overlap. No future external weather
or AQ is served as a substitute for the team's own predictions. Never weaken the
3-hour freshness/short-target validation if input is delayed.

No weather DB/history is uploaded. Live ingestion still depends on Open-Meteo
availability and quotas. Do not repeatedly redeploy to work around an upstream
outage. The scheduler performs bounded retries and preserves available inputs.

## Verify Before Building Phones

1. The build log must show successful validation with cells=67 and the expected
   V3/long-range model versions; deployment must not exit or run out of memory.
2. /live returns200 once HTTP is running. /ready returns503 until fresh input
   and models are usable; only200 means ready. Health checks must use /live so
   an upstream outage does not cause restart/ingest loops.
3. /weather/bundle returns200, current input within3hours, 48 hourly forecasts,
   7 daily forecasts, forecast_provider=sky_weather_ai and no forecast_error.
   ai_error can still be explicit if the shortest target already elapsed; do
   not claim all AI panels ready until ai_error=null.
4. Verify a second scheduled ingestion and inspect Render memory/restart logs.
   A Windows synthetic-data probe is NOT proof of a Linux512MB memory ceiling.
5. Use only the actual HTTPS service URL from the successful Render deployment:
   flutter build apk --dart-define=API_BASE_URL=https://<actual-service>.onrender.com
   Use the same define for an iOS build on a signed Apple environment. No
   localhost/LAN URLs in phone release builds. Do not publish an untested URL.

This image is API-only: it does not contain a Flutter web build. An API URL is
not a deployed Flutter website. A separate web build must point to this API, or
web/API must be packaged together in a later deployment. CORS_ORIGINS should be
restricted to the actual web origin if browser access is enabled.

## Remaining Limits

Durable accounts/admin/feedback require persistent external storage or a paid
persistent disk. Render Free does not solve this. SMTP password recovery also
needs a supported delivery provider; no delivery configuration is added here.
Do not treat this demo as a finished production backend.

Preparation does not commit/push code or create a Render service. Confirm the
branch contains the new Dockerfile, ignore file, model checker, ingest change
and serving models before pressing Deploy. Do not use git add . on this dirty
worktree; review/stage only intended changes and include their dependencies.
