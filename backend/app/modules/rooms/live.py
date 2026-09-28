"""The live lobby of a room in Redis: typed wrappers around its Lua scripts.

Every room script is the engine's ``lib.lua``, then ``lua/room_lib.lua``, then its own body;
each change is atomic, bumps the room channel's ``seq``, appends ``room.state`` (or
``room.started`` / ``room.closed``) to the room log and publishes it on ``ev:r:{rid}``. Any
process can run them: the api creates rooms, rt nodes run everything live, and the worker
takes banned or deleted players out.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import orjson
from redis.asyncio import Redis

from app.core.redis import LuaScript
from app.modules.realtime import keys, protocol
from app.modules.realtime.engine.scripts import LIB_SOURCE

LUA_DIR = Path(__file__).parent / "lua"
ROOM_LIB = (LUA_DIR / "room_lib.lua").read_text()


def _script(name: str) -> LuaScript:
    return LuaScript("\n".join([LIB_SOURCE, ROOM_LIB, (LUA_DIR / f"{name}.lua").read_text()]))


_CREATE = _script("room_create")
_JOIN = _script("room_join")
_LEAVE = _script("room_leave")
_OP = _script("room_op")
_START = _script("room_start")
_TICK = _script("room_tick")
_READ = _script("room_read")


@dataclass(frozen=True, slots=True)
class Outcome:
    """What a room script did: ``status`` and a status-specific ``detail``."""

    status: str
    detail: str


def _outcome(result: Sequence[Any]) -> Outcome:
    return Outcome(str(result[0]), str(result[1]))


def _json(value: Any) -> str:
    return orjson.dumps(value).decode()


async def create(redis: Redis, rid: str, config: Mapping[str, Any]) -> Outcome:
    return _outcome(await _CREATE(redis, keys=[keys.room(rid)], args=[_json(config)]))


async def join(
    redis: Redis, rid: str, uid: str, card: Mapping[str, Any], *, spectator: bool = False
) -> Outcome:
    return _outcome(
        await _JOIN(
            redis,
            keys=[keys.room(rid)],
            args=[uid, _json(card), "spectator" if spectator else "player"],
        )
    )


async def leave(redis: Redis, rid: str, uid: str, *, kicked: bool = False) -> Outcome:
    return _outcome(await _LEAVE(redis, keys=[keys.room(rid)], args=[uid, "1" if kicked else "0"]))


async def op(
    redis: Redis,
    rid: str,
    name: str,
    uid: str,
    arg: Mapping[str, Any] | None = None,
    *,
    settings: Mapping[str, Any] | None = None,
) -> Outcome:
    return _outcome(
        await _OP(
            redis,
            keys=[keys.room(rid)],
            args=[name, uid, _json(arg or {}), _json(settings) if settings is not None else ""],
        )
    )


async def claim_start(redis: Redis, rid: str, uid: str, mid: str) -> tuple[str, list[str]]:
    """(status, players): ``ok`` with the players of the new game, or why not."""
    status, detail = await _START(redis, keys=[keys.room(rid)], args=[uid, mid])
    players: list[str] = orjson.loads(detail) if status == "ok" else []
    return str(status), players


async def tick(redis: Redis, rid: str) -> Outcome:
    return _outcome(await _TICK(redis, keys=[keys.room(rid)], args=[]))


async def read(redis: Redis, rid: str) -> dict[str, Any] | None:
    """``{seq, state, status, match, active_ms, idle_ms}``, or None if the room is gone."""
    raw = await _READ(redis, keys=[keys.room(rid)], args=[])
    if raw is None:
        return None
    value: dict[str, Any] = orjson.loads(raw)
    return value


async def snapshot(redis: Redis, rid: str, *, ts: int) -> dict[str, Any] | None:
    """The ``room.state`` frame whose seq is the channel's current seq."""
    current = await read(redis, rid)
    if current is None or current["status"] == "closed":
        return None
    return protocol.frame(
        "room.state", current["state"], ch=room_channel(rid), ts=ts, seq=int(current["seq"])
    )


def room_channel(rid: str) -> str:
    return f"r:{rid}"
