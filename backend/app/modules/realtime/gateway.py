"""WebSocket gateway at ``/v1/ws`` (``docs/protocol.md`` sections 1-4 and 10).

The socket must say ``hello`` within 5 s. The ticket in it is consumed with ``GETDEL``; then the
session must not be revoked, the account not banned or closed, and the protocol version and app
build supported (an old build may still finish a live match). The newest socket of a user wins
and the older one closes with 4409, except that a live match on another device is only moved
with ``takeover: true`` (``LIVE_ELSEWHERE``).

After ``welcome`` the gateway dispatches client messages, forwards events from Redis pub/sub,
and on disconnect starts the player's grace period in a live match (60 s more when the server
itself is restarting) or marks their queue ticket as disconnected.
"""

import asyncio
import contextlib
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

import orjson
import structlog
from fastapi import APIRouter, WebSocket
from redis.exceptions import RedisError
from starlette.websockets import WebSocketDisconnect

from app.core.clock import utc_now
from app.modules.auth.access import revoked_session_key
from app.modules.realtime import keys, protocol, rstr
from app.modules.realtime.connection import MAX_VIOLATIONS, Connection
from app.modules.realtime.engine import scripts
from app.modules.realtime.node import RtNode
from app.modules.realtime.protocol import CloseCode, ErrorCode
from app.modules.users.authz import authz_key, load_authz, parse_authz
from app.modules.users.models import UserStatus

log = structlog.stdlib.get_logger(__name__)

router = APIRouter()

EMOTES = frozenset({"gg", "nice", "wow", "oops"})
EMOTE_GAP_MS = 3000
EMOTES_PER_MATCH = 10

Handler = Callable[[RtNode, Connection, str | None, dict[str, Any]], Awaitable[None]]


class BadMessage(Exception):
    """A frame that isn't a protocol message: the socket closes with 4400."""


def parse_frame(text: str | None) -> dict[str, Any]:
    if text is None or len(text.encode()) > protocol.MAX_INBOUND_FRAME_BYTES:
        raise BadMessage
    try:
        frame = orjson.loads(text)
    except orjson.JSONDecodeError as exc:
        raise BadMessage from exc
    if not isinstance(frame, dict) or not isinstance(frame.get("t"), str):
        raise BadMessage
    data = frame.get("d", {})
    message_id = frame.get("id")
    if not isinstance(data, dict) or (
        message_id is not None
        and (not isinstance(message_id, str) or len(message_id) > protocol.MAX_MESSAGE_ID_LENGTH)
    ):
        raise BadMessage
    return frame


@router.websocket("/ws")
async def gateway(websocket: WebSocket) -> None:
    node: RtNode = websocket.app.state.rt_node
    await websocket.accept()
    if node.draining:
        await websocket.close(code=CloseCode.SERVER_RESTART, reason="server restarting")
        return
    try:
        async with asyncio.timeout(protocol.HELLO_TIMEOUT_S):
            message = await websocket.receive()
    except TimeoutError:
        await _close(websocket, CloseCode.HELLO_TIMEOUT, "hello timeout")
        return
    if message["type"] == "websocket.disconnect":
        return
    try:
        hello = parse_frame(message.get("text"))
        if hello["t"] != "hello":
            raise BadMessage
    except BadMessage:
        await _close(websocket, CloseCode.BAD_MESSAGE, "bad message")
        return
    conn = await _handshake(node, websocket, hello)
    if conn is None:
        return
    await _serve(node, conn, hello)


async def _close(websocket: WebSocket, code: int, reason: str) -> None:
    log.info("ws.closed", code=int(code), reason=reason)
    with contextlib.suppress(RuntimeError, WebSocketDisconnect):
        await websocket.close(code=code, reason=reason)


async def _handshake(
    node: RtNode, websocket: WebSocket, hello: dict[str, Any]
) -> Connection | None:
    data = hello["d"]
    ticket = data.get("ticket")
    raw = await node.redis.getdel(keys.rt_ticket(ticket)) if isinstance(ticket, str) else None
    if raw is None:
        await _close(websocket, CloseCode.BAD_TICKET, "bad ticket")
        return None
    claims = orjson.loads(raw)
    user_id = uuid.UUID(claims["uid"])
    if await node.redis.exists(revoked_session_key(uuid.UUID(claims["sid"]))):
        await _close(websocket, CloseCode.REVOKED, "session revoked")
        return None
    authz = parse_authz(await rstr.get(node.redis, authz_key(user_id)))
    if authz is None:
        async with node.sessionmaker() as db:
            authz = await load_authz(db, node.redis, user_id)
    if (
        authz is None
        or authz.banned(utc_now())
        or authz.status in {UserStatus.PENDING_DELETION, UserStatus.DELETED}
    ):
        await _close(websocket, CloseCode.REVOKED, "account unavailable")
        return None

    busy = await node.busy(str(user_id))
    in_match = busy is not None and busy.startswith("m:")
    build = data.get("build") if isinstance(data.get("build"), int) else 0
    async with node.sessionmaker() as db:
        config = await node.runtime_config.get(db, node.settings)
    if data.get("proto") != protocol.PROTOCOL_VERSION or (
        build < config.min_build and not in_match
    ):
        await _close(websocket, CloseCode.UPDATE_REQUIRED, "update required")
        return None

    conn = Connection(
        node,
        websocket,
        user_id=user_id,
        session_id=claims["sid"],
        roles=list(claims.get("roles", [])),
        device=str(claims.get("dev", "")),
        build=build,
    )
    current = await rstr.get(node.redis, keys.connection(conn.uid))
    other_session = current is not None and current.split("|")[-1] != conn.session_id
    if in_match and other_session and data.get("takeover") is not True and busy is not None:
        await websocket.send_text(
            protocol.encode(
                protocol.frame(
                    "error",
                    {
                        "ref": hello.get("id"),
                        "code": ErrorCode.LIVE_ELSEWHERE,
                        "message": "A live match is running on another device.",
                        "retryable": False,
                        "details": {"match_id": busy[2:]},
                    },
                    ts=node.clock.now_ms(),
                )
            )
        )
        await _close(websocket, CloseCode.SUPERSEDED, "live elsewhere")
        return None
    return conn


async def _serve(node: RtNode, conn: Connection, hello: dict[str, Any]) -> None:
    writer = asyncio.create_task(conn.writer())
    heartbeat: asyncio.Task[None] | None = None
    restart = False
    try:
        await node.register(conn)
        active = await node.active(conn.uid)
        conn.reply(
            None,
            "welcome",
            {
                "conn_id": conn.conn_id,
                "user_id": conn.uid,
                "server_ms": node.clock.now_ms(),
                "hb_s": conn.hb_s,
                "active": active,
            },
        )
        await node.refresh_state(conn)
        heartbeat = asyncio.create_task(conn.heartbeat())
        await _resume(node, conn, hello["d"].get("resume"), active)
        restart = await _read(node, conn)
    finally:
        conn.stop()
        if heartbeat is not None:
            heartbeat.cancel()
        writer.cancel()
        await asyncio.gather(writer, *([heartbeat] if heartbeat else []), return_exceptions=True)
        await _disconnected(node, conn, restart=restart or node.draining)


async def _resume(
    node: RtNode, conn: Connection, resume: Any, active: list[dict[str, Any]]
) -> None:
    """Replays the channels the client was on, and joins a live match it didn't list."""
    wanted: dict[str, int] = {}
    if isinstance(resume, list):
        for entry in resume[:8]:
            if isinstance(entry, dict) and isinstance(entry.get("ch"), str):
                last = entry.get("last_seq")
                wanted[entry["ch"]] = last if isinstance(last, int) else 0
    for item in active:
        if item["kind"] == "match":
            wanted.setdefault(item["ch"], 0)
            await node.match_connected(conn, item["id"])
        elif item["kind"] == "queue":
            await node.redis.hset(keys.ticket(item["id"]), "disc_ms", 0)
    for channel, last_seq in wanted.items():
        if channel.startswith("m:"):
            await node.follow_match(conn, channel[2:], last_seq=last_seq)


async def _read(node: RtNode, conn: Connection) -> bool:
    """Reads client frames until the socket closes; True if the server is restarting.

    After a close was requested it keeps reading (and ignoring) until the close handshake ends.
    """
    while True:
        message = await conn.websocket.receive()
        if message["type"] == "websocket.disconnect":
            return message.get("code") == CloseCode.SERVER_RESTART
        if conn.closed:
            continue
        try:
            frame = parse_frame(message.get("text"))
        except BadMessage:
            conn.close_soon(CloseCode.BAD_MESSAGE, "bad message")
            continue
        if not conn.allow_frame():
            conn.error(
                frame.get("id"),
                ErrorCode.RATE_LIMITED,
                "Too many messages.",
                details={"retry_after_s": 1},
                retryable=True,
            )
            if conn.violations >= MAX_VIOLATIONS:
                conn.close_soon(CloseCode.RATE_LIMITED, "rate limited")
            continue
        handler = HANDLERS.get(frame["t"])
        if handler is None:
            continue  # unknown types are ignored within v1
        try:
            await handler(node, conn, frame.get("id"), frame.get("d") or {})
        except RedisError:
            log.warning("ws.handler_unavailable", type=frame["t"], exc_info=True)
            conn.error(frame.get("id"), ErrorCode.UNAVAILABLE, "Please try again.", retryable=True)
        except Exception:
            log.exception("ws.handler_failed", type=frame["t"])
            conn.error(frame.get("id"), ErrorCode.UNAVAILABLE, "Please try again.", retryable=True)


async def _disconnected(node: RtNode, conn: Connection, *, restart: bool) -> None:
    try:
        current = await node.unregister(conn)
        if not current:
            return  # a newer socket took over; the player is still here
        busy = await node.busy(conn.uid)
        if busy is None:
            return
        kind, _, ident = busy.partition(":")
        if kind == "m":
            await node.match_dropped(conn.uid, ident, restart=restart)
        elif kind == "q":
            await node.redis.hset(keys.ticket(ident), "disc_ms", node.clock.now_ms())
    except RedisError:
        log.warning("ws.disconnect_cleanup_failed", user_id=conn.uid, exc_info=True)


# Handlers


async def _clock_ping(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    conn.reply(None, "clock.pong", {"c0": d.get("c0"), "s": node.clock.now_ms()})


async def _pong(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    allowance = conn.pong(d.get("n"))
    if allowance is not None:
        for mid in list(conn.matches):
            await scripts.set_latency(node.redis, mid, conn.uid, allowance)


async def _client_state(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    state = d.get("state")
    if state not in {"foreground", "background"}:
        conn.error(ref, ErrorCode.BAD_REQUEST, "Unknown app state.")
        return
    conn.foreground = state == "foreground"
    now = node.clock.now_ms()
    if conn.foreground:
        await node.redis.delete(keys.background(conn.uid))
    else:
        await node.redis.set(keys.background(conn.uid), now, ex=3600)
    busy = await node.busy(conn.uid)
    if busy is not None and busy.startswith("q:"):
        await node.redis.hset(keys.ticket(busy[2:]), "bg_ms", 0 if conn.foreground else now)


async def _sync(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    channel = d.get("ch")
    last_seq = d.get("last_seq")
    if not isinstance(channel, str) or not isinstance(last_seq, int):
        conn.error(ref, ErrorCode.BAD_REQUEST, "sync needs ch and last_seq.")
        return
    if not channel.startswith("m:") or not await node.follow_match(
        conn, channel[2:], last_seq=last_seq
    ):
        conn.error(ref, ErrorCode.NOT_FOUND, "This game isn't available.", ch=channel)


def _match_id(conn: Connection, ref: str | None, d: dict[str, Any]) -> str | None:
    mid = d.get("match_id")
    try:
        return str(uuid.UUID(mid)) if isinstance(mid, str) else None
    except ValueError:
        return None


async def _checked(
    node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]
) -> str | None:
    """The match id of a match message, if the sender plays in that match."""
    mid = _match_id(conn, ref, d)
    if mid is None:
        conn.error(ref, ErrorCode.BAD_REQUEST, "match_id is missing.")
        return None
    if not await node.is_player(mid, conn.uid):
        conn.error(ref, ErrorCode.NOT_FOUND, "This game isn't available.")
        return None
    return mid


async def _ready(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    mid = await _checked(node, conn, ref, d)
    if mid is None:
        return
    if mid not in conn.matches:
        await node.follow_match(conn, mid, last_seq=None)
    step = await scripts.ready(node.redis, mid, conn.uid)
    node.engine.report(mid, ver=step.ver, due=step.due)
    conn.ack(ref, ch=protocol.match_channel(mid))


async def _answer(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    mid = _match_id(conn, ref, d)
    q, opt, el_ms = d.get("q"), d.get("opt"), d.get("el_ms")
    if (
        mid is None
        or not isinstance(q, int)
        or not isinstance(opt, str)
        or len(opt) > 16
        or not isinstance(el_ms, int)
    ):
        conn.error(ref, ErrorCode.BAD_REQUEST, "ans.submit needs match_id, q, opt and el_ms.")
        return
    step = await scripts.answer(node.redis, mid, conn.uid, q=q, opt=opt, el_ms=max(0, el_ms))
    conn.reply(
        ref,
        "ans.ack",
        {"q": q, "status": step.status, "dup": step.dup},
        ch=protocol.match_channel(mid),
    )
    if not step.dup and step.status != "invalid":
        node.engine.report(mid, ver=step.ver, due=step.due)


async def _emote(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    mid = await _checked(node, conn, ref, d)
    if mid is None:
        return
    if d.get("e") not in EMOTES:
        conn.error(ref, ErrorCode.BAD_REQUEST, "Unknown emote.")
        return
    status = await scripts.emote(
        node.redis, mid, conn.uid, str(d["e"]), gap_ms=EMOTE_GAP_MS, limit=EMOTES_PER_MATCH
    )
    if status == "ok":
        conn.ack(ref, ch=protocol.match_channel(mid))
    else:
        conn.error(
            ref,
            ErrorCode.RATE_LIMITED,
            "Slow down with the emotes.",
            details={"retry_after_s": EMOTE_GAP_MS // 1000},
            retryable=True,
            ch=protocol.match_channel(mid),
        )


async def _forfeit(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    mid = await _checked(node, conn, ref, d)
    if mid is None:
        return
    step = await scripts.forfeit(node.redis, mid, conn.uid)
    node.engine.report(mid, ver=step.ver, due=step.due, ended=step.ended)
    conn.ack(ref, ch=protocol.match_channel(mid))


async def _rematch(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    mid = await _checked(node, conn, ref, d)
    if mid is not None:
        await node.rematches.respond(conn, ref, mid, accept=d.get("accept") is not False)


async def _mm_join(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    await node.matchmaker.join(conn, ref, d)


async def _mm_cancel(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    await node.matchmaker.cancel(conn, ref)


async def _mm_respond(node: RtNode, conn: Connection, ref: str | None, d: dict[str, Any]) -> None:
    await node.matchmaker.respond(conn, ref, d)


HANDLERS: dict[str, Handler] = {
    "clock.ping": _clock_ping,
    "pong": _pong,
    "client.state": _client_state,
    "sync": _sync,
    "mm.join": _mm_join,
    "mm.cancel": _mm_cancel,
    "mm.respond": _mm_respond,
    "match.ready": _ready,
    "ans.submit": _answer,
    "emote": _emote,
    "match.forfeit": _forfeit,
    "match.rematch": _rematch,
}
