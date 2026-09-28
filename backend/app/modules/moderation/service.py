"""Player reports and the moderation ladder (docs/plan.md, "Security model").

``apply_moderation`` is how moderators (the admin panel, scripts) and automatic signals act on
an account: warn, reset name, restrict social, shadow pool, temporary ban, permanent ban.

* Warnings, name resets and social restrictions put an ``account`` notice in the inbox. The
  shadow pool is silent on purpose: matchmaking asks ``in_shadow_pool``.
* A restriction sets status ``restricted``: the player keeps playing but can't send friend
  requests or challenges. ``lift_expired`` (a worker job) ends restrictions and bans whose time
  is up.
* A ban bumps ``token_version`` (every access token stops working at once, answering
  ``ACCOUNT_BANNED``), ends every device session, tells the live socket to close
  (``ctl:u:{uid}``), and runs the ban hooks (boards, live games) that other features register.
"""

import secrets
import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta

import structlog
from redis.asyncio import Redis
from sqlalchemy import Exists, SQLColumnExpression, and_, exists, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound, ValidationFailed
from app.modules.auth.models import DeviceSession, RevokeReason
from app.modules.moderation.models import (
    ModerationAction,
    ModerationKind,
    ReportReason,
    UserReport,
)
from app.modules.notifications.service import forget_push_tokens, notify
from app.modules.system.models import AuditLog
from app.modules.users.authz import invalidate_authz
from app.modules.users.control import ControlType, publish_control
from app.modules.users.models import BanReason, User, UserStatus
from app.modules.users.validation import FALLBACK_DISPLAY_NAME

log = structlog.stdlib.get_logger(__name__)

REPORT_DEDUPE_WINDOW = timedelta(hours=24)
BANS = frozenset({ModerationKind.TEMP_BAN, ModerationKind.PERM_BAN})

_REASON_TEXT = {
    BanReason.CHEATING: "unfair play",
    BanReason.ABUSE: "abusive behaviour",
    BanReason.OFFENSIVE_NAME: "an offensive name",
    BanReason.OTHER: "breaking the community rules",
}

# (db, user_id, now): runs in the banning transaction (withdraw from boards, forfeit games).
BanHook = Callable[[AsyncSession, uuid.UUID, datetime], Awaitable[None]]
_BAN_HOOKS: list[BanHook] = []


def register_ban_hook(hook: BanHook) -> None:
    if hook not in _BAN_HOOKS:
        _BAN_HOOKS.append(hook)


# --- Reports --------------------------------------------------------------------------------


async def file_report(
    db: AsyncSession,
    reporter_id: uuid.UUID,
    *,
    reported_id: uuid.UUID,
    reason: ReportReason,
    match_id: uuid.UUID | None,
    note: str | None,
    now: datetime,
) -> None:
    """Queue a report for review. The same report again within a day is kept once."""
    if reporter_id == reported_id:
        raise ValidationFailed(
            "You can't report yourself.",
            details={"fields": {"user_id": "You can't report yourself."}},
        )
    if await db.get(User, reported_id) is None:
        raise NotFound("That player was not found.", code="USER_NOT_FOUND")
    duplicate = await db.scalar(
        select(
            exists().where(
                UserReport.reporter_id == reporter_id,
                UserReport.reported_id == reported_id,
                UserReport.reason == reason.value,
                UserReport.match_id.is_(None)
                if match_id is None
                else UserReport.match_id == match_id,
                UserReport.created_at > now - REPORT_DEDUPE_WINDOW,
            )
        )
    )
    if duplicate:
        return
    db.add(
        UserReport(
            reporter_id=reporter_id,
            reported_id=reported_id,
            match_id=match_id,
            reason=reason.value,
            note=note,
            created_at=now,
        )
    )
    await db.flush()


# --- The ladder -----------------------------------------------------------------------------


async def apply_moderation(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    action: ModerationKind | str,
    *,
    reason: BanReason | str,
    until: datetime | None = None,
    by: uuid.UUID | None = None,
    note: str | None = None,
    now: datetime,
) -> ModerationAction:
    """Record and carry out one moderation step, then commit (the socket is told to close
    only once the ban is stored)."""
    kind, reason = ModerationKind(action), BanReason(reason)
    _check_until(kind, until, now)
    user = await db.get(User, user_id, with_for_update=True)
    if user is None:
        raise NotFound("That player was not found.", code="USER_NOT_FOUND")
    before = _snapshot(user)
    record = ModerationAction(
        user_id=user_id,
        kind=kind.value,
        reason=reason.value,
        note=note,
        until=until,
        created_by=by,
        created_at=now,
    )
    db.add(record)
    await db.flush()

    if kind in BANS:
        await _ban(db, user, reason, until, now)
    elif kind == ModerationKind.RESET_NAME:
        await _reset_name(db, user)
    elif kind == ModerationKind.RESTRICT_SOCIAL and user.status == UserStatus.ACTIVE:
        user.status = UserStatus.RESTRICTED.value
    await db.flush()
    if kind not in BANS and kind != ModerationKind.SHADOW_POOL:
        await _tell(db, user_id, record, kind, reason, until)
    db.add(
        AuditLog(
            action=f"user.moderation.{kind.value}",
            entity_type="user",
            entity_id=str(user_id),
            before=before,
            after={**_snapshot(user), "action_id": str(record.id), "until": _iso(until)},
        )
    )
    await db.commit()
    await invalidate_authz(redis, user_id)
    if kind in BANS:
        await publish_control(redis, user_id, ControlType.BAN, reason=reason.value)
    log.info("moderation.applied", user_id=str(user_id), kind=kind.value, reason=reason.value)
    return record


def _check_until(kind: ModerationKind, until: datetime | None, now: datetime) -> None:
    if kind == ModerationKind.TEMP_BAN and (until is None or until <= now):
        raise ValueError("a temporary ban needs an end in the future")
    if kind == ModerationKind.PERM_BAN and until is not None:
        raise ValueError("a permanent ban has no end")
    if until is not None and until <= now:
        raise ValueError("until must be in the future")


async def _ban(
    db: AsyncSession, user: User, reason: BanReason, until: datetime | None, now: datetime
) -> None:
    user.status = UserStatus.BANNED.value
    user.ban_reason = reason.value
    user.banned_until = until
    user.token_version += 1
    ended = list(
        await db.scalars(
            update(DeviceSession)
            .where(DeviceSession.user_id == user.id, DeviceSession.revoked_at.is_(None))
            .values(revoked_at=now, revoke_reason=RevokeReason.BANNED.value)
            .returning(DeviceSession.id)
        )
    )
    await forget_push_tokens(db, ended)
    for hook in _BAN_HOOKS:
        await hook(db, user.id, now)


async def _reset_name(db: AsyncSession, user: User) -> None:
    """Back to "Player", and a neutral handle the player can change right away."""
    user.display_name = FALLBACK_DISPLAY_NAME
    if user.handle is not None:
        while True:
            handle = f"player_{secrets.token_hex(4)}"
            if await db.scalar(select(User.id).where(User.handle == handle)) is None:
                break
        user.handle = handle
        user.handle_changed_at = None


async def _tell(
    db: AsyncSession,
    user_id: uuid.UUID,
    record: ModerationAction,
    kind: ModerationKind,
    reason: BanReason,
    until: datetime | None,
) -> None:
    why = _REASON_TEXT[reason]
    if kind == ModerationKind.WARN:
        title, body = "A warning about your account", f"We've had reports of {why}."
    elif kind == ModerationKind.RESET_NAME:
        title = "Your name was reset"
        body = "Your name and username broke the rules, so we reset them. Choose new ones."
    else:
        ends = f" until {until:%d %b %Y}" if until is not None else ""
        title = "Friend features are paused"
        body = (
            f"Because of {why}, you can't send friend requests or challenges{ends}. "
            "You can still play."
        )
    await notify(
        db,
        user_id,
        kind="account",
        title=title,
        body=body,
        icon="shield",
        action={"route": "/settings/profile", "params": {}}
        if kind == ModerationKind.RESET_NAME
        else None,
        key=f"moderation:{record.id}",
    )


def _snapshot(user: User) -> dict[str, object]:
    return {
        "status": user.status,
        "display_name": user.display_name,
        "handle": user.handle,
        "ban_reason": user.ban_reason,
        "banned_until": _iso(user.banned_until),
        "token_version": user.token_version,
    }


def _iso(moment: datetime | None) -> str | None:
    return moment.isoformat() if moment is not None else None


def in_force(
    kind: ModerationKind, user_id: uuid.UUID | SQLColumnExpression[uuid.UUID], now: datetime
) -> Exists:
    """A condition: the player has an unrevoked action of ``kind`` that hasn't ended."""
    return exists().where(
        ModerationAction.user_id == user_id,
        ModerationAction.kind == kind.value,
        ModerationAction.revoked_at.is_(None),
        or_(ModerationAction.until.is_(None), ModerationAction.until > now),
    )


async def in_shadow_pool(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> bool:
    """Whether matchmaking should pair the player only with others in the shadow pool."""
    return bool(await db.scalar(select(in_force(ModerationKind.SHADOW_POOL, user_id, now))))


async def lift_expired(db: AsyncSession, redis: Redis, *, now: datetime) -> int:
    """End restrictions and bans whose time is up; returns how many accounts changed."""
    restricted = in_force(ModerationKind.RESTRICT_SOCIAL, User.id, now)
    lifted = list(
        await db.scalars(
            update(User)
            .where(
                or_(
                    and_(User.status == UserStatus.RESTRICTED.value, ~restricted),
                    and_(
                        User.status == UserStatus.BANNED.value,
                        User.banned_until.is_not(None),
                        User.banned_until <= now,
                    ),
                )
            )
            .values(
                status=UserStatus.ACTIVE.value,
                ban_reason=None,
                banned_until=None,
            )
            .returning(User.id)
        )
    )
    # A ban that ended while a restriction still runs leaves the account restricted.
    if lifted:
        await db.execute(
            update(User)
            .where(User.id.in_(lifted), restricted)
            .values(status=UserStatus.RESTRICTED.value)
        )
    await db.commit()
    for user_id in lifted:
        await invalidate_authz(redis, user_id)
    return len(lifted)
