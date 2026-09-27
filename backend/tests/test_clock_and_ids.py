import time
from datetime import UTC

from redis.asyncio import Redis

from app.core.clock import redis_now_ms, utc_now
from app.core.ids import new_id


async def test_redis_now_ms_tracks_the_redis_clock(redis: Redis) -> None:
    first = await redis_now_ms(redis)
    second = await redis_now_ms(redis)

    # Local Redis: its clock is the host clock.
    assert abs(first - time.time() * 1000) < 1000
    assert first <= second


def test_utc_now_is_timezone_aware() -> None:
    assert utc_now().tzinfo is UTC


def test_new_id_is_a_time_ordered_uuid7() -> None:
    ids = [new_id() for _ in range(100)]

    assert all(value.version == 7 for value in ids)
    assert len(set(ids)) == len(ids)
    assert ids == sorted(ids)
