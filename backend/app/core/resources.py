"""Process-wide infrastructure clients, opened once per process and closed on shutdown."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.core.config import Settings
from app.core.db import create_engine, create_sessionmaker
from app.core.redis import create_redis


@dataclass(frozen=True, slots=True)
class Resources:
    engine: AsyncEngine
    sessionmaker: async_sessionmaker[AsyncSession]
    redis: Redis


@asynccontextmanager
async def open_resources(settings: Settings, *, component: str) -> AsyncIterator[Resources]:
    """Create the DB engine and Redis client. Connections are made lazily, on first use."""
    engine = create_engine(settings, application_name=f"quiz-{component}")
    redis = create_redis(settings)
    try:
        yield Resources(engine=engine, sessionmaker=create_sessionmaker(engine), redis=redis)
    finally:
        await redis.aclose()
        await engine.dispose()
