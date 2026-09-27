"""Time sources.

Match timing must come from Redis ``TIME`` so every realtime node agrees on one clock; use
``utc_now`` only for wall-clock bookkeeping such as audit timestamps.
"""

from datetime import UTC, datetime

from redis.asyncio import Redis


async def redis_now_ms(redis: Redis) -> int:
    """Current Redis server time in milliseconds since the Unix epoch."""
    seconds, microseconds = await redis.time()
    return seconds * 1000 + microseconds // 1000


def utc_now() -> datetime:
    """Timezone-aware current UTC time."""
    return datetime.now(UTC)
