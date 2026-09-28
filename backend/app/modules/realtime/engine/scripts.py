"""The Lua scripts that make every change to live match and queue state, with typed wrappers.

Each match script is ``lua/lib.lua`` followed by the script's own body, so they share one
implementation of events, timers, reveals and results. Nodes never read-modify-write match state
from Python; see ``docs/realtime-engine.md`` ("Scripts").
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import orjson
from redis.asyncio import Redis

from app.core.redis import LuaScript
from app.modules.realtime import keys

LUA_DIR = Path(__file__).parent / "lua"
LIB_SOURCE = (LUA_DIR / "lib.lua").read_text()


def _script(name: str) -> LuaScript:
    return LuaScript(LIB_SOURCE + "\n" + (LUA_DIR / f"{name}.lua").read_text())


_CREATE = _script("create")
_READY = _script("ready")
_ADVANCE = _script("advance")
_ANSWER = _script("answer")
_CONN = _script("conn")
_FORFEIT = _script("forfeit")
_EMOTE = _script("emote")
_LATENCY = _script("latency")
_EVENT = _script("event")
_FINALIZE = _script("finalize")
_MM_JOIN = _script("mm_join")
_MM_CANCEL = _script("mm_cancel")
_MM_PAIR = _script("mm_pair")
_MM_UNPAIR = _script("mm_unpair")
_LEASES = _script("leases")
_SNAPSHOT = _script("snapshot")

TERMINAL_PHASES = frozenset({"finished", "aborted", "voided"})


@dataclass(frozen=True, slots=True)
class Step:
    """What a state-changing script did: ``status`` (usually the new phase), the match version
    and when the match next needs its timer (0: never)."""

    status: str
    ver: int
    due: int

    @property
    def ended(self) -> bool:
        return self.status in TERMINAL_PHASES


@dataclass(frozen=True, slots=True)
class AnswerStep:
    status: str  # accepted, late, too_early, invalid or wrong_phase
    dup: bool
    ver: int
    due: int


def _step(result: Sequence[Any]) -> Step:
    return Step(str(result[0]), int(result[1]), int(result[2]))


def _json(value: Any) -> str:
    return orjson.dumps(value).decode()


async def create(
    redis: Redis,
    mid: str,
    config: Mapping[str, Any],
    questions: Sequence[Mapping[str, Any]],
    *,
    ttl_s: int,
) -> Step:
    return _step(
        await _CREATE(redis, keys=[keys.match(mid)], args=[_json(config), _json(questions), ttl_s])
    )


async def ready(redis: Redis, mid: str, uid: str) -> Step:
    return _step(await _READY(redis, keys=[keys.match(mid)], args=[uid]))


async def advance(redis: Redis, mid: str, expected_ver: int) -> Step:
    return _step(await _ADVANCE(redis, keys=[keys.match(mid)], args=[expected_ver]))


async def answer(
    redis: Redis,
    mid: str,
    uid: str,
    *,
    q: int,
    opt: str,
    el_ms: int,
    bot_ms: int | None = None,
) -> AnswerStep:
    status, dup, ver, due = await _ANSWER(
        redis,
        keys=[keys.match(mid)],
        args=[uid, q, opt, el_ms, "" if bot_ms is None else bot_ms],
    )
    return AnswerStep(str(status), bool(int(dup)), int(ver), int(due))


async def connection(
    redis: Redis, mid: str, uid: str, *, connected: bool, extra_ms: int = 0
) -> Step:
    state = "connected" if connected else "dropped"
    return _step(await _CONN(redis, keys=[keys.match(mid)], args=[uid, state, extra_ms]))


async def forfeit(redis: Redis, mid: str, uid: str) -> Step:
    return _step(await _FORFEIT(redis, keys=[keys.match(mid)], args=[uid]))


async def emote(redis: Redis, mid: str, uid: str, emote: str, *, gap_ms: int, limit: int) -> str:
    (status,) = await _EMOTE(redis, keys=[keys.match(mid)], args=[uid, emote, gap_ms, limit])
    return str(status)


async def set_latency(redis: Redis, mid: str, uid: str, lat_ms: int) -> bool:
    return bool(await _LATENCY(redis, keys=[keys.match(mid)], args=[uid, lat_ms]))


async def emit(redis: Redis, mid: str, event_type: str, payload: Mapping[str, Any]) -> int:
    """Emit one shared event on the match channel; 0 if the match is gone."""
    return int(await _EVENT(redis, keys=[keys.match(mid)], args=[event_type, _json(payload)]))


async def finalize(redis: Redis, mid: str, *, ttl_s: int) -> list[str]:
    """Mark a settled match and let its keys expire; returns its human players."""
    return [str(uid) for uid in await _FINALIZE(redis, keys=[keys.match(mid)], args=[mid, ttl_s])]


async def mm_join(
    redis: Redis,
    ticket_id: str,
    fields: Mapping[str, Any],
    *,
    busy_ttl_s: int,
    max_wait_ms: int,
    requeue_min_ms: int,
    replaces: str = "",
) -> tuple[bool, str]:
    """Queue a ticket. (True, joined_ms) or (False, the busy value in the way)."""
    status, value = await _MM_JOIN(
        redis,
        keys=[
            keys.busy(str(fields["uid"])),
            keys.ticket(ticket_id),
            keys.queue(str(fields["mode"]), str(fields["subject"])),
        ],
        args=[ticket_id, _json(fields), busy_ttl_s, max_wait_ms, requeue_min_ms, replaces],
    )
    return status == "ok", str(value)


async def mm_cancel(
    redis: Redis, uid: str, ticket_id: str, *, mode: str, subject: str
) -> tuple[str, str]:
    """("cancelled", hold id), ("matched", match id) or ("gone", "")."""
    status, value = await _MM_CANCEL(
        redis,
        keys=[keys.busy(uid), keys.ticket(ticket_id), keys.queue(mode, subject)],
        args=[ticket_id],
    )
    return str(status), str(value)


async def mm_pair(
    redis: Redis,
    a: tuple[str, str],
    b: tuple[str, str],
    *,
    mode: str,
    subject: str,
    mid: str,
    busy_ttl_s: int,
) -> bool:
    """Take tickets ``a`` and ``b`` ((uid, ticket id) each) out of the queue for ``mid``."""
    return bool(
        await _MM_PAIR(
            redis,
            keys=[
                keys.busy(a[0]),
                keys.busy(b[0]),
                keys.ticket(a[1]),
                keys.ticket(b[1]),
                keys.queue(mode, subject),
            ],
            args=[a[1], b[1], mid, busy_ttl_s],
        )
    )


async def mm_unpair(
    redis: Redis,
    a: tuple[str, str, Mapping[str, str]],
    b: tuple[str, str, Mapping[str, str]],
    *,
    mode: str,
    subject: str,
    mid: str,
    busy_ttl_s: int,
) -> int:
    """Put tickets back after a failed match creation: (uid, ticket id, original fields)."""
    return int(
        await _MM_UNPAIR(
            redis,
            keys=[
                keys.busy(a[0]),
                keys.busy(b[0]),
                keys.ticket(a[1]),
                keys.ticket(b[1]),
                keys.queue(mode, subject),
            ],
            args=[a[1], b[1], mid, _json(dict(a[2])), _json(dict(b[2])), busy_ttl_s],
        )
    )


async def renew_leases(
    redis: Redis, lease_keys: Sequence[str], holder: str, ttl_ms: int
) -> set[int]:
    """Renew the leases ``holder`` still holds; returns the indexes of those it lost."""
    if not lease_keys:
        return set()
    lost = await _LEASES(redis, keys=list(lease_keys), args=[holder, ttl_ms])
    return {int(index) - 1 for index in lost}


async def release_leases(redis: Redis, lease_keys: Sequence[str], holder: str) -> None:
    if lease_keys:
        await _LEASES(redis, keys=list(lease_keys), args=[holder, 0])


async def read_snapshot(redis: Redis, mid: str, viewer: str) -> dict[str, Any] | None:
    """The raw state behind a ``match.snapshot`` for ``viewer``, read atomically."""
    raw = await _SNAPSHOT(redis, keys=[keys.match(mid)], args=[viewer])
    if raw is None:
        return None
    state: dict[str, Any] = orjson.loads(raw)
    return state
