"""Live tournament events, delivered through the outbox so they go out exactly when the step
that caused them commits (docs/protocol.md §9).

- ``tournaments.user``: one player's event on ``u`` (``t.check_in``, ``t.at_risk``,
  ``t.checked_in``, ``t.pairing``, ``t.bye``, ``t.finished``, ``t.cancelled``).
- ``tournaments.channel``: an event on ``t:<id>`` for every subscriber (``t.round``).
- ``tournaments.standings``: ``t.standings`` on ``t:<id>``, read from the database when it is
  delivered. Settlements schedule it into 2-second buckets (one message per bucket and
  tournament), so it goes out at most every 2 s and always shows the latest standings.
"""

import uuid
from datetime import UTC, datetime
from typing import Any

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import redis_now_ms
from app.modules.outbox.service import OutboxContext, enqueue, register
from app.modules.realtime import keys, protocol

TOPIC_USER = "tournaments.user"
TOPIC_CHANNEL = "tournaments.channel"
TOPIC_STANDINGS = "tournaments.standings"


def channel(tournament_id: uuid.UUID | str) -> str:
    return f"t:{tournament_id}"


async def user_event(
    db: AsyncSession, user_id: uuid.UUID, event_type: str, data: dict[str, Any], *, key: str
) -> None:
    await enqueue(
        db,
        TOPIC_USER,
        {"user_id": str(user_id), "type": event_type, "data": data},
        key=f"{TOPIC_USER}:{key}",
    )


async def channel_event(
    db: AsyncSession, tournament_id: uuid.UUID, event_type: str, data: dict[str, Any], *, key: str
) -> None:
    await enqueue(
        db,
        TOPIC_CHANNEL,
        {"tournament_id": str(tournament_id), "type": event_type, "data": data},
        key=f"{TOPIC_CHANNEL}:{key}",
    )


async def schedule_standings(
    db: AsyncSession, tournament_id: uuid.UUID, *, now: datetime, interval_ms: int
) -> None:
    """Publish ``t.standings`` at the start of the next ``interval_ms`` bucket (once per
    bucket, however many settlements land in it)."""
    now_ms = int(now.timestamp() * 1000)
    bucket = now_ms // interval_ms + 1
    await enqueue(
        db,
        TOPIC_STANDINGS,
        {"tournament_id": str(tournament_id)},
        key=f"{TOPIC_STANDINGS}:{tournament_id}:{bucket}",
        available_at=datetime.fromtimestamp(bucket * interval_ms / 1000, UTC),
    )


async def publish_channel(
    redis: Redis, tournament_id: str, event_type: str, data: dict[str, Any]
) -> None:
    now = await redis_now_ms(redis)
    frame = protocol.frame(event_type, data, ch=channel(tournament_id), ts=now)
    await redis.publish(keys.tournament_events(tournament_id), protocol.encode(frame))


async def _user(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    await protocol.publish_to_user(
        ctx.redis,
        payload["user_id"],
        payload["type"],
        payload["data"],
        ts=await redis_now_ms(ctx.redis),
    )


async def _channel(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    await publish_channel(ctx.redis, payload["tournament_id"], payload["type"], payload["data"])


async def _standings(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    # Imported here: standings imports this module.
    from app.modules.tournaments.standings_view import standings_snapshot

    tournament_id = payload["tournament_id"]
    snapshot = await standings_snapshot(ctx.db, uuid.UUID(tournament_id))
    if snapshot is not None:
        await publish_channel(ctx.redis, tournament_id, "t.standings", snapshot)


register(TOPIC_USER, _user)
register(TOPIC_CHANNEL, _channel)
register(TOPIC_STANDINGS, _standings)
