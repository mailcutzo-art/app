"""Deleting an account: hidden for 7 days (restorable exactly), erased after 30.

``request_deletion`` (``POST /v1/me/delete``, after a fresh sign-in proof):
* status ``pending_deletion`` with ``restore_until`` 7 days away; every device session ends and
  the live socket is told to close;
* the player disappears for everyone else: search, profiles, friends lists, requests (pending
  ones are withdrawn) and the activity feed skip ``HIDDEN_STATUSES``; friendships, ranks and
  history stay, so a restore brings them back;
* ``on_account_deleted`` hooks run in the same transaction: tournaments withdraw and refund
  entries, live matches are forfeited, leaderboards drop the player.

Signing in during the 7 days gives a restricted session (``CurrentAuthClosing``) that can only
read ``/v1/me``, restore or sign out. ``restore`` undoes the hiding and runs
``on_account_restored`` hooks.

30 days after the request the worker's ``account_erasure_job`` erases the account for good:
the ``users`` row stays as an anonymous tombstone (so coin ledger, match and practice rows keep
a valid owner), the sign-in identities go (the same Google account can sign up again as a new
player), and so do sessions, settings, the inbox, social rows, feedback and the analytics link.
``on_account_erased`` hooks remove whatever else a feature keeps about the person.
"""

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta
from enum import StrEnum

import structlog
from redis.asyncio import Redis
from sqlalchemy import delete, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Conflict, Forbidden, Unauthorized
from app.modules.analytics.models import AnalyticsEvent
from app.modules.auth.access import mark_sessions_revoked
from app.modules.auth.google import GoogleIdTokenVerifier, claim_single_use
from app.modules.auth.models import AuthIdentity, DeviceSession, Provider, RevokeReason
from app.modules.feedback.models import Feedback
from app.modules.moderation.models import ModerationKind
from app.modules.moderation.service import in_force
from app.modules.notifications.models import Notification, PushToken
from app.modules.notifications.service import forget_push_tokens
from app.modules.social.friends import cancel_pending_between
from app.modules.social.models import ActivityEvent, Block, FriendRequest, Friendship
from app.modules.social.presence import clear_presence
from app.modules.users.authz import invalidate_authz
from app.modules.users.control import ControlType, publish_control
from app.modules.users.models import Role, User, UserSettings, UserStatus
from app.modules.users.validation import DEFAULT_AVATAR_SYMBOL, DEFAULT_AVATAR_TONE

log = structlog.stdlib.get_logger(__name__)

RESTORE_WINDOW = timedelta(days=7)
ERASE_AFTER = timedelta(days=30)
ERASED_NAME = "Deleted player"
ERASE_BATCH = 50

# (db, user_id, now), run inside the transaction that changes the account.
AccountHook = Callable[[AsyncSession, uuid.UUID, datetime], Awaitable[None]]

_DELETED_HOOKS: list[AccountHook] = []
_RESTORED_HOOKS: list[AccountHook] = []
_ERASED_HOOKS: list[AccountHook] = []


def on_account_deleted(hook: AccountHook) -> AccountHook:
    """Run ``hook`` when a player deletes their account (usable as a decorator)."""
    if hook not in _DELETED_HOOKS:
        _DELETED_HOOKS.append(hook)
    return hook


def on_account_restored(hook: AccountHook) -> AccountHook:
    """Run ``hook`` when a player restores their account within 7 days."""
    if hook not in _RESTORED_HOOKS:
        _RESTORED_HOOKS.append(hook)
    return hook


def on_account_erased(hook: AccountHook) -> AccountHook:
    """Run ``hook`` when an account is erased for good (before the tombstone is written)."""
    if hook not in _ERASED_HOOKS:
        _ERASED_HOOKS.append(hook)
    return hook


# --- Proof ----------------------------------------------------------------------------------


class ProofProvider(StrEnum):
    GOOGLE = "google"
    DEV = "dev"


async def check_proof(
    db: AsyncSession,
    redis: Redis,
    settings: Settings,
    verifier: GoogleIdTokenVerifier,
    user_id: uuid.UUID,
    *,
    provider: ProofProvider,
    id_token: str | None,
    now: datetime,
) -> None:
    """A fresh sign-in for this very account: a Google ID token (recent, single use) whose
    subject is linked to the user, or, where dev login is on, the dev proof.

    Any failure is 403 ``REAUTH_REQUIRED`` (never 401, which would make the app refresh its
    session), with ``details.reason``: the verifier's code (``ID_TOKEN_EXPIRED``,
    ``TOKEN_REPLAYED``...), ``WRONG_ACCOUNT`` or ``PROOF_NOT_ACCEPTED``.
    """
    if provider == ProofProvider.DEV:
        if not settings.dev_login_enabled:
            raise reauth_required("PROOF_NOT_ACCEPTED", "Sign in with Google to confirm.")
        return
    if id_token is None:
        raise reauth_required("PROOF_NOT_ACCEPTED", "Sign in with Google to confirm.")
    try:
        identity = await verifier.verify(id_token, now=now)
        await claim_single_use(redis, id_token, expires_at=identity.expires_at, now=now)
    except Unauthorized as exc:
        raise reauth_required(exc.code, "Please sign in again to confirm.") from exc
    linked = await db.scalar(
        select(AuthIdentity.id).where(
            AuthIdentity.user_id == user_id,
            AuthIdentity.provider == Provider.GOOGLE.value,
            AuthIdentity.subject == identity.subject,
        )
    )
    if linked is None:
        raise reauth_required(
            "WRONG_ACCOUNT",
            "That's a different Google account. Sign in with the one this profile uses.",
        )


def reauth_required(reason: str, message: str) -> Forbidden:
    return Forbidden(message, code="REAUTH_REQUIRED", details={"reason": reason})


# --- Delete and restore ---------------------------------------------------------------------


async def request_deletion(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, now: datetime
) -> User:
    """Hide the account and end every session (the proof was checked by the caller).
    Commits, then tells Redis: revoked sessions, the authz cache and the live socket."""
    user = await db.get_one(User, user_id, with_for_update=True)
    if user.status == UserStatus.PENDING_DELETION:
        return user
    user.status = UserStatus.PENDING_DELETION.value
    user.deletion_requested_at = now
    user.restore_until = now + RESTORE_WINDOW
    user.token_version += 1
    ended = list(
        await db.scalars(
            update(DeviceSession)
            .where(DeviceSession.user_id == user_id, DeviceSession.revoked_at.is_(None))
            .values(revoked_at=now, revoke_reason=RevokeReason.ACCOUNT_DELETED.value)
            .returning(DeviceSession.id)
        )
    )
    await forget_push_tokens(db, ended)
    await cancel_pending_between(db, user_id, None, now=now)
    for hook in _DELETED_HOOKS:
        await hook(db, user_id, now)
    await db.commit()
    await mark_sessions_revoked(redis, ended, RevokeReason.ACCOUNT_DELETED)
    await invalidate_authz(redis, user_id)
    await clear_presence(redis, user_id)
    await publish_control(redis, user_id, ControlType.REVOKE, reason="account_deleted")
    log.info("account.deletion_requested", user_id=str(user_id))
    return user


async def restore_account(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, now: datetime
) -> User:
    """Bring the account back exactly as it was (within the 7 days)."""
    user = await db.get_one(User, user_id, with_for_update=True)
    if user.status != UserStatus.PENDING_DELETION:
        return user
    if not user.restorable(now):
        raise Conflict("It's too late to restore this account.", code="RESTORE_EXPIRED")
    restricted = await db.scalar(select(in_force(ModerationKind.RESTRICT_SOCIAL, user_id, now)))
    user.status = (UserStatus.RESTRICTED if restricted else UserStatus.ACTIVE).value
    user.deletion_requested_at = None
    user.restore_until = None
    for hook in _RESTORED_HOOKS:
        await hook(db, user_id, now)
    await db.commit()
    await invalidate_authz(redis, user_id)
    log.info("account.restored", user_id=str(user_id))
    return user


# --- Erasure --------------------------------------------------------------------------------


async def erase_due(db: AsyncSession, *, now: datetime, batch: int = ERASE_BATCH) -> int:
    """Erase accounts whose deletion is 30 days old, each in its own transaction."""
    due = list(
        await db.scalars(
            select(User.id)
            .where(
                User.status == UserStatus.PENDING_DELETION.value,
                User.deletion_requested_at <= now - ERASE_AFTER,
            )
            .order_by(User.deletion_requested_at)
            .limit(batch)
        )
    )
    await db.commit()
    erased = 0
    for user_id in due:
        erased += await erase_account(db, user_id, now=now)
    return erased


async def erase_account(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> bool:
    """Erase one account if it is still due (a restore may have won the race)."""
    user = await db.get(User, user_id, with_for_update=True, populate_existing=True)
    if (
        user is None
        or user.status != UserStatus.PENDING_DELETION
        or user.deletion_requested_at is None
        or user.deletion_requested_at > now - ERASE_AFTER
    ):
        await db.commit()
        return False
    for hook in _ERASED_HOOKS:
        await hook(db, user_id, now)
    for statement in (
        delete(AuthIdentity).where(AuthIdentity.user_id == user_id),
        delete(PushToken).where(PushToken.user_id == user_id),
        delete(DeviceSession).where(DeviceSession.user_id == user_id),
        delete(UserSettings).where(UserSettings.user_id == user_id),
        delete(Notification).where(Notification.user_id == user_id),
        delete(Friendship).where(or_(Friendship.lo == user_id, Friendship.hi == user_id)),
        delete(FriendRequest).where(
            or_(FriendRequest.from_id == user_id, FriendRequest.to_id == user_id)
        ),
        delete(Block).where(or_(Block.blocker_id == user_id, Block.blocked_id == user_id)),
        delete(ActivityEvent).where(ActivityEvent.user_id == user_id),
        delete(Feedback).where(Feedback.user_id == user_id),
        update(AnalyticsEvent).where(AnalyticsEvent.user_id == user_id).values(user_id=None),
    ):
        await db.execute(statement)
    user.handle = None
    user.display_name = ERASED_NAME
    user.email = None
    user.avatar_tone = DEFAULT_AVATAR_TONE
    user.avatar_symbol = DEFAULT_AVATAR_SYMBOL
    user.goal = None
    user.birth_year = None
    user.is_minor = False
    user.roles = [Role.USER.value]
    user.last_seen_at = None
    user.ban_reason = None
    user.banned_until = None
    user.handle_changed_at = None
    user.restore_until = None
    user.status = UserStatus.DELETED.value
    user.token_version += 1
    await db.commit()
    log.info("account.erased", user_id=str(user_id))
    return True
