"""Queue tickets in Redis: queueing, cancelling, requeueing and the abort cooldown.

A ticket is a hash ``mm:t:{ticket}`` plus an entry in its queue ``mm:q:{mode}:{subject}``
(scored by rating), and the player's busy slot points at it (``q:<ticket>``). The scripts in
``engine/lua/mm_*.lua`` change all three at once.
"""

import math
import secrets
from collections.abc import Mapping
from typing import Any

import structlog
from redis.asyncio import Redis

from app.core.clock import redis_now_ms
from app.core.config import Settings
from app.modules.realtime import keys, protocol, rstr
from app.modules.realtime.engine import scripts

log = structlog.stdlib.get_logger(__name__)

ALL_CHAPTERS = "*"  # a ticket's chapter when the player picked "All chapters"
# Minimum search time left after a requeue, so a player bounced near the end still gets a try.
REQUEUE_MIN_MS = 30_000
TIMEOUT_OPTIONS = ["keep", "bot", "invite", "cancel"]


def new_ticket_id() -> str:
    return secrets.token_urlsafe(12)


def busy_ttl_s(settings: Settings) -> int:
    """Safety TTL of a queue busy slot: longer than any search can last."""
    return math.ceil(settings.mm_max_wait_s + settings.mm_keep_s) + 600


async def queue_ticket(
    redis: Redis,
    settings: Settings,
    ticket_id: str,
    fields: Mapping[str, Any],
    *,
    replaces: str = "",
) -> tuple[bool, str]:
    """(True, joined_ms) or (False, the busy value in the way)."""
    return await scripts.mm_join(
        redis,
        ticket_id,
        fields,
        busy_ttl_s=busy_ttl_s(settings),
        max_wait_ms=round(settings.mm_max_wait_s * 1000),
        requeue_min_ms=REQUEUE_MIN_MS,
        replaces=replaces,
    )


async def requeue(
    redis: Redis, settings: Settings, fields: Mapping[str, str], *, reason: str
) -> bool:
    """Put a player whose match fell through back at the head of the queue (their original
    ``joined_ms``) and tell them with ``mm.requeued``. False if they are busy elsewhere now."""
    uid = fields["uid"]
    ok, _ = await queue_ticket(
        redis,
        settings,
        new_ticket_id(),
        {key: fields[key] for key in _REQUEUED_FIELDS if key in fields},
    )
    if not ok:
        return False
    now = await redis_now_ms(redis)
    waited_s = max(0, (now - int(fields["joined_ms"])) // 1000)
    await protocol.publish_to_user(
        redis, uid, "mm.requeued", {"reason": reason, "waited_s": waited_s}, ts=now
    )
    log.info("mm.requeued", user_id=uid, reason=reason)
    return True


_REQUEUED_FIELDS = (
    "uid",
    "mode",
    "subject",
    "chapter",
    "rating",
    "rd",
    "device",
    "hold_id",
    "first",
    "joined_ms",
    "deadline_ms",
)


async def record_abort(redis: Redis, settings: Settings, uid: str, match_id: str) -> int | None:
    """Count an abort against ``uid``; returns when their cooldown ends (ms) if this one
    started it (``mm_abort_limit`` aborts within an hour)."""
    now = await redis_now_ms(redis)
    key = keys.aborts(uid)
    async with redis.pipeline(transaction=True) as pipe:
        pipe.zadd(key, {match_id: now})
        pipe.zremrangebyscore(key, "-inf", now - 3_600_000)
        pipe.zcard(key)
        pipe.expire(key, 3600)
        _, _, count, _ = await pipe.execute()
    if int(count) < settings.mm_abort_limit:
        return None
    until = now + settings.mm_cooldown_s * 1000
    await redis.set(keys.cooldown(uid), until, px=settings.mm_cooldown_s * 1000)
    await redis.delete(key)
    log.info("mm.cooldown_started", user_id=uid, until=until)
    return until


async def cooldown_until(redis: Redis, uid: str) -> int | None:
    value = await rstr.get(redis, keys.cooldown(uid))
    return int(value) if value else None
