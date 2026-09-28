"""Outbox handlers that deliver inbox items: live on the user's channel, and by push.

Both are idempotent enough for at-least-once delivery: a repeated ``notify`` event just sets
the badge to the same count, and a repeated push replaces the earlier one on the phone (it
carries the notification id as its Android tag and iOS collapse id).
"""

import uuid
from datetime import timedelta
from typing import Any

import orjson
import structlog
from sqlalchemy import delete, select

from app.core.clock import redis_now_ms
from app.modules.auth.models import DeviceSession
from app.modules.notifications import fcm
from app.modules.notifications.kinds import NotificationKind, category_of, channel_of
from app.modules.notifications.models import Notification, PushToken
from app.modules.notifications.service import (
    TOPIC_LIVE,
    TOPIC_PUSH,
    in_quiet_hours,
    unread_count,
)
from app.modules.outbox.service import OutboxContext, register
from app.modules.users.settings import read_settings

log = structlog.stdlib.get_logger("app.notifications")

PROTOCOL_VERSION = 1
# A push this late (retries, an outage) is no longer news; the inbox still has it.
PUSH_STALE_AFTER = timedelta(hours=1)


def user_channel(user_id: uuid.UUID | str) -> str:
    """The Redis pub/sub channel of one user's ``u`` events (docs/realtime-engine.md)."""
    return f"ev:u:{user_id}"


def notify_event(item: Notification, *, unread: int, ts: int) -> dict[str, Any]:
    """The ``notify`` envelope of docs/protocol.md §9a, as the gateway forwards it."""
    return {
        "v": PROTOCOL_VERSION,
        "t": "notify",
        "ch": "u",
        "ts": ts,
        "d": {
            "id": str(item.id),
            "kind": item.kind,
            "title": item.title,
            "body": item.body,
            "action": item.action,
            "unread": unread,
        },
    }


async def publish_live(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    item = await ctx.db.get(Notification, uuid.UUID(payload["notification_id"]))
    if item is None:  # pruned meanwhile
        return
    unread = await unread_count(ctx.db, item.user_id, now=ctx.now)
    event = notify_event(item, unread=unread, ts=await redis_now_ms(ctx.redis))
    await ctx.redis.publish(user_channel(item.user_id), orjson.dumps(event))


async def send_push(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    account = fcm.service_account(ctx.settings)
    if account is None:
        log.debug("push.skipped", reason="disabled")
        return
    item = await ctx.db.get(Notification, uuid.UUID(payload["notification_id"]))
    if item is None or item.read_at is not None:
        return
    reason = await _hold_back(ctx, item, time_critical=bool(payload.get("time_critical")))
    if reason is not None:
        log.debug("push.skipped", reason=reason, kind=item.kind)
        return
    tokens = (
        await ctx.db.execute(
            select(PushToken.id, PushToken.token)
            .join(DeviceSession, DeviceSession.id == PushToken.session_id)
            .where(PushToken.user_id == item.user_id, DeviceSession.revoked_at.is_(None))
        )
    ).all()
    stale: list[uuid.UUID] = []
    for token_id, token in tokens:
        message = push_message(item, token=token, time_critical=bool(payload.get("time_critical")))
        # A transient failure raises, so the whole push is retried; phones that already got it
        # replace it (same tag) instead of showing it twice.
        if await fcm.send(ctx.http, account, message, now=ctx.now) is fcm.SendOutcome.INVALID_TOKEN:
            stale.append(token_id)
    if stale:
        await ctx.db.execute(delete(PushToken).where(PushToken.id.in_(stale)))
        log.info("push.tokens_dropped", count=len(stale))


async def _hold_back(ctx: OutboxContext, item: Notification, *, time_critical: bool) -> str | None:
    """Why this push shouldn't go out, or ``None`` to send it."""
    if ctx.now - item.created_at > PUSH_STALE_AFTER:
        return "stale"
    prefs = await read_settings(ctx.db, item.user_id)
    category = category_of(NotificationKind(item.kind))
    if category is not None and not prefs.category_enabled(category.value):
        return "category_off"
    if not time_critical and in_quiet_hours(ctx.now, prefs.quiet_start, prefs.quiet_end):
        return "quiet_hours"
    return None


def push_message(item: Notification, *, token: str, time_critical: bool) -> dict[str, Any]:
    """An FCM v1 message mirroring the inbox item; tapping it opens the same destination."""
    action = item.action or {}
    return {
        "token": token,
        "notification": {"title": item.title, "body": item.body},
        "data": {
            "notification_id": str(item.id),
            "kind": item.kind,
            "route": str(action.get("route") or "/inbox"),
            "params": orjson.dumps(action.get("params") or {}).decode(),
        },
        "android": {
            "priority": "HIGH" if time_critical else "NORMAL",
            "notification": {
                "tag": str(item.id),
                "channel_id": channel_of(NotificationKind(item.kind)),
            },
        },
        "apns": {"headers": {"apns-collapse-id": str(item.id)}},
    }


register(TOPIC_LIVE, publish_live)
register(TOPIC_PUSH, send_push)
