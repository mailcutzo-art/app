"""Realtime protocol v1 constants and frames shared by the gateway and the engine.

See ``docs/protocol.md``. Every frame is one JSON object ``{v, t, id, ch, seq, ts, d}``; server
frames carry ``ch`` and ``ts``, and ``seq`` only on resumable channels (``m:``, ``r:``).
"""

from enum import IntEnum, StrEnum
from typing import Any

import orjson
from redis.asyncio import Redis

from app.modules.realtime import keys

PROTOCOL_VERSION = 1
HELLO_TIMEOUT_S = 5.0
MAX_INBOUND_FRAME_BYTES = 4096
MAX_MESSAGE_ID_LENGTH = 36
USER_CHANNEL = "u"


class CloseCode(IntEnum):
    """WebSocket close codes the server uses (docs/protocol.md section 4)."""

    NORMAL = 1000
    SERVER_RESTART = 1012
    TRY_AGAIN_LATER = 1013
    BAD_MESSAGE = 4400
    BAD_TICKET = 4401
    REVOKED = 4403
    HELLO_TIMEOUT = 4408
    SUPERSEDED = 4409
    UPDATE_REQUIRED = 4426
    RATE_LIMITED = 4429


class ErrorCode(StrEnum):
    BAD_REQUEST = "BAD_REQUEST"
    NOT_FOUND = "NOT_FOUND"
    NOT_ALLOWED = "NOT_ALLOWED"
    BUSY = "BUSY"
    ALREADY_MATCHED = "ALREADY_MATCHED"
    INSUFFICIENT_COINS = "INSUFFICIENT_COINS"
    COOLDOWN = "COOLDOWN"
    RATE_LIMITED = "RATE_LIMITED"
    UNAVAILABLE = "UNAVAILABLE"
    LIVE_ELSEWHERE = "LIVE_ELSEWHERE"


# Dropped first when a connection's outbound queue is full.
DROPPABLE_TYPES = frozenset({"q.progress", "emote"})


def match_channel(match_id: str) -> str:
    return f"m:{match_id}"


def frame(
    event_type: str,
    data: dict[str, Any],
    *,
    ch: str = USER_CHANNEL,
    ts: int,
    seq: int | None = None,
) -> dict[str, Any]:
    out: dict[str, Any] = {"v": PROTOCOL_VERSION, "t": event_type, "ch": ch, "ts": ts}
    if seq is not None:
        out["seq"] = seq
    out["d"] = data
    return out


def encode(value: dict[str, Any]) -> str:
    return orjson.dumps(value).decode()


async def publish_to_user(
    redis: Redis,
    user_id: str,
    event_type: str,
    data: dict[str, Any],
    *,
    ts: int,
    ch: str = USER_CHANNEL,
) -> None:
    """Deliver an event to one user's live socket, wherever it is (``ev:u:{uid}``, no seq)."""
    await redis.publish(keys.user_events(user_id), encode(frame(event_type, data, ch=ch, ts=ts)))
