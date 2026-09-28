"""Presence: online, in a battle, in a tournament or offline (docs/plan.md, Phase 7).

The realtime gateway keeps ``presence:{uid}`` fresh while a socket is open (``set_presence``
with a TTL a little longer than its heartbeat), so a vanished socket turns into "offline" on
its own. Presence is shown only to friends, and only when the player's ``presence`` privacy
setting is ``friends``.
"""

import uuid
from collections.abc import Collection, Sequence
from datetime import datetime
from enum import StrEnum

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.modules.social.privacy import PresenceTo, privacy_many, users_by_id
from app.modules.social.relations import friend_ids

DEFAULT_TTL_S = 90


class Presence(StrEnum):
    ONLINE = "online"
    IN_BATTLE = "in_battle"
    IN_TOURNAMENT = "in_tournament"
    OFFLINE = "offline"


LIVE_STATES = frozenset({Presence.ONLINE, Presence.IN_BATTLE, Presence.IN_TOURNAMENT})


def presence_key(user_id: uuid.UUID) -> str:
    return f"presence:{user_id}"


async def set_presence(
    redis: Redis, user_id: uuid.UUID, state: Presence | str, ttl_s: int = DEFAULT_TTL_S
) -> None:
    """Record what the player is doing for ``ttl_s`` seconds; ``offline`` clears it."""
    state = Presence(state)
    if state == Presence.OFFLINE:
        await clear_presence(redis, user_id)
        return
    if ttl_s < 1:
        raise ValueError("ttl_s must be at least 1")
    await redis.set(presence_key(user_id), state.value, ex=ttl_s)


async def clear_presence(redis: Redis, user_id: uuid.UUID) -> None:
    await redis.delete(presence_key(user_id))


async def read_presence(redis: Redis, user_ids: Sequence[uuid.UUID]) -> dict[uuid.UUID, Presence]:
    """Raw presence, ignoring privacy: for server-side use only (never show it as is)."""
    if not user_ids:
        return {}
    values = await redis.mget([presence_key(user_id) for user_id in user_ids])
    return {
        user_id: Presence(value) if value in LIVE_STATES else Presence.OFFLINE
        for user_id, value in zip(user_ids, values, strict=True)
    }


async def get_presence_many(
    redis: Redis,
    user_ids: Collection[uuid.UUID],
    *,
    db: AsyncSession,
    viewer_id: uuid.UUID,
    now: datetime | None = None,
) -> dict[uuid.UUID, Presence]:
    """Presence as ``viewer_id`` may see it: the real state for friends whose setting allows
    it, ``offline`` for everyone else."""
    ids = list(dict.fromkeys(user_ids))
    result = dict.fromkeys(ids, Presence.OFFLINE)
    friends = await friend_ids(db, viewer_id)
    candidates = [user_id for user_id in ids if user_id in friends]
    if not candidates:
        return result
    users = list((await users_by_id(db, candidates)).values())
    privacy = await privacy_many(db, users, now=now or utc_now())
    visible = [user.id for user in users if privacy[user.id].presence == PresenceTo.FRIENDS]
    result.update(await read_presence(redis, visible))
    return result
