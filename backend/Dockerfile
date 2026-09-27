# syntax=docker/dockerfile:1
#
# One image for all three processes; choose one with the container command:
#   api (default)  uvicorn app.main_api:create_app --factory --host 0.0.0.0 --port 8000 ...
#   rt             uvicorn app.main_rt:create_app --factory --host 0.0.0.0 --port 8000 \
#                    --no-proxy-headers --no-server-header --ws-max-size 65536
#   worker         python -m app.main_worker    (no HTTP: disable the healthcheck for it)
#   migrations     alembic upgrade head
# Configuration comes from APP_* environment variables (see .env.example).

FROM ghcr.io/astral-sh/uv:0.8.17 AS uv

FROM python:3.11-slim AS builder
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv
WORKDIR /src
# Dependencies first: this layer is reused until uv.lock changes.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-dev --no-install-project
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-editable

FROM python:3.11-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    APP_ENV=prod
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY alembic.ini ./
COPY alembic ./alembic
USER app:app
EXPOSE 8000
# Liveness only: /healthz checks no dependencies (use /readyz for load-balancer readiness).
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]
# Client IPs come from APP_TRUSTED_PROXIES, so uvicorn must not rewrite them from headers.
CMD ["uvicorn", "app.main_api:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", \
     "--no-proxy-headers", "--no-server-header", "--no-access-log"]
