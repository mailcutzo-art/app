"""Busy checks that live outside Redis's one busy slot (``busy:{uid}``).

A registered or checked-in tournament player isn't in any queue or match between rounds, yet
may not start something that would still run when their tournament needs them (docs/plan.md,
edge case #9). Features register a check here; ``mm.join`` (and rooms) ask ``check_busy``
with the longest time the new game could run until, and answer ``BUSY`` with the returned
``details.active`` when one says the player is taken.
"""

import uuid
from collections.abc import Awaitable, Callable

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.matches.schemas import ActiveOut

# (db, redis, user, until_ms) -> where the player is needed before ``until_ms``, or None.
BusyCheck = Callable[[AsyncSession, Redis, uuid.UUID, int], Awaitable[ActiveOut | None]]

_CHECKS: list[BusyCheck] = []


def register_busy_check(check: BusyCheck) -> None:
    if check not in _CHECKS:
        _CHECKS.append(check)


async def check_busy(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, until_ms: int
) -> ActiveOut | None:
    """The first registered check that finds the player busy before ``until_ms``."""
    for check in _CHECKS:
        found = await check(db, redis, user_id, until_ms)
        if found is not None:
            return found
    return None
