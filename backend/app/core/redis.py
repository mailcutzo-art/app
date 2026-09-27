"""Shared async Redis client and Lua script helper."""

import hashlib
from collections.abc import Sequence
from typing import Annotated, Any

from fastapi import Depends
from redis.asyncio import Redis
from redis.asyncio.retry import Retry
from redis.backoff import ExponentialWithJitterBackoff
from redis.exceptions import NoScriptError
from starlette.requests import HTTPConnection

from app.core.config import Settings


def create_redis(settings: Settings) -> Redis:
    """A pooled client that fails fast (bounded retries) when Redis is unreachable."""
    return Redis.from_url(
        settings.redis_url.get_secret_value(),
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=5,
        health_check_interval=30,
        retry=Retry(ExponentialWithJitterBackoff(), retries=2),
    )


async def get_redis(conn: HTTPConnection) -> Redis:
    """FastAPI dependency: the app's shared Redis client."""
    redis: Redis = conn.app.state.resources.redis
    return redis


RedisDep = Annotated[Redis, Depends(get_redis)]


class LuaScript:
    """A Lua script run with EVALSHA, falling back to EVAL (which caches it) after NOSCRIPT."""

    def __init__(self, source: str) -> None:
        self.source = source
        self.sha = hashlib.sha1(source.encode(), usedforsecurity=False).hexdigest()

    async def __call__(
        self, redis: Redis, keys: Sequence[str] = (), args: Sequence[str | bytes | int | float] = ()
    ) -> Any:
        try:
            return await redis.evalsha(self.sha, len(keys), *keys, *args)
        except NoScriptError:
            return await redis.eval(self.source, len(keys), *keys, *args)
