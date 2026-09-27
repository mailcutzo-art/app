"""Process-wide infrastructure clients, opened once per process and closed on shutdown."""

import functools
import ssl
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

import httpx
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app import __version__
from app.core.config import Settings
from app.core.db import create_engine, create_sessionmaker
from app.core.redis import create_redis


@dataclass(frozen=True, slots=True)
class Resources:
    engine: AsyncEngine
    sessionmaker: async_sessionmaker[AsyncSession]
    redis: Redis
    http: httpx.AsyncClient  # outbound calls (Google keys, later push notifications)


@functools.cache
def _tls_context() -> ssl.SSLContext:
    """Built once per process: loading the CA bundle costs ~50 ms (honours SSL_CERT_FILE)."""
    return httpx.create_ssl_context()


@asynccontextmanager
async def open_resources(settings: Settings, *, component: str) -> AsyncIterator[Resources]:
    """Create the DB engine and the Redis and HTTP clients; they connect lazily, on first use."""
    engine = create_engine(settings, application_name=f"quiz-{component}")
    redis = create_redis(settings)
    http = httpx.AsyncClient(
        verify=_tls_context(),
        timeout=httpx.Timeout(10.0, connect=5.0),
        headers={"User-Agent": f"quiz-backend/{__version__}"},
    )
    try:
        yield Resources(
            engine=engine, sessionmaker=create_sessionmaker(engine), redis=redis, http=http
        )
    finally:
        await http.aclose()
        await redis.aclose()
        await engine.dispose()
