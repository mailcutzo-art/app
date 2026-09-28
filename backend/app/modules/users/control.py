"""Control messages to a player's live socket (``ctl:u:{uid}``, docs/realtime-engine.md).

The realtime gateway subscribes for each of its sockets and closes the socket on ``revoke``
and ``ban`` with ``4403`` (docs/protocol.md). Messages are ``{"type", "reason"}``, plus ``sid``
when a ``revoke`` ends one session only (without it every socket of the user closes). Publish
only after the change has committed.
"""

import uuid
from collections.abc import Iterable
from enum import StrEnum
from typing import Any

import orjson
from redis.asyncio import Redis


class ControlType(StrEnum):
    REVOKE = "revoke"  # sessions ended (one with ``sid``; all without: account deleted)
    BAN = "ban"


def control_channel(user_id: uuid.UUID) -> str:
    return f"ctl:u:{user_id}"


def control_message(
    kind: ControlType, *, reason: str | None = None, session_id: uuid.UUID | None = None
) -> bytes:
    message: dict[str, Any] = {"type": kind.value, "reason": reason}
    if session_id is not None:
        message["sid"] = str(session_id)
    return orjson.dumps(message)


async def publish_control(
    redis: Redis, user_id: uuid.UUID, kind: ControlType, *, reason: str | None = None
) -> None:
    """Close every socket of the user."""
    await redis.publish(control_channel(user_id), control_message(kind, reason=reason))


async def revoke_sessions(
    redis: Redis, user_id: uuid.UUID, session_ids: Iterable[uuid.UUID], reason: str
) -> None:
    """Close the sockets of these sessions only (sign-out, replaced, reuse detection)."""
    channel = control_channel(user_id)
    async with redis.pipeline(transaction=False) as pipe:
        for session_id in session_ids:
            pipe.publish(
                channel,
                control_message(ControlType.REVOKE, reason=reason, session_id=session_id),
            )
        await pipe.execute()
