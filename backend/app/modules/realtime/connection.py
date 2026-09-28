"""One player's WebSocket on this node: outbound queue, inbound limits, heartbeat and the match
channels it follows.

- **Outbound.** At most 256 queued frames. When full, ``q.progress`` and ``emote`` frames are
  dropped first; if that isn't enough the socket closes with 1013 and the client resumes.
- **Inbound.** A token bucket of 10 frames a second with bursts of 30; the third violation
  closes with 4429.
- **Heartbeat.** ``ping {n}`` every ``hb_s`` (30 s idle, 10 s queued, 5 s in a match, announced
  with ``hb {s}``). The median of the last 10 round trips sets the latency allowance. Silence
  past the stale limit for the state closes the socket.
- **Match channels.** Following ``m:<mid>`` subscribes the node to ``ev:m:<mid>``; events are
  buffered until the snapshot or replay has been sent, then forwarded in ``seq`` order.
"""

import asyncio
import contextlib
import statistics
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Literal

import orjson
import structlog
from starlette.websockets import WebSocket, WebSocketDisconnect, WebSocketState

from app.modules.realtime import protocol, views
from app.modules.realtime.engine.scoring import latency_allowance
from app.modules.realtime.protocol import CloseCode

if TYPE_CHECKING:
    from app.modules.realtime.node import RtNode

log = structlog.stdlib.get_logger(__name__)

OUTBOUND_LIMIT = 256
INBOUND_RATE = 10.0
INBOUND_BURST = 30.0
MAX_VIOLATIONS = 3
RTT_SAMPLES = 10

State = Literal["idle", "queue", "match"]


@dataclass(slots=True)
class MatchFollow:
    """A match channel this socket follows: the last seq forwarded, and events held back
    while the snapshot or replay is being sent."""

    last_seq: int = 0
    buffering: bool = True
    held: list[dict[str, Any]] = field(default_factory=list)


class Connection:
    def __init__(
        self,
        node: "RtNode",
        websocket: WebSocket,
        *,
        user_id: uuid.UUID,
        session_id: str,
        roles: list[str],
        device: str,
        build: int,
    ) -> None:
        self.node = node
        self.websocket = websocket
        self.user_id = user_id
        self.uid = str(user_id)
        self.session_id = session_id
        self.roles = roles
        self.device = device
        self.build = build
        self.conn_id = uuid.uuid4().hex[:16]
        self.state: State = "idle"
        self.foreground = True
        self.matches: dict[str, MatchFollow] = {}
        self.closed = False
        self.close_code: int | None = None
        self._outbound: deque[tuple[str, bool]] = deque()
        self._wake = asyncio.Event()
        self._tokens = INBOUND_BURST
        self._tokens_at = time.monotonic()
        self._violations = 0
        self._pings: dict[int, float] = {}
        self._ping_n = 0
        self._last_ping = time.monotonic()
        self._rtts: deque[float] = deque(maxlen=RTT_SAMPLES)
        self.lat_ms = latency_allowance(None)
        self.last_frame_at = time.monotonic()

    # Outbound

    def send(self, frame: dict[str, Any]) -> None:
        self.send_text(protocol.encode(frame), droppable=frame.get("t") in protocol.DROPPABLE_TYPES)

    def send_text(self, text: str, *, droppable: bool = False) -> None:
        if self.closed:
            return
        if len(self._outbound) >= OUTBOUND_LIMIT:
            if droppable:
                return
            self._outbound = deque(item for item in self._outbound if not item[1])
            if len(self._outbound) >= OUTBOUND_LIMIT:
                self.close_soon(CloseCode.TRY_AGAIN_LATER, "too slow")
                return
        self._outbound.append((text, droppable))
        self._wake.set()

    def reply(
        self, ref: str | None, event_type: str, data: dict[str, Any], *, ch: str | None = None
    ) -> None:
        """A per-player reply (never logged, no seq)."""
        payload = dict(data)
        if ref is not None and event_type in {"ack", "error", "ans.ack"}:
            payload.setdefault("ref", ref)
        self.send(
            protocol.frame(
                event_type, payload, ch=ch or protocol.USER_CHANNEL, ts=self.node.clock.now_ms()
            )
        )

    def ack(self, ref: str | None, *, ch: str | None = None) -> None:
        self.reply(ref, "ack", {}, ch=ch)

    def error(
        self,
        ref: str | None,
        code: str,
        message: str,
        *,
        details: dict[str, Any] | None = None,
        retryable: bool = False,
        ch: str | None = None,
    ) -> None:
        self.reply(
            ref,
            "error",
            {"code": code, "message": message, "retryable": retryable, "details": details or {}},
            ch=ch,
        )

    async def writer(self) -> None:
        """Sends queued frames until the socket closes."""
        try:
            while not self.closed:
                if not self._outbound:
                    self._wake.clear()
                    await self._wake.wait()
                    continue
                text, _ = self._outbound.popleft()
                await self.websocket.send_text(text)
        except (RuntimeError, OSError, WebSocketDisconnect):  # the reader sees the disconnect
            self.closed = True

    def close_soon(self, code: int, reason: str) -> None:
        """Close from a callback (pub/sub, a full queue) without awaiting."""
        if self.closed:
            return
        self.closed = True
        self.close_code = code
        self._wake.set()
        asyncio.get_running_loop().create_task(self._close(code, reason))

    async def close(self, code: int, reason: str) -> None:
        if self.closed and self.close_code is not None:
            return
        self.closed = True
        self.close_code = code
        self._wake.set()
        await self._close(code, reason)

    async def _close(self, code: int, reason: str) -> None:
        log.info("ws.closed", code=code, reason=reason, user_id=self.uid)
        if self.websocket.application_state != WebSocketState.DISCONNECTED:
            with contextlib.suppress(Exception):
                await self.websocket.close(code=code, reason=reason)

    # Inbound limits

    def allow_frame(self) -> bool:
        """Spend a token; False when over the limit (and closes on the third violation)."""
        now = time.monotonic()
        self.last_frame_at = now
        self._tokens = min(INBOUND_BURST, self._tokens + (now - self._tokens_at) * INBOUND_RATE)
        self._tokens_at = now
        if self._tokens >= 1:
            self._tokens -= 1
            return True
        self._violations += 1
        if self._violations >= MAX_VIOLATIONS:
            self.close_soon(CloseCode.RATE_LIMITED, "rate limited")
        return False

    # Heartbeat

    @property
    def hb_s(self) -> int:
        settings = self.node.settings
        return {
            "idle": settings.rt_hb_idle_s,
            "queue": settings.rt_hb_queue_s,
            "match": settings.rt_hb_match_s,
        }[self.state]

    @property
    def stale_s(self) -> float:
        settings = self.node.settings
        return {
            "idle": settings.rt_stale_idle_s,
            "queue": settings.rt_stale_queue_s,
            "match": settings.rt_stale_match_s,
        }[self.state]

    def set_state(self, state: State) -> None:
        if state != self.state:
            self.state = state
            self.reply(None, "hb", {"s": self.hb_s})

    async def heartbeat(self) -> None:
        """Pings every ``hb_s``; closes the socket after ``stale_s`` without any frame."""
        while not self.closed:
            await asyncio.sleep(min(0.5, self.hb_s / 4))
            now = time.monotonic()
            if now - self.last_frame_at > self.stale_s:
                await self.close(CloseCode.NORMAL, "stale")
                return
            if now - self._last_ping >= self.hb_s:
                self._last_ping = now
                self._ping_n += 1
                self._pings[self._ping_n] = now
                for n in [n for n in self._pings if n < self._ping_n - RTT_SAMPLES]:
                    del self._pings[n]
                self.reply(None, "ping", {"n": self._ping_n})
                await self.node.refresh_presence(self)

    def pong(self, n: Any) -> int | None:
        """Records a round trip; returns the new latency allowance if it changed."""
        sent = self._pings.pop(n, None) if isinstance(n, int) else None
        if sent is None:
            return None
        self._rtts.append((time.monotonic() - sent) * 1000)
        allowance = latency_allowance(statistics.median(self._rtts))
        if allowance == self.lat_ms:
            return None
        self.lat_ms = allowance
        return allowance

    # Match channels

    def on_match_event(self, channel: str, message: str) -> None:
        """Hub listener for ``ev:m:<mid>``."""
        mid = channel.removeprefix("ev:m:")
        follow = self.matches.get(mid)
        if follow is None:
            return
        envelope = orjson.loads(message)
        if follow.buffering:
            follow.held.append(envelope)
            return
        self.forward(mid, follow, envelope)

    def forward(self, mid: str, follow: MatchFollow, envelope: dict[str, Any]) -> None:
        seq = int(envelope.get("seq") or 0)
        if seq <= follow.last_seq:
            return
        follow.last_seq = seq
        self.send(views.for_viewer(envelope, self.uid))
        if envelope.get("t") == "match.end":
            self.node.spawn(self.node.refresh_state(self))

    def on_user_event(self, _channel: str, message: str) -> None:
        """Hub listener for ``ev:u:<uid>``: per-player events, forwarded as they are."""
        envelope = orjson.loads(message)
        self.send(envelope)
        event_type = envelope.get("t")
        if event_type == "mm.found":
            mid = str(envelope["d"]["match_id"])
            self.node.spawn(self.node.follow_match(self, mid, last_seq=None))
        if event_type in {"mm.found", "mm.cancelled", "mm.requeued", "mm.queued"}:
            self.node.spawn(self.node.refresh_state(self))

    def on_control(self, _channel: str, message: str) -> None:
        """Hub listener for ``ctl:u:<uid>``: another device, a revoked session or a ban."""
        command = orjson.loads(message)
        kind = command.get("type")
        if kind == "supersede" and command.get("conn_id") != self.conn_id:
            self.close_soon(CloseCode.SUPERSEDED, "playing on another device")
        elif kind == "revoke" and command.get("sid") in {None, self.session_id}:
            self.close_soon(CloseCode.REVOKED, "session revoked")
        elif kind == "ban":
            self.close_soon(CloseCode.REVOKED, "account banned")
