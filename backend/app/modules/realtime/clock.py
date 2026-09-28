"""The rt node's view of the shared clock (Redis ``TIME``).

Scripts read Redis ``TIME`` themselves; Python only needs it to arm local timers for a due time
written by a script, and to stamp frames. The offset to the local clock is measured with a round
trip and refreshed periodically.
"""

import time

from redis.asyncio import Redis

from app.core.clock import redis_now_ms


class SharedClock:
    def __init__(self) -> None:
        self._offset_ms = 0.0

    def now_ms(self) -> int:
        """Server time in Unix ms (Redis clock, estimated locally)."""
        return int(time.time() * 1000 + self._offset_ms)

    def delay_s(self, due_ms: int) -> float:
        """Seconds from now until ``due_ms`` on the shared clock (0 if past)."""
        return max(0.0, (due_ms - self.now_ms()) / 1000)

    async def sync(self, redis: Redis) -> None:
        sent = time.time() * 1000
        server = await redis_now_ms(redis)
        received = time.time() * 1000
        self._offset_ms = server - (sent + received) / 2
