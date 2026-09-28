"""Creating inbox items and reading, marking and pruning them; push tokens.

``notify`` is how every feature tells a player something. It writes the inbox row and, in the
same transaction, outbox messages that deliver it: ``notify.live`` publishes a ``notify`` event
on the player's ``u`` channel (docs/protocol.md §9a) and ``notify.push`` sends a push when the
player's settings allow one (see ``delivery``).
"""

import uuid
from collections.abc import Sequence
from datetime import datetime, time, timedelta
from typing import Any

from sqlalchemy import delete, func, select, tuple_, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.ids import new_id
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.notifications.kinds import NotificationKind, pushes_by_default
from app.modules.notifications.models import Notification, PushToken
from app.modules.notifications.schemas import NotificationOut, NotificationsOut
from app.modules.outbox.service import enqueue

RETENTION = timedelta(days=90)
TOPIC_LIVE = "notify.live"
TOPIC_PUSH = "notify.push"


async def notify(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    kind: NotificationKind | str,
    title: str,
    body: str,
    icon: str | None = None,
    action: dict[str, Any] | None = None,
    key: str | None = None,
    push: bool | None = None,
    time_critical: bool = False,
) -> uuid.UUID | None:
    """Put a notice in the player's inbox and deliver it live and (maybe) by push.

    ``key`` de-duplicates per player: the same key again creates nothing and returns ``None``.
    ``push=None`` pushes unless the kind is inbox-only; the player's category settings and
    quiet hours still apply, except that ``time_critical`` pushes (their own match or round
    starting) ignore quiet hours. ``action`` is ``{"route": ..., "params": {...}}``.
    """
    kind = NotificationKind(kind)
    notification_id = new_id()
    inserted = await db.scalar(
        insert(Notification)
        .values(
            id=notification_id,
            user_id=user_id,
            kind=kind.value,
            title=title,
            body=body,
            icon=icon,
            action=action,
            key=key or str(notification_id),
        )
        .on_conflict_do_nothing(index_elements=[Notification.user_id, Notification.key])
        .returning(Notification.id)
    )
    if inserted is None:
        return None
    reference = {"notification_id": str(notification_id), "user_id": str(user_id)}
    await enqueue(db, TOPIC_LIVE, reference, key=f"{TOPIC_LIVE}:{notification_id}")
    if pushes_by_default(kind) if push is None else push:
        await enqueue(
            db,
            TOPIC_PUSH,
            {**reference, "time_critical": time_critical},
            key=f"{TOPIC_PUSH}:{notification_id}",
        )
    return notification_id


# --- Reading and marking -------------------------------------------------------------------


class NotificationCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


def notification_out(item: Notification) -> NotificationOut:
    return NotificationOut(
        id=item.id,
        kind=item.kind,
        title=item.title,
        body=item.body,
        icon=item.icon,
        action=item.action,
        created_at=item.created_at,
        read=item.read_at is not None,
    )


async def list_notifications(
    db: AsyncSession, user_id: uuid.UUID, *, cursor: str | None, limit: int, now: datetime
) -> NotificationsOut:
    """The inbox of the last 90 days, newest first."""
    statement = (
        select(Notification)
        .where(Notification.user_id == user_id, Notification.created_at > now - RETENTION)
        .order_by(Notification.created_at.desc(), Notification.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, NotificationCursor)
        statement = statement.where(
            tuple_(Notification.created_at, Notification.id) < tuple_(position.at, position.id)
        )
    rows = (await db.scalars(statement)).all()
    page = rows[:limit]
    next_cursor = None
    if len(rows) > limit:
        last = page[-1]
        next_cursor = encode_cursor(NotificationCursor(at=last.created_at, id=last.id))
    return NotificationsOut(
        items=[notification_out(item) for item in page], next_cursor=next_cursor
    )


async def unread_count(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> int:
    count = await db.scalar(
        select(func.count()).where(
            Notification.user_id == user_id,
            Notification.read_at.is_(None),
            Notification.created_at > now - RETENTION,
        )
    )
    return int(count or 0)


async def mark_read(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    ids: Sequence[uuid.UUID] | None,
    now: datetime,
) -> int:
    """Mark the given notices (or, with ``ids=None``, all of them) read. Other players' ids
    are ignored. Returns how many changed."""
    statement = (
        update(Notification)
        .where(Notification.user_id == user_id, Notification.read_at.is_(None))
        .values(read_at=now)
    )
    if ids is not None:
        statement = statement.where(Notification.id.in_(list(ids)))
    result = await db.execute(statement)
    return int(getattr(result, "rowcount", 0) or 0)


async def purge_notifications(db: AsyncSession, *, now: datetime, batch: int = 5000) -> int:
    """Delete notices older than 90 days, in batches."""
    total = 0
    while True:
        old = select(Notification.id).where(Notification.created_at < now - RETENTION).limit(batch)
        result = await db.execute(
            delete(Notification).where(Notification.id.in_(old.scalar_subquery()))
        )
        count = int(getattr(result, "rowcount", 0) or 0)
        await db.commit()
        total += count
        if count < batch:
            return total


# --- Quiet hours ---------------------------------------------------------------------------


def in_quiet_hours(moment: datetime, start: time | None, end: time | None) -> bool:
    """Whether ``moment`` falls in the quiet window (IST wall clock), which may span midnight.
    No window (``None``) or an empty one (start == end) is never quiet."""
    if start is None or end is None or start == end:
        return False
    local = moment.astimezone(IST).time().replace(tzinfo=None)
    if start < end:
        return start <= local < end
    return local >= start or local < end


# --- Push tokens ---------------------------------------------------------------------------


async def save_push_token(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    token: str,
    platform: str,
) -> None:
    """Register this installation's token. A session has at most one token, and a token one
    owner: registering it here takes it from any other session (a shared phone)."""
    await db.execute(
        delete(PushToken).where(PushToken.token == token, PushToken.session_id != session_id)
    )
    await db.execute(
        insert(PushToken)
        .values(id=new_id(), user_id=user_id, session_id=session_id, token=token, platform=platform)
        .on_conflict_do_update(
            index_elements=[PushToken.session_id],
            set_={"token": token, "platform": platform, "updated_at": func.now()},
        )
    )


async def forget_push_tokens(db: AsyncSession, session_ids: Sequence[uuid.UUID]) -> None:
    """Drop the tokens of sessions that ended (sign-out, replaced, revoked)."""
    if session_ids:
        await db.execute(delete(PushToken).where(PushToken.session_id.in_(list(session_ids))))
