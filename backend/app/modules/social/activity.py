"""The friends' activity feed: achievements, podiums, level-ups, streaks, new friendships, and
the battle results and progress players share (``shares.py``).

Features record events with ``record_activity`` in their own transaction; each player sees
their friends' events, and their own shares, from the last 7 days (``GET /v1/me/activity``).
Events are kept 30 days.
"""

import uuid
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import and_, delete, or_, select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import new_id
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.social.cards import cards
from app.modules.social.models import SHARE_KINDS, ActivityEvent, ActivityKind
from app.modules.social.privacy import is_minor_user
from app.modules.social.relations import blocked_ids, friend_ids
from app.modules.social.schemas import ActivityFeedOut, ActivityOut
from app.modules.users.models import HIDDEN_STATUSES, User

FEED_WINDOW = timedelta(days=7)
RETENTION = timedelta(days=30)

# Where an event names another player: ``friend`` items name the new friend, shared results
# the opponent. The feed shows that player's card only if the viewer may see them.
_OTHER_FIELD = {ActivityKind.FRIEND: "friend_id", ActivityKind.SHARED_RESULT: "opponent_id"}
# How a shared result names an opponent the viewer may not see (or who left).
HIDDEN_OPPONENT = "Another player"


async def record_activity(
    db: AsyncSession,
    user_id: uuid.UUID,
    kind: ActivityKind | str,
    payload: dict[str, Any],
    *,
    key: str,
    now: datetime | None = None,
) -> bool:
    """Add an event to the player's friends' feeds; ``False`` if ``key`` was already used.

    ``payload`` is what the app shows: e.g. ``{"level": 12}`` for ``level_up``,
    ``{"tournament_id", "name", "rank"}`` for ``podium``, ``{"days": 30}`` for ``streak``,
    ``{"achievement": "sharpshooter", "title": ...}`` for ``achievement``. For ``friend`` it is
    ``{"friend_id"}``; the feed adds the friend's card when the viewer may see it (a shared
    result's ``opponent_id`` works the same way). ``now`` sets ``created_at`` (by default the
    database's clock).
    """
    values: dict[str, Any] = {
        "id": new_id(),
        "user_id": user_id,
        "kind": ActivityKind(kind).value,
        "payload": payload,
        "key": key,
    }
    if now is not None:
        values["created_at"] = now
    inserted = await db.scalar(
        insert(ActivityEvent)
        .values(**values)
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
    """Friends' events and the viewer's own shares from the last 7 days, newest first."""
    friends = await friend_ids(db, viewer_id)
    statement = (
        select(ActivityEvent)
        .where(
            or_(
                ActivityEvent.user_id.in_(list(friends)),
                and_(ActivityEvent.user_id == viewer_id, ActivityEvent.kind.in_(SHARE_KINDS)),
            ),
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
    items = await render_activity(db, viewer_id, page, friends=friends, now=now)
    next_cursor = None
    if len(rows) > limit:
        last = page[-1]
        next_cursor = encode_cursor(ActivityCursor(at=last.created_at, id=last.id))
    return ActivityFeedOut(items=items, next_cursor=next_cursor)


async def render_activity(
    db: AsyncSession,
    viewer_id: uuid.UUID,
    events: list[ActivityEvent],
    *,
    friends: set[uuid.UUID],
    now: datetime,
) -> list[ActivityOut]:
    """Feed items for ``events`` as ``viewer_id`` sees them.

    A ``friend`` item whose new friend the viewer may not see is left out. A shared result's
    ``opponent_id`` becomes ``opponent`` (their card, or null for a bot or a player the viewer
    may not see) and ``opponent_name`` (the card's name, a bot's stored name, or
    ``HIDDEN_OPPONENT``).
    """
    others = {
        uuid.UUID(str(event.payload[field]))
        for event in events
        if (field := _OTHER_FIELD.get(ActivityKind(event.kind))) is not None
        and _is_uuid(event.payload.get(field))
    }
    visible_others = await _visible_to(db, viewer_id, others, friends=friends, now=now)
    card_of = await cards(db, {event.user_id for event in events} | visible_others)
    items = []
    for event in events:
        if event.user_id not in card_of:
            continue
        payload = dict(event.payload)
        if event.kind == ActivityKind.FRIEND:
            friend_id = payload.pop("friend_id", None)
            other = uuid.UUID(str(friend_id)) if _is_uuid(friend_id) else None
            if other is None or other not in visible_others:
                continue
            payload["friend"] = card_of[other].model_dump(mode="json")
        elif event.kind == ActivityKind.SHARED_RESULT:
            opponent_id = payload.pop("opponent_id", None)
            other = uuid.UUID(str(opponent_id)) if _is_uuid(opponent_id) else None
            card = card_of.get(other) if other is not None and other in visible_others else None
            payload["opponent"] = card.model_dump(mode="json") if card is not None else None
            if card is not None:
                payload["opponent_name"] = card.display_name
            elif other is not None or not payload.get("opponent_name"):
                payload["opponent_name"] = HIDDEN_OPPONENT
        items.append(
            ActivityOut(
                id=event.id,
                user=card_of[event.user_id],
                kind=event.kind,
                payload=payload,
                created_at=event.created_at,
            )
        )
    return items


async def _visible_to(
    db: AsyncSession,
    viewer_id: uuid.UUID,
    user_ids: set[uuid.UUID],
    *,
    friends: set[uuid.UUID],
    now: datetime,
) -> set[uuid.UUID]:
    """Of ``user_ids``, those the viewer may see named in an item: visible, not blocked, and
    not a minor unless the viewer is their friend (or the viewer themself)."""
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
