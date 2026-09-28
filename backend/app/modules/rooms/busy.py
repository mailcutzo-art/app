"""One busy slot per user, and the checks other features plug in.

``busy:{uid}`` says whether the player is queued, playing, in a room or in a tournament
(``docs/realtime-engine.md``). Creating or joining a room, accepting an invite and starting a
game also ask every registered **busy check**: a tournament the player registered for whose
start (minus 2 minutes) falls before ``until``, the longest the room's game could last, answers
with that tournament as ``details.active`` of a ``BUSY`` error. Tournaments register theirs with
``register_busy_check``; until then there are none.
"""

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.matches.schemas import ActiveOut
from app.modules.realtime import keys, rstr

# (db, redis, user, until) -> where the player is needed before ``until``, or None.
BusyCheck = Callable[[AsyncSession, Redis, uuid.UUID, datetime], Awaitable[ActiveOut | None]]

_CHECKS: list[BusyCheck] = []

MATCH_TITLES = {
    "quick_rated": "Quick Battle",
    "quick_casual": "Quick Battle",
    "bot": "Practice Bot",
    "friend": "Play with Friend",
    "group": "Group Battle",
    "tournament": "Tournament game",
}
ROOM_TITLES = {"friend": "Play with Friend", "group": "Group Battle"}


def register_busy_check(check: BusyCheck) -> None:
    """Add a check run before a room is created, joined or started (idempotent)."""
    if check not in _CHECKS:
        _CHECKS.append(check)


def unregister_busy_check(check: BusyCheck) -> None:
    if check in _CHECKS:
        _CHECKS.remove(check)


async def active_of(redis: Redis, busy: str) -> ActiveOut:
    """What a busy slot value points at, as ``details.active`` and Home's ``live`` show it."""
    kind, _, ident = busy.partition(":")
    if kind == "m":
        match_kind = await rstr.hget(redis, keys.match(ident), "kind")
        return ActiveOut(
            kind="match",
            id=ident,
            title=MATCH_TITLES.get(match_kind or "", "Quick Battle"),
            action={"route": f"/battle/match/{ident}"},
        )
    if kind == "q":
        return ActiveOut(
            kind="queue", id=ident, title="Quick Battle", action={"route": "/battle/search"}
        )
    if kind == "r":
        room_kind = await rstr.hget(redis, keys.room(ident), "kind")
        return ActiveOut(
            kind="room",
            id=ident,
            title=ROOM_TITLES.get(room_kind or "", "Room"),
            action={"route": f"/rooms/{ident}"},
        )
    return ActiveOut(
        kind="tournament", id=ident, title="Tournament", action={"route": f"/arena/{ident}"}
    )


async def busy_elsewhere(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    *,
    until: datetime,
    allow: str | None = None,
) -> ActiveOut | None:
    """Where the player is busy (their slot, unless it is ``allow``, then every registered
    check up to ``until``), or None if they are free."""
    busy = await rstr.get(redis, keys.busy(str(user_id)))
    if busy is not None and busy != allow:
        return await active_of(redis, busy)
    for check in _CHECKS:
        found = await check(db, redis, user_id, until)
        if found is not None:
            return found
    return None
