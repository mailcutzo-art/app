"""Control messages to a user's live socket, on any rt node (``ctl:u:{uid}``).

The publishers live in ``app.modules.users.control`` (one message format for every sender);
the gateway reads them in ``Connection.on_control``:

- ``revoke``: sessions ended. With ``sid`` only that session's socket closes (4403); without
  it (account deleted) every socket of the user does.
- ``ban``: the account was suspended; every socket of the user closes with 4403.
- ``supersede`` is sent by the gateway itself when a newer socket connects (4409).
"""

import uuid

from redis.asyncio import Redis

from app.modules.users.control import ControlType, publish_control, revoke_sessions

__all__ = ["disconnect_banned", "revoke_sessions"]


async def disconnect_banned(redis: Redis, user_id: uuid.UUID, reason: str | None = None) -> None:
    """Close every socket of a suspended account."""
    await publish_control(redis, user_id, ControlType.BAN, reason=reason)
