"""Keeping periodic jobs to one worker replica: Redis leases and once-a-day markers."""

import secrets
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from datetime import date

from redis.asyncio import Redis

from app.core.redis import LuaScript

DONE_MARKER_TTL_S = 3 * 24 * 60 * 60

# KEYS[1] lease; ARGV[1] owner token. Only the owner may release (it may have expired and been
# taken by another replica meanwhile).
_RELEASE = LuaScript(
    """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
"""
)


@asynccontextmanager
async def lease(redis: Redis, name: str, *, ttl_s: int) -> AsyncIterator[bool]:
    """Try to hold ``name`` for up to ``ttl_s`` seconds; yields whether this replica got it.

    ``ttl_s`` must exceed the job's longest run, or a second replica may start meanwhile.
    """
    key = f"lease:{name}"
    token = secrets.token_hex(16)
    acquired = bool(await redis.set(key, token, nx=True, ex=ttl_s))
    try:
        yield acquired
    finally:
        if acquired:
            await _RELEASE(redis, keys=[key], args=[token])


async def once_per_day(
    redis: Redis,
    name: str,
    day: date,
    run: Callable[[], Awaitable[None]],
    *,
    lease_ttl_s: int,
) -> bool:
    """Run ``run`` once for ``day`` across all replicas; True if this call ran it.

    The day is marked done only after a successful run, so a failed run is retried on a later
    tick.
    """
    done_key = f"job:{name}:done:{day.isoformat()}"
    if await redis.exists(done_key):
        return False
    async with lease(redis, name, ttl_s=lease_ttl_s) as acquired:
        if not acquired or await redis.exists(done_key):
            return False
        await run()
        await redis.set(done_key, "1", ex=DONE_MARKER_TTL_S)
    return True
