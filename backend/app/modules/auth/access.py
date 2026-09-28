"""Per-request session state kept in Redis: revocation markers and the last-seen gate."""

import uuid
from collections.abc import Iterable
from datetime import datetime

from redis.asyncio import Redis
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.tokens import ACCESS_TOKEN_TTL, VERIFY_LEEWAY
from app.modules.auth.models import DeviceSession, RevokeReason
from app.modules.realtime.control import revoke_sessions
from app.modules.users.models import User

# A revoked session's access tokens stay cryptographically valid until they expire; the marker
# rejects them until then.
REVOKED_MARKER_TTL = ACCESS_TOKEN_TTL + VERIFY_LEEWAY
# Requests record activity at most this often per session.
ACTIVITY_INTERVAL_S = 300


def revoked_session_key(session_id: uuid.UUID) -> str:
    return f"revoked_sid:{session_id}"


def activity_gate_key(session_id: uuid.UUID) -> str:
    return f"seen:{session_id}"


async def mark_sessions_revoked(
    redis: Redis, session_ids: Iterable[uuid.UUID], reason: RevokeReason, *, user_id: uuid.UUID
) -> None:
    """Reject the sessions' remaining access tokens (the marker holds why they ended) and
    close their realtime sockets (4403)."""
    ended = list(session_ids)
    ttl = int(REVOKED_MARKER_TTL.total_seconds())
    async with redis.pipeline(transaction=False) as pipe:
        for session_id in ended:
            pipe.set(revoked_session_key(session_id), reason.value, ex=ttl)
        await pipe.execute()
    await revoke_sessions(redis, user_id, ended, reason.value)


def revoke_reason(marker: str) -> str | None:
    """The reason stored in a revocation marker (``None`` for markers without one)."""
    return marker if marker in {reason.value for reason in RevokeReason} else None


async def record_activity(
    db: AsyncSession, *, user_id: uuid.UUID, session_id: uuid.UUID, now: datetime
) -> None:
    await db.execute(
        update(DeviceSession).where(DeviceSession.id == session_id).values(last_seen_at=now)
    )
    await db.execute(update(User).where(User.id == user_id).values(last_seen_at=now))
