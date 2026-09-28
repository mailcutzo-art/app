"""The inbox, push tokens and notification settings (docs/api-play.md, "Inbox and push")."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.security import CurrentAuth
from app.modules.notifications import service
from app.modules.notifications.kinds import Category
from app.modules.notifications.schemas import (
    MarkReadIn,
    NotificationKinds,
    NotificationSettings,
    NotificationsOut,
    PushTokenIn,
    QuietHours,
    UnreadCountOut,
)
from app.modules.users.settings import (
    Preferences,
    locked_settings,
    preferences_of,
    read_settings,
)

router = APIRouter(tags=["notifications"])

CursorQuery = Annotated[str | None, Query(max_length=512)]
LimitQuery = Annotated[int, Query(ge=1, le=100)]

_settings_limit = rate_limit("settings.write", capacity=30, refill_per_sec=30 / 60, scope="user")


@router.get("/me/notifications")
async def list_notifications(
    auth: CurrentAuth,
    db: SessionDep,
    clock: ClockDep,
    cursor: CursorQuery = None,
    limit: LimitQuery = 30,
) -> NotificationsOut:
    """The inbox, newest first; notices are kept for 90 days."""
    return await service.list_notifications(
        db, auth.user_id, cursor=cursor, limit=limit, now=clock()
    )


@router.get("/me/notifications/unread-count")
async def unread_count(auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> UnreadCountOut:
    """The bell's badge. Live changes arrive as ``notify`` events on the ``u`` channel."""
    return UnreadCountOut(count=await service.unread_count(db, auth.user_id, now=clock()))


@router.post("/me/notifications/read", status_code=204)
async def mark_read(body: MarkReadIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> None:
    """``{"ids": [...]}`` marks those read (unknown ids are ignored), ``{"all": true}`` all."""
    await service.mark_read(db, auth.user_id, ids=None if body.all else body.ids, now=clock())


@router.put("/me/push-token", status_code=204, dependencies=[Depends(_settings_limit)])
async def save_push_token(body: PushTokenIn, auth: CurrentAuth, db: SessionDep) -> None:
    """Register this device's FCM token (replacing its previous one)."""
    await service.save_push_token(
        db,
        user_id=auth.user_id,
        session_id=auth.session_id,
        token=body.token,
        platform=body.platform.value,
    )


@router.delete("/me/push-token", status_code=204)
async def delete_push_token(auth: CurrentAuth, db: SessionDep) -> None:
    """Stop push to this device. Signing out does this too."""
    await service.forget_push_tokens(db, [auth.session_id])


@router.get("/me/settings/notifications")
async def read_notification_settings(auth: CurrentAuth, db: SessionDep) -> NotificationSettings:
    prefs = await read_settings(db, auth.user_id)
    return _settings_out(prefs)


@router.put("/me/settings/notifications", dependencies=[Depends(_settings_limit)])
async def update_notification_settings(
    body: NotificationSettings, auth: CurrentAuth, db: SessionDep
) -> NotificationSettings:
    """Push on or off per category, and the quiet hours (``null`` turns them off; leaving
    the field out keeps them). Returns the settings as stored."""
    row = await locked_settings(db, auth.user_id)
    row.notification_kinds = body.kinds.as_dict()
    if "quiet_hours" in body.model_fields_set:
        row.quiet_start, row.quiet_end = (
            body.quiet_hours.times() if body.quiet_hours else (None, None)
        )
    await db.flush()
    prefs = preferences_of(row)
    return _settings_out(prefs)


def _settings_out(prefs: Preferences) -> NotificationSettings:
    return NotificationSettings(
        kinds=NotificationKinds(**{c.value: prefs.category_enabled(c.value) for c in Category}),
        quiet_hours=QuietHours.of(prefs.quiet_start, prefs.quiet_end),
    )
