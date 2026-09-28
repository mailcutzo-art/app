"""Taking a banned or deleted player out of live play.

A ban or an account deletion runs its hooks inside the banning (deleting) transaction, which has
no Redis: ``withdraw_on_ban`` and ``withdraw_on_delete`` enqueue a ``matches.withdraw`` outbox
message there, so the withdrawal happens exactly when the change commits. The worker's handler
then cancels a queue ticket (refunding a casual entry) or forfeits a live match (settlement
pays the opponent the win); ``welcome``, ``mm.join`` and the socket gate keep the player out
from then on. Closing the sockets is the ban's (and deletion's) own control message.
"""

import uuid
from datetime import datetime
from typing import Any

import structlog
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.matches import ports
from app.modules.outbox.service import OutboxContext, enqueue, register
from app.modules.realtime import keys, rstr
from app.modules.realtime.engine import scripts
from app.modules.realtime.matchmaking import tickets

log = structlog.stdlib.get_logger(__name__)

TOPIC = "matches.withdraw"


async def withdraw_player(
    db: AsyncSession, redis: Redis, escrow: ports.EscrowPort, user_id: uuid.UUID
) -> str | None:
    """End what the player is in: "cancelled" (a search), "forfeited" (a match) or None."""
    uid = str(user_id)
    busy = await rstr.get(redis, keys.busy(uid))
    if busy is None:
        return None
    kind, _, ident = busy.partition(":")
    if kind == "q":
        status, value = await tickets.end_ticket(redis, uid, ident)
        if status == "cancelled":
            if value:
                await escrow.release(db, hold_id=value, key=f"mm:{ident}:refund")
            log.info("matches.withdrawn", user_id=uid, ticket_id=ident)
            return "cancelled"
        if status != "matched":
            return None
        kind, ident = "m", value
    if kind == "m":
        step = await scripts.forfeit(redis, ident, uid)
        if step.ended:
            log.info("matches.withdrawn", user_id=uid, match_id=ident)
            return "forfeited"
    return None


async def _enqueue(db: AsyncSession, user_id: uuid.UUID, now: datetime, reason: str) -> None:
    await enqueue(
        db,
        TOPIC,
        {"user_id": str(user_id), "reason": reason},
        key=f"{TOPIC}:{user_id}:{reason}:{now.isoformat()}",
    )


async def withdraw_on_ban(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> None:
    """``moderation.register_ban_hook``."""
    await _enqueue(db, user_id, now, "banned")


async def withdraw_on_delete(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> None:
    """``users.deletion.on_account_deleted``."""
    await _enqueue(db, user_id, now, "account_deleted")


async def _handle(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    await withdraw_player(
        ctx.db, ctx.redis, ports.integrations.escrow, uuid.UUID(payload["user_id"])
    )


register(TOPIC, _handle)
