"""Time sources.

Match timing must come from Redis ``TIME`` so every realtime node agrees on one clock. Request
handling takes wall-clock time from the ``ClockDep`` dependency, which tests override to move
time forward.
"""

from collections.abc import Callable
from datetime import UTC, datetime, timedelta, timezone
from typing import Annotated

from fastapi import Depends
from redis.asyncio import Redis

# India has no daylight saving time, so a fixed offset is exact.
IST = timezone(timedelta(hours=5, minutes=30), "IST")

Clock = Callable[[], datetime]


async def redis_now_ms(redis: Redis) -> int:
    """Current Redis server time in milliseconds since the Unix epoch."""
    seconds, microseconds = await redis.time()
    return seconds * 1000 + microseconds // 1000


def utc_now() -> datetime:
    """Timezone-aware current UTC time."""
    return datetime.now(UTC)


def iso_utc(moment: datetime | None) -> str | None:
    """``2026-09-27T16:00:00Z``: ISO 8601 in UTC, as API responses write times."""
    if moment is None:
        return None
    return moment.astimezone(UTC).isoformat().replace("+00:00", "Z")


async def get_clock() -> Clock:
    """FastAPI dependency: the wall clock."""
    return utc_now


ClockDep = Annotated[Clock, Depends(get_clock)]
