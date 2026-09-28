"""Control messages to a user's live socket, on any rt node (``ctl:u:{uid}``).

- ``revoke``: the session ended (logout, signed out from another device, reuse detection); the
  socket of that session closes with 4403.
- ``ban``: the account was suspended; every socket of the user closes with 4403.
- ``supersede`` is sent by the gateway itself when a newer socket connects (4409).
"""

import uuid
from collections.abc import Iterable

import orjson
from redis.asyncio import Redis

from app.modules.realtime import keys


async def revoke_sessions(
    redis: Redis, user_id: uuid.UUID, session_ids: Iterable[uuid.UUID], reason: str
) -> None:
    channel = keys.user_control(str(user_id))
    async with redis.pipeline(transaction=False) as pipe:
        for session_id in session_ids:
            pipe.publish(
                channel, orjson.dumps({"type": "revoke", "sid": str(session_id), "reason": reason})
            )
        await pipe.execute()


async def disconnect_banned(redis: Redis, user_id: uuid.UUID) -> None:
    """Close every socket of a suspended account (moderation calls this with the ban)."""
    await redis.publish(keys.user_control(str(user_id)), orjson.dumps({"type": "ban"}))
