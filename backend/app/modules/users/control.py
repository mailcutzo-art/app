"""Control messages to a player's live socket (``ctl:u:{uid}``, docs/realtime-engine.md).

The realtime gateway subscribes for each of its sockets and closes the socket on ``revoke``
and ``ban`` with ``4403`` (docs/protocol.md). Publish only after the change has committed.
"""

import uuid
from enum import StrEnum

import orjson
from redis.asyncio import Redis


class ControlType(StrEnum):
    REVOKE = "revoke"  # the sessions ended (account deleted, signed out everywhere)
    BAN = "ban"


def control_channel(user_id: uuid.UUID) -> str:
    return f"ctl:u:{user_id}"


async def publish_control(
    redis: Redis, user_id: uuid.UUID, kind: ControlType, *, reason: str | None = None
) -> None:
    message = {"type": kind.value, "reason": reason}
    await redis.publish(control_channel(user_id), orjson.dumps(message))
