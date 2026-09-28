"""Periodic background loops of an rt node that stop cleanly.

A loop is stopped by setting its event, never by cancelling it in the middle of a Redis command
(which can leave a connection half used), so shutdown waits at most one step.
"""

import asyncio
import contextlib
from collections.abc import Awaitable, Callable

import structlog
from redis.exceptions import RedisError

log = structlog.stdlib.get_logger(__name__)

STOP_WAIT_S = 5.0


async def every(
    interval_s: float, stop: asyncio.Event, step: Callable[[], Awaitable[None]], *, name: str
) -> None:
    """Run ``step`` every ``interval_s`` until ``stop`` is set. Failures are logged."""
    while not stop.is_set():
        with contextlib.suppress(TimeoutError):
            async with asyncio.timeout(interval_s):
                await stop.wait()
        if stop.is_set():
            return
        try:
            await step()
        except (RedisError, OSError):
            log.warning("rt.loop_failed", loop=name, exc_info=True)
        except Exception:
            log.exception("rt.loop_crashed", loop=name)


async def stop_all(stop: asyncio.Event, tasks: list[asyncio.Task[None]]) -> None:
    """Ask the loops to end, then wait for them (cancelling any that hang)."""
    stop.set()
    if not tasks:
        return
    _, pending = await asyncio.wait(tasks, timeout=STOP_WAIT_S)
    for task in pending:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
