"""Sign-in, token refresh and device sessions.

These functions commit themselves: what they revoke must stay revoked even when the request then
fails, and Redis markers are written only after the database agrees.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime

import structlog
from redis.asyncio import Redis
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Forbidden, Unauthorized
from app.core.ids import new_id
from app.core.tokens import issue_access_token
from app.modules.auth.access import mark_sessions_revoked
from app.modules.auth.models import (
    AuthIdentity,
    DeviceSession,
    Provider,
    RefreshToken,
    RevokeReason,
)
from app.modules.auth.refresh import (
    REFRESH_FAMILY_TTL,
    REFRESH_TOKEN_TTL,
    REUSE_GRACE,
    GraceCache,
    IssuedTokens,
    hash_refresh_token,
    new_refresh_token,
)
from app.modules.auth.schemas import DeviceIn
from app.modules.notifications.service import forget_push_tokens
from app.modules.users.authz import account_banned
from app.modules.users.models import User, UserStatus
from app.modules.users.validation import (
    DEFAULT_AVATAR_SYMBOL,
    DEFAULT_AVATAR_TONE,
    suggest_display_name,
)

MAX_ACTIVE_SESSIONS = 5
CLOSED_STATUSES = frozenset({UserStatus.PENDING_DELETION, UserStatus.DELETED})

log = structlog.stdlib.get_logger(__name__)


@dataclass(frozen=True, slots=True)
class ExternalAccount:
    provider: Provider
    subject: str
    email: str | None
    name: str | None


@dataclass(frozen=True, slots=True)
class SignInResult:
    user: User
    tokens: IssuedTokens
    is_new_user: bool


async def sign_in(
    db: AsyncSession,
    redis: Redis,
    settings: Settings,
    *,
    account: ExternalAccount,
    device: DeviceIn,
    now: datetime,
) -> SignInResult:
    """Find or create the user for ``account`` and start a session on ``device``.

    Users are matched by (provider, subject) only, never by email. The installation's previous
    session ends, and beyond ``MAX_ACTIVE_SESSIONS`` the least recently used ones end too.
    """
    user, is_new_user = await _find_or_create_user(db, account)
    if user.ban_in_force(now):
        raise account_banned(user.ban_reason, user.banned_until, appeal=settings.appeal_contact)
    if user.status in CLOSED_STATUSES:
        raise Forbidden("This account has been closed.", code="ACCOUNT_CLOSED")

    replaced = await _end_active_sessions(
        db, user.id, now, RevokeReason.REPLACED, install_id=device.install_id
    )
    session = DeviceSession(
        id=new_id(),
        user_id=user.id,
        install_id=device.install_id,
        platform=device.platform,
        app_version=device.app_version,
        build=device.build,
        created_at=now,
        last_seen_at=now,
    )
    db.add(session)
    await db.flush()
    over_limit = await _enforce_session_limit(db, user.id, now)
    user.last_seen_at = now
    tokens, _ = await _issue_tokens(db, settings, user, session, now)
    await db.commit()
    await mark_sessions_revoked(redis, replaced, RevokeReason.REPLACED)
    await mark_sessions_revoked(redis, over_limit, RevokeReason.SESSION_LIMIT)
    log.info("auth.signed_in", user_id=str(user.id), provider=account.provider, new=is_new_user)
    return SignInResult(user=user, tokens=tokens, is_new_user=is_new_user)


async def rotate_refresh_token(
    db: AsyncSession, redis: Redis, settings: Settings, *, token: str, now: datetime
) -> IssuedTokens:
    """Exchange a refresh token for a new pair; the old token becomes used.

    A used token presented again within ``REUSE_GRACE`` gets the same pair back (the client may
    have crashed before saving it); later, it is treated as stolen and the whole session ends.
    """
    grace = GraceCache(redis, settings.refresh_grace_key_bytes)
    token_hash = hash_refresh_token(token)
    # The row lock serializes concurrent refreshes with the same token.
    current = await db.scalar(
        select(RefreshToken).where(RefreshToken.token_hash == token_hash).with_for_update()
    )
    if current is None:
        raise _invalid_refresh_token()
    session = await db.get(DeviceSession, current.session_id, with_for_update=True)
    if session is None or session.revoked_at is not None:
        raise _invalid_refresh_token()

    if current.used_at is not None:
        if now - current.used_at <= REUSE_GRACE:
            replay = await grace.get(token_hash)
            if replay is None:
                log.warning("auth.refresh_grace_missing", session_id=str(session.id))
                raise _invalid_refresh_token()
            return replay
        await _end_session_for_reuse(db, redis, session, now)
        raise Unauthorized(
            "Your session has ended. Please sign in again.", code="REFRESH_TOKEN_REUSED"
        )
    if now >= current.expires_at:
        raise _invalid_refresh_token()

    user = await db.get_one(User, session.user_id)
    if user.ban_in_force(now):
        raise account_banned(user.ban_reason, user.banned_until, appeal=settings.appeal_contact)
    if user.status in CLOSED_STATUSES:
        raise Unauthorized("This account has been closed.", code="ACCOUNT_CLOSED")

    tokens, successor = await _issue_tokens(
        db,
        settings,
        user,
        session,
        now,
        family_id=current.family_id,
        family_expires_at=current.family_expires_at,
    )
    current.used_at = now
    current.successor_id = successor.id
    session.last_seen_at = now
    await db.flush()
    # Stored before committing: a concurrent retry waiting on the row lock reads it next.
    await grace.put(token_hash, tokens)
    await db.commit()
    return tokens


async def end_session(
    db: AsyncSession,
    redis: Redis,
    *,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    now: datetime,
    reason: RevokeReason,
) -> bool:
    """End one of the user's active sessions; ``False`` if there is no such session."""
    ended = await db.scalar(
        update(DeviceSession)
        .where(
            DeviceSession.id == session_id,
            DeviceSession.user_id == user_id,
            DeviceSession.revoked_at.is_(None),
        )
        .values(revoked_at=now, revoke_reason=reason)
        .returning(DeviceSession.id)
    )
    if ended is None:
        return False
    await forget_push_tokens(db, [ended])
    await db.commit()
    await mark_sessions_revoked(redis, [session_id], reason)
    return True


async def end_other_sessions(
    db: AsyncSession, redis: Redis, *, user_id: uuid.UUID, keep: uuid.UUID, now: datetime
) -> None:
    ended = await _end_active_sessions(db, user_id, now, RevokeReason.SIGNED_OUT, keep=keep)
    await db.commit()
    await mark_sessions_revoked(redis, ended, RevokeReason.SIGNED_OUT)


async def active_sessions(db: AsyncSession, user_id: uuid.UUID) -> list[DeviceSession]:
    result = await db.scalars(
        select(DeviceSession)
        .where(DeviceSession.user_id == user_id, DeviceSession.revoked_at.is_(None))
        .order_by(DeviceSession.last_seen_at.desc(), DeviceSession.id.desc())
    )
    return list(result)


async def _find_or_create_user(db: AsyncSession, account: ExternalAccount) -> tuple[User, bool]:
    identity = await _find_identity(db, account)
    if identity is None:
        try:
            async with db.begin_nested():
                user = User(
                    display_name=suggest_display_name(account.name, account.email),
                    email=account.email,
                    avatar_tone=DEFAULT_AVATAR_TONE,
                    avatar_symbol=DEFAULT_AVATAR_SYMBOL,
                )
                db.add(user)
                await db.flush()
                db.add(
                    AuthIdentity(
                        user_id=user.id,
                        provider=account.provider,
                        subject=account.subject,
                        email=account.email,
                    )
                )
            return user, True
        except IntegrityError:
            # The same account signed in concurrently elsewhere and created the user first.
            identity = await _find_identity(db, account)
            if identity is None:
                raise
    # Locking the user serializes their sign-ins (session replacement and the session limit).
    user = await db.get_one(User, identity.user_id, with_for_update=True)
    if account.email is not None:
        identity.email = account.email
        user.email = account.email
    return user, False


async def _find_identity(db: AsyncSession, account: ExternalAccount) -> AuthIdentity | None:
    return await db.scalar(
        select(AuthIdentity).where(
            AuthIdentity.provider == account.provider, AuthIdentity.subject == account.subject
        )
    )


async def _end_active_sessions(
    db: AsyncSession,
    user_id: uuid.UUID,
    now: datetime,
    reason: RevokeReason,
    *,
    install_id: str | None = None,
    keep: uuid.UUID | None = None,
) -> list[uuid.UUID]:
    statement = update(DeviceSession).where(
        DeviceSession.user_id == user_id, DeviceSession.revoked_at.is_(None)
    )
    if install_id is not None:
        statement = statement.where(DeviceSession.install_id == install_id)
    if keep is not None:
        statement = statement.where(DeviceSession.id != keep)
    result = await db.scalars(
        statement.values(revoked_at=now, revoke_reason=reason).returning(DeviceSession.id)
    )
    ended = list(result)
    await forget_push_tokens(db, ended)
    return ended


async def _enforce_session_limit(
    db: AsyncSession, user_id: uuid.UUID, now: datetime
) -> list[uuid.UUID]:
    excess = (
        select(DeviceSession.id)
        .where(DeviceSession.user_id == user_id, DeviceSession.revoked_at.is_(None))
        .order_by(
            DeviceSession.last_seen_at.desc(),
            DeviceSession.created_at.desc(),
            DeviceSession.id.desc(),
        )
        .offset(MAX_ACTIVE_SESSIONS)
    )
    result = await db.scalars(
        update(DeviceSession)
        .where(DeviceSession.id.in_(excess))
        .values(revoked_at=now, revoke_reason=RevokeReason.SESSION_LIMIT)
        .returning(DeviceSession.id)
    )
    ended = list(result)
    await forget_push_tokens(db, ended)
    return ended


async def _issue_tokens(
    db: AsyncSession,
    settings: Settings,
    user: User,
    session: DeviceSession,
    now: datetime,
    *,
    family_id: uuid.UUID | None = None,
    family_expires_at: datetime | None = None,
) -> tuple[IssuedTokens, RefreshToken]:
    """A new access token and refresh token; a new family unless ``family_id`` is given."""
    family_expires_at = family_expires_at or now + REFRESH_FAMILY_TTL
    refresh_token = new_refresh_token()
    row = RefreshToken(
        id=new_id(),
        session_id=session.id,
        family_id=family_id or new_id(),
        token_hash=hash_refresh_token(refresh_token),
        created_at=now,
        expires_at=min(now + REFRESH_TOKEN_TTL, family_expires_at),
        family_expires_at=family_expires_at,
    )
    db.add(row)
    # Inserted now, so an older token's successor_id can reference it in the next flush.
    await db.flush()
    access_token, access_expires_at = issue_access_token(
        settings.jwt_keys,
        user_id=user.id,
        session_id=session.id,
        roles=user.roles,
        token_version=user.token_version,
        now=now,
    )
    return IssuedTokens(access_token, access_expires_at, refresh_token), row


async def _end_session_for_reuse(
    db: AsyncSession, redis: Redis, session: DeviceSession, now: datetime
) -> None:
    session.revoked_at = now
    session.revoke_reason = RevokeReason.REFRESH_REUSE
    await forget_push_tokens(db, [session.id])
    await db.commit()
    await mark_sessions_revoked(redis, [session.id], RevokeReason.REFRESH_REUSE)
    log.warning(
        "auth.refresh_reuse_detected", user_id=str(session.user_id), session_id=str(session.id)
    )


def _invalid_refresh_token() -> Unauthorized:
    return Unauthorized(
        "Your session has ended. Please sign in again.", code="INVALID_REFRESH_TOKEN"
    )
