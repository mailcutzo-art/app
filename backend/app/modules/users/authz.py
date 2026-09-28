"""What every authenticated request must know about its user, cached briefly in Redis.

Status, token version and roles decide whether a valid access token is still honoured. They are
cached for ``AUTHZ_TTL_S`` and the cache is dropped whenever they change, so bans and role
changes apply within a minute even if an invalidation is missed.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime

import orjson
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import iso_utc
from app.core.errors import Forbidden
from app.modules.users.models import User, ban_in_force, restorable

AUTHZ_TTL_S = 60


@dataclass(frozen=True, slots=True)
class Authz:
    status: str
    token_version: int
    roles: frozenset[str]
    ban_reason: str | None = None
    banned_until: datetime | None = None
    restore_until: datetime | None = None

    def banned(self, now: datetime) -> bool:
        return ban_in_force(self.status, self.banned_until, now)

    def restorable(self, now: datetime) -> bool:
        return restorable(self.status, self.restore_until, now)


def authz_key(user_id: uuid.UUID) -> str:
    return f"authz:{user_id}"


def parse_authz(raw: str | None) -> Authz | None:
    """A cached snapshot, or ``None`` when missing or unreadable."""
    if raw is None:
        return None
    try:
        data = orjson.loads(raw)
        return Authz(
            data["status"],
            int(data["ver"]),
            frozenset(data["roles"]),
            data["ban_reason"],
            _moment(data["banned_until"]),
            _moment(data["restore_until"]),
        )
    except (orjson.JSONDecodeError, KeyError, TypeError, ValueError):
        return None


def _moment(raw: str | None) -> datetime | None:
    return datetime.fromisoformat(raw) if raw is not None else None


async def load_authz(db: AsyncSession, redis: Redis, user_id: uuid.UUID) -> Authz | None:
    """Read the snapshot from the database and cache it; ``None`` if the user doesn't exist."""
    row = (
        await db.execute(
            select(
                User.status,
                User.token_version,
                User.roles,
                User.ban_reason,
                User.banned_until,
                User.restore_until,
            ).where(User.id == user_id)
        )
    ).one_or_none()
    if row is None:
        return None
    authz = Authz(
        row.status,
        row.token_version,
        frozenset(row.roles),
        row.ban_reason,
        row.banned_until,
        row.restore_until,
    )
    payload = {
        "status": authz.status,
        "ver": authz.token_version,
        "roles": sorted(authz.roles),
        "ban_reason": authz.ban_reason,
        "banned_until": authz.banned_until.isoformat() if authz.banned_until else None,
        "restore_until": authz.restore_until.isoformat() if authz.restore_until else None,
    }
    await redis.set(authz_key(user_id), orjson.dumps(payload), ex=AUTHZ_TTL_S)
    return authz


def account_banned(reason: str | None, until: datetime | None, *, appeal: str) -> Forbidden:
    """The 403 for a suspended account, with what the Suspended screen shows."""
    return Forbidden(
        "This account has been suspended.",
        code="ACCOUNT_BANNED",
        details={"reason": reason, "until": iso_utc(until), "appeal": appeal},
    )


async def invalidate_authz(redis: Redis, user_id: uuid.UUID) -> None:
    await redis.delete(authz_key(user_id))
