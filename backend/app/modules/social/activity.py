"""The friends' activity feed: achievements, podiums, level-ups, streaks and new friendships.

Features record events with ``record_activity`` in their own transaction; each player sees
their friends' events from the last 7 days (``GET /v1/me/activity``). Events are kept 30 days.
"""

import uuid
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import delete, select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import new_id
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.social.cards import cards
from app.modules.social.models import ActivityEvent, ActivityKind
from app.modules.social.privacy import is_minor_user
from app.modules.social.relations import blocked_ids, friend_ids
from app.modules.social.schemas import ActivityFeedOut, ActivityOut
from app.modules.users.models import HIDDEN_STATUSES, User

FEED_WINDOW = timedelta(days=7)
RETENTION = timedelta(days=30)


async def record_activity(
    db: AsyncSession,
    user_id: uuid.UUID,
    kind: ActivityKind | str,
    payload: dict[str, Any],
    *,
    key: str,
) -> bool:
    """Add an event to the player's friends' feeds; ``False`` if ``key`` was already used.

    ``payload`` is what the app shows: e.g. ``{"level": 12}`` for ``level_up``,
    ``{"tournament_id", "name", "rank"}`` for ``podium``, ``{"days": 30}`` for ``streak``,
    ``{"achievement": "sharpshooter", "title": ...}`` for ``achievement``. For ``friend`` it is
    ``{"friend_id"}``; the feed adds the friend's card when the viewer may see it.
    """
    inserted = await db.scalar(
        insert(ActivityEvent)
        .values(
            id=new_id(), user_id=user_id, kind=ActivityKind(kind).value, payload=payload, key=key
        )
        .on_conflict_do_nothing(index_elements=[ActivityEvent.user_id, ActivityEvent.key])
        .returning(ActivityEvent.id)
    )
    return inserted is not None


class ActivityCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


async def friends_activity(
    db: AsyncSession, viewer_id: uuid.UUID, *, cursor: str | None, limit: int, now: datetime
) -> ActivityFeedOut:
    """Friends' events from the last 7 days, newest first."""
    friends = await friend_ids(db, viewer_id)
    if not friends:
        return ActivityFeedOut(items=[], next_cursor=None)
    statement = (
        select(ActivityEvent)
        .where(
            ActivityEvent.user_id.in_(list(friends)),
            ActivityEvent.created_at > now - FEED_WINDOW,
        )
        .order_by(ActivityEvent.created_at.desc(), ActivityEvent.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, ActivityCursor)
        statement = statement.where(
            tuple_(ActivityEvent.created_at, ActivityEvent.id) < tuple_(position.at, position.id)
        )
    rows = list(await db.scalars(statement))
    page = rows[:limit]
    others = {
        uuid.UUID(str(event.payload["friend_id"]))
        for event in page
        if event.kind == ActivityKind.FRIEND and _is_uuid(event.payload.get("friend_id"))
    }
    visible_others = await _visible_to(db, viewer_id, others, friends=friends, now=now)
    card_of = await cards(db, {event.user_id for event in page} | visible_others)
    items = []
    for event in page:
        payload = dict(event.payload)
        if event.kind == ActivityKind.FRIEND:
            friend_id = payload.pop("friend_id", None)
            other = uuid.UUID(str(friend_id)) if _is_uuid(friend_id) else None
            if other is None or other not in visible_others:
                continue
            payload["friend"] = card_of[other].model_dump(mode="json")
        items.append(
            ActivityOut(
                id=event.id,
                user=card_of[event.user_id],
                kind=event.kind,
                payload=payload,
                created_at=event.created_at,
            )
        )
    next_cursor = None
    if len(rows) > limit:
        last = page[-1]
        next_cursor = encode_cursor(ActivityCursor(at=last.created_at, id=last.id))
    return ActivityFeedOut(items=items, next_cursor=next_cursor)


async def _visible_to(
    db: AsyncSession,
    viewer_id: uuid.UUID,
    user_ids: set[uuid.UUID],
    *,
    friends: set[uuid.UUID],
    now: datetime,
) -> set[uuid.UUID]:
    """Of ``user_ids``, those the viewer may see in a "now friends with" item: visible, not
    blocked, and not a minor unless the viewer is their friend (or the viewer themself)."""
    if not user_ids:
        return set()
    users = await db.scalars(
        select(User).where(User.id.in_(list(user_ids)), User.status.not_in(HIDDEN_STATUSES))
    )
    blocked = await blocked_ids(db, viewer_id)
    return {
        user.id
        for user in users
        if user.id not in blocked
        and (user.id == viewer_id or user.id in friends or not is_minor_user(user, now))
    }


def _is_uuid(value: object) -> bool:
    try:
        uuid.UUID(str(value))
    except ValueError:
        return False
    return True


async def purge_activity(db: AsyncSession, *, now: datetime) -> int:
    result = await db.execute(
        delete(ActivityEvent).where(ActivityEvent.created_at < now - RETENTION)
    )
    return int(getattr(result, "rowcount", 0) or 0)
