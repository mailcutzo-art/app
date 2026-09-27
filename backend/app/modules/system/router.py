"""Liveness and readiness probes, and the client bootstrap config."""

import asyncio
from collections.abc import Awaitable, Callable

import structlog
from fastapi import APIRouter
from sqlalchemy import text

from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.errors import ServiceUnavailable
from app.core.redis import RedisDep
from app.modules.system.schemas import ClientConfig, Health, Readiness

READINESS_TIMEOUT_S = 2.0

log = structlog.stdlib.get_logger(__name__)

# Probes are served at the root, outside the versioned API.
health_router = APIRouter(tags=["system"])
router = APIRouter(tags=["system"])


@health_router.get("/healthz")
async def healthz() -> Health:
    """Liveness: the process is serving requests. Checks no dependencies."""
    return Health(status="ok")


@health_router.get(
    "/readyz", responses={503: {"description": "A dependency (Postgres or Redis) is unavailable"}}
)
async def readyz(session: SessionDep, redis: RedisDep) -> Readiness:
    """Readiness: Postgres answers ``SELECT 1`` and Redis answers ``PING``."""
    database, redis_status = await asyncio.gather(
        _probe("database", lambda: session.execute(text("SELECT 1"))),
        _probe("redis", redis.ping),
    )
    checks = {"database": database, "redis": redis_status}
    if any(status != "ok" for status in checks.values()):
        raise ServiceUnavailable("Service is not ready.", details={"checks": checks})
    return Readiness(status="ok", checks=checks)


async def _probe(name: str, check: Callable[[], Awaitable[object]]) -> str:
    try:
        async with asyncio.timeout(READINESS_TIMEOUT_S):
            await check()
    except Exception as exc:  # noqa: BLE001 - any failure means "not ready"
        log.warning("readiness.check_failed", check=name, error_type=type(exc).__name__)
        return "unavailable"
    return "ok"


@router.get("/config")
async def client_config(settings: SettingsDep) -> ClientConfig:
    """Bootstrap config fetched at app start: force-update threshold, maintenance, flags."""
    return ClientConfig(
        min_build=settings.min_build,
        maintenance=settings.maintenance,
        features=settings.feature_flags,
    )
