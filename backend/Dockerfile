# HCMC Weather API (FastAPI + in-process hourly ingest scheduler).
# Build from the repo root:  docker compose build   (or: docker build -t sky-weather-api backend)

# --- build stage: resolve wheels into an isolated venv ----------------------------------------------
# Same Python minor and pinned requirements as the tested setup (backend suite: Python 3.14).
FROM python:3.14-slim AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install -r /tmp/requirements.txt

# --- runtime stage ----------------------------------------------------------------------------------
FROM python:3.14-slim
# libgomp1: OpenMP runtime needed by lightgbm wheels.
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

ARG APP_UID=10001
RUN useradd --uid ${APP_UID} --create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOST=0.0.0.0 \
    PORT=8000 \
    ENABLE_DOCS=0 \
    LOG_LEVEL=INFO

WORKDIR /app
COPY --chown=app:app . /app
# data/ (SQLite) and models/ are normally volumes; keep the mount points owned by the app user.
RUN mkdir -p /app/data /app/models && chown app:app /app/data /app/models

USER app
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/live' % os.environ.get('PORT','8000'), timeout=4)" || exit 1

# One process on purpose: the ingest scheduler runs inside the API process and must not run twice.
# python main.py = uvicorn with a single worker (HOST/PORT from env). To scale out, run extra
# replicas with INGEST_ENABLED=0 and keep exactly one replica with ingest on.
CMD ["python", "main.py"]
