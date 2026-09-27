"""Sign-in, token refresh, logout and device sessions.

``dev_router`` (password-less dev login) is mounted only when ``APP_DEV_LOGIN_ENABLED`` is set,
which settings validation forbids in prod; otherwise the path is a plain 404.
"""

import math
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends

from app.core.clock import ClockDep
from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.errors import NotFound
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.auth import service
from app.modules.auth.google import GoogleVerifierDep, claim_single_use
from app.modules.auth.models import Provider
from app.modules.auth.refresh import IssuedTokens
from app.modules.auth.schemas import (
    DevLoginIn,
    GoogleSignInIn,
    RefreshIn,
    SessionOut,
    SignInOut,
    TokensOut,
)
from app.modules.auth.service import ExternalAccount, RevokeReason, SignInResult
from app.modules.users.schemas import MeOut

router = APIRouter(prefix="/auth", tags=["auth"])
dev_router = APIRouter(prefix="/auth", tags=["auth"])
sessions_router = APIRouter(prefix="/me/sessions", tags=["auth"])

# Per client IP. Generous because Indian mobile carriers put many users behind one address.
_sign_in_limit = rate_limit("auth.sign_in", capacity=20, refill_per_sec=20 / 60)
_refresh_limit = rate_limit("auth.refresh", capacity=120, refill_per_sec=2)


@router.post("/google", dependencies=[Depends(_sign_in_limit)])
async def sign_in_with_google(
    body: GoogleSignInIn,
    verifier: GoogleVerifierDep,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
    clock: ClockDep,
) -> SignInOut:
    """Exchange a Google ID token (fresh, single use) for a session on this device."""
    now = clock()
    identity = await verifier.verify(body.id_token, now=now)
    await claim_single_use(redis, body.id_token, expires_at=identity.expires_at, now=now)
    account = ExternalAccount(Provider.GOOGLE, identity.subject, identity.email, identity.name)
    result = await service.sign_in(
        db, redis, settings, account=account, device=body.device, now=now
    )
    return _sign_in_response(result, now)


@dev_router.post("/dev-login", dependencies=[Depends(_sign_in_limit)])
async def dev_login(
    body: DevLoginIn, db: SessionDep, redis: RedisDep, settings: SettingsDep, clock: ClockDep
) -> SignInOut:
    """Development only: sign in as the account for ``email``, creating it if needed."""
    now = clock()
    account = ExternalAccount(Provider.DEV, body.email, body.email, body.display_name)
    result = await service.sign_in(
        db, redis, settings, account=account, device=body.device, now=now
    )
    return _sign_in_response(result, now)


@router.post("/refresh", dependencies=[Depends(_refresh_limit)])
async def refresh(
    body: RefreshIn, db: SessionDep, redis: RedisDep, settings: SettingsDep, clock: ClockDep
) -> TokensOut:
    """Rotate the refresh token. 401 ``INVALID_REFRESH_TOKEN`` or ``REFRESH_TOKEN_REUSED``
    (the session is then over), 403 ``ACCOUNT_BANNED``."""
    now = clock()
    tokens = await service.rotate_refresh_token(
        db, redis, settings, token=body.refresh_token, now=now
    )
    return _tokens_response(tokens, now)


@router.post("/logout", status_code=204)
async def logout(auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep) -> None:
    """End this device's session; its tokens stop working immediately."""
    await service.end_session(
        db,
        redis,
        user_id=auth.user_id,
        session_id=auth.session_id,
        now=clock(),
        reason=RevokeReason.LOGOUT,
    )


@sessions_router.get("")
async def list_sessions(auth: CurrentAuth, db: SessionDep) -> list[SessionOut]:
    """Signed-in devices, most recently active first."""
    return [
        SessionOut(
            id=session.id,
            platform=session.platform,
            app_version=session.app_version,
            created_at=session.created_at,
            last_seen_at=session.last_seen_at,
            current=session.id == auth.session_id,
        )
        for session in await service.active_sessions(db, auth.user_id)
    ]


@sessions_router.delete("/{session_id}", status_code=204)
async def end_session(
    session_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep
) -> None:
    """Sign one device out (this one included)."""
    ended = await service.end_session(
        db,
        redis,
        user_id=auth.user_id,
        session_id=session_id,
        now=clock(),
        reason=RevokeReason.SIGNED_OUT,
    )
    if not ended:
        raise NotFound("That session was not found.", code="SESSION_NOT_FOUND")


@sessions_router.post("/revoke-others", status_code=204)
async def end_other_sessions(
    auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep
) -> None:
    """Sign out every device except this one."""
    await service.end_other_sessions(
        db, redis, user_id=auth.user_id, keep=auth.session_id, now=clock()
    )


def _tokens_response(tokens: IssuedTokens, now: datetime) -> TokensOut:
    return TokensOut(
        access_token=tokens.access_token,
        access_expires_in=_seconds_left(tokens, now),
        refresh_token=tokens.refresh_token,
    )


def _sign_in_response(result: SignInResult, now: datetime) -> SignInOut:
    return SignInOut(
        access_token=result.tokens.access_token,
        access_expires_in=_seconds_left(result.tokens, now),
        refresh_token=result.tokens.refresh_token,
        user=MeOut.from_user(result.user),
        is_new_user=result.is_new_user,
    )


def _seconds_left(tokens: IssuedTokens, now: datetime) -> int:
    """Whole seconds until the access token expires, rounded up (900 for a new token)."""
    return max(0, math.ceil((tokens.access_expires_at - now).total_seconds()))
