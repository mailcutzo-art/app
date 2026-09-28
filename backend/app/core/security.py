"""Caller identity: client IP resolution, bearer authentication and role checks."""

import uuid
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from ipaddress import IPv4Network, IPv6Network, ip_address
from typing import Annotated

import structlog
from fastapi import Depends
from starlette.requests import HTTPConnection

from app.core.clock import ClockDep
from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.errors import Forbidden, Unauthorized
from app.core.redis import RedisDep
from app.core.tokens import decode_access_token
from app.modules.auth.access import (
    ACTIVITY_INTERVAL_S,
    activity_gate_key,
    record_activity,
    revoke_reason,
    revoked_session_key,
)
from app.modules.users.authz import account_banned, authz_key, load_authz, parse_authz
from app.modules.users.models import Role, UserStatus

# Higher roles include the lower ones.
_ROLE_RANKS: dict[str, int] = {Role.USER: 0, Role.MODERATOR: 1, Role.ADMIN: 2}


def client_ip(conn: HTTPConnection, trusted_proxies: Sequence[IPv4Network | IPv6Network]) -> str:
    """The client's IP address.

    ``X-Forwarded-For`` is used only when the direct peer is a trusted proxy. The chain is then
    read right to left and the first hop that is not itself a trusted proxy is the client; hops
    further left are client-supplied and can be forged.
    """
    peer = conn.client.host if conn.client else ""
    if not _is_trusted(peer, trusted_proxies):
        return peer or "unknown"
    forwarded = ",".join(conn.headers.getlist("x-forwarded-for"))
    for hop in reversed([part.strip() for part in forwarded.split(",") if part.strip()]):
        try:
            address = ip_address(hop)
        except ValueError:
            break
        if not any(address in network for network in trusted_proxies):
            return str(address)
    return peer


def _is_trusted(host: str, trusted_proxies: Sequence[IPv4Network | IPv6Network]) -> bool:
    if not trusted_proxies:
        return False
    try:
        address = ip_address(host)
    except ValueError:
        return False
    return any(address in network for network in trusted_proxies)


@dataclass(frozen=True, slots=True)
class AuthContext:
    user_id: uuid.UUID
    session_id: uuid.UUID
    roles: frozenset[str]
    # A session of an account deleted less than 7 days ago; only ``CurrentAuthClosing``
    # endpoints (``GET /v1/me``, restore, logout) accept it.
    pending_deletion: bool = False

    def has_role(self, role: Role) -> bool:
        rank = max((_ROLE_RANKS.get(held, -1) for held in self.roles), default=-1)
        return rank >= _ROLE_RANKS[role]


async def _authenticate(
    conn: HTTPConnection,
    settings: SettingsDep,
    redis: RedisDep,
    db: SessionDep,
    clock: ClockDep,
    *,
    allow_pending_deletion: bool,
) -> AuthContext:
    scheme, _, token = conn.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise Unauthorized()
    now = clock()
    claims = decode_access_token(settings.jwt_keys, token.strip(), now=now)

    async with redis.pipeline(transaction=False) as pipe:
        pipe.get(revoked_session_key(claims.session_id))
        pipe.get(authz_key(claims.user_id))
        pipe.set(activity_gate_key(claims.session_id), "1", nx=True, ex=ACTIVITY_INTERVAL_S)
        revoked, cached_authz, first_in_interval = await pipe.execute()
    if revoked is not None:
        raise Unauthorized(
            "You have been signed out.",
            code="SESSION_REVOKED",
            details={"reason": revoke_reason(revoked)},
        )

    authz = parse_authz(cached_authz) or await load_authz(db, redis, claims.user_id)
    if authz is None:
        raise Unauthorized("Your session is not valid.", code="INVALID_ACCESS_TOKEN")
    if authz.banned(now):
        raise account_banned(authz.ban_reason, authz.banned_until, appeal=settings.appeal_contact)
    pending_deletion = authz.restorable(now)
    if authz.status in {UserStatus.PENDING_DELETION, UserStatus.DELETED} and not (
        pending_deletion and allow_pending_deletion
    ):
        raise Unauthorized("This account has been closed.", code="ACCOUNT_CLOSED")
    if authz.token_version != claims.token_version:
        raise Unauthorized("Your session is not valid.", code="INVALID_ACCESS_TOKEN")

    if first_in_interval:
        await record_activity(db, user_id=claims.user_id, session_id=claims.session_id, now=now)
    structlog.contextvars.bind_contextvars(user_id=str(claims.user_id))
    return AuthContext(
        user_id=claims.user_id,
        session_id=claims.session_id,
        roles=authz.roles,
        pending_deletion=pending_deletion,
    )


async def get_auth_context(
    conn: HTTPConnection,
    settings: SettingsDep,
    redis: RedisDep,
    db: SessionDep,
    clock: ClockDep,
) -> AuthContext:
    """FastAPI dependency: authenticate the ``Authorization: Bearer`` access token.

    Besides the signature and expiry it checks, in one Redis round trip, that the session was
    not revoked (logout, ban, reuse detection) and that the user's status and token version
    still allow the token. Activity is recorded at most every ``ACTIVITY_INTERVAL_S`` seconds.
    A deleted account's restricted session gets 401 ``ACCOUNT_CLOSED`` here.
    """
    return await _authenticate(conn, settings, redis, db, clock, allow_pending_deletion=False)


async def get_closing_auth_context(
    conn: HTTPConnection,
    settings: SettingsDep,
    redis: RedisDep,
    db: SessionDep,
    clock: ClockDep,
) -> AuthContext:
    """Like ``get_auth_context``, but also accepts the restricted session of an account deleted
    less than 7 days ago (``auth.pending_deletion``). Only ``GET /v1/me``, ``POST
    /v1/me/restore`` and logout use it (docs/api-play.md, "Deletion in detail")."""
    return await _authenticate(conn, settings, redis, db, clock, allow_pending_deletion=True)


CurrentAuth = Annotated[AuthContext, Depends(get_auth_context)]
CurrentAuthClosing = Annotated[AuthContext, Depends(get_closing_auth_context)]


async def get_current_user_id(auth: CurrentAuth) -> uuid.UUID:
    """FastAPI dependency: the authenticated user's id."""
    return auth.user_id


CurrentUserId = Annotated[uuid.UUID, Depends(get_current_user_id)]


def require_role(role: Role) -> Callable[..., Awaitable[AuthContext]]:
    """Dependency factory: 403 ``ROLE_REQUIRED`` unless the caller has ``role`` (or higher)."""

    async def ensure_role(auth: CurrentAuth) -> AuthContext:
        if not auth.has_role(role):
            raise Forbidden("You don't have access to this.", code="ROLE_REQUIRED")
        return auth

    return ensure_role
