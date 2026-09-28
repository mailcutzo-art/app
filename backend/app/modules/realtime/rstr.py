"""Typed string reads from Redis.

The shared client decodes responses (``decode_responses=True``), but redis-py types its replies
as ``bytes | str``; these helpers give the realtime code plain ``str`` values.
"""

from collections.abc import Sequence
from typing import Any

from redis.asyncio import Redis


def as_str(value: Any) -> str:
    return value.decode() if isinstance(value, bytes) else str(value)


def opt_str(value: Any) -> str | None:
    return None if value is None else as_str(value)


async def get(redis: Redis, key: str) -> str | None:
    return opt_str(await redis.get(key))


async def hget(redis: Redis, key: str, field: str) -> str | None:
    return opt_str(await redis.hget(key, field))


async def hmget(redis: Redis, key: str, fields: Sequence[str]) -> list[str | None]:
    return [opt_str(value) for value in await redis.hmget(key, list(fields))]


async def hgetall(redis: Redis, key: str) -> dict[str, str]:
    return {as_str(k): as_str(v) for k, v in (await redis.hgetall(key)).items()}
