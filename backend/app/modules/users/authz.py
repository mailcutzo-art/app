"""What every authenticated request must know about its user, cached briefly in Redis.

Status, token version and roles decide whether a valid access token is still honoured. They are
cached for ``AUTHZ_TTL_S`` and the cache is dropped whenever they change, so bans and role
changes apply within a minute even if an invalidation is missed.
"""

import uuid
from dataclasses import dataclass

import orjson
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.users.models import User

AUTHZ_TTL_S = 60


@dataclass(frozen=True, slots=True)
class Authz:
    status: str
    token_version: int
    roles: frozenset[str]


def authz_key(user_id: uuid.UUID) -> str:
    return f"authz:{user_id}"


def parse_authz(raw: str | None) -> Authz | None:
    """A cached snapshot, or ``None`` when missing or unreadable."""
    if raw is None:
        return None
    try:
        data = orjson.loads(raw)
        return Authz(data["status"], int(data["ver"]), frozenset(data["roles"]))
    except (orjson.JSONDecodeError, KeyError, TypeError, ValueError):
        return None


async def load_authz(db: AsyncSession, redis: Redis, user_id: uuid.UUID) -> Authz | None:
    """Read the snapshot from the database and cache it; ``None`` if the user doesn't exist."""
    row = (
        await db.execute(
            select(User.status, User.token_version, User.roles).where(User.id == user_id)
        )
    ).one_or_none()
    if row is None:
        return None
    authz = Authz(row.status, row.token_version, frozenset(row.roles))
    payload = {"status": authz.status, "ver": authz.token_version, "roles": sorted(authz.roles)}
    await redis.set(authz_key(user_id), orjson.dumps(payload), ex=AUTHZ_TTL_S)
    return authz


async def invalidate_authz(redis: Redis, user_id: uuid.UUID) -> None:
    await redis.delete(authz_key(user_id))
