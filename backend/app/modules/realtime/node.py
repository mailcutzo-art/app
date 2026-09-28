"""One ``rt`` process: its sockets, pub/sub fan-out, match owner, queue leaders and settlement.

Created by ``app.main_rt`` at startup and stopped on shutdown (``docs/realtime-engine.md``,
"Pieces"). Uvicorn closes every socket with 1012 when it gets SIGTERM, before the app's
shutdown runs; each socket's disconnect then gives its player the restart grace, and ``stop``
hands the match leases back so other nodes adopt the matches at once.
"""

import asyncio
import secrets
import uuid
from collections.abc import Coroutine
from typing import Any

import orjson
import structlog
from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.core.config import Settings
from app.core.redis import LuaScript
from app.modules.matches.busy import check_busy
from app.modules.matches.ports import Integrations
from app.modules.matches.settlement import SessionFactory, SettleDeps, settle_match
from app.modules.realtime import keys, protocol, rstr, views
from app.modules.realtime.clock import SharedClock
from app.modules.realtime.connection import Connection, MatchFollow, State
from app.modules.realtime.engine import scripts
from app.modules.realtime.engine.owner import MatchEngine
from app.modules.realtime.hub import Hub
from app.modules.system.runtime import RuntimeConfigCache

log = structlog.stdlib.get_logger(__name__)

# KEYS[1] rt:conn:<uid>; ARGV[1] this socket's value. Only the socket that set it may clear it.
_RELEASE_CONNECTION = LuaScript(
    """
if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0
"""
)


class RtNode:
    def __init__(
        self,
        *,
        settings: Settings,
        redis: Redis,
        sessionmaker: SessionFactory,
        integrations: Integrations,
    ) -> None:
        self.settings = settings
        self.redis = redis
        self.sessionmaker = sessionmaker
        self.integrations = integrations
        self.node_id = settings.rt_node_id or f"rt-{secrets.token_hex(4)}"
        self.clock = SharedClock()
        self.hub = Hub(redis)
        self.settle_deps = SettleDeps(
            redis=redis, sessionmaker=sessionmaker, settings=settings, integrations=integrations
        )
        self.engine = MatchEngine(
            redis=redis,
            settings=settings,
            node_id=self.node_id,
            clock=self.clock,
            settle=lambda mid: settle_match(self.settle_deps, mid),
        )
        self.runtime_config = RuntimeConfigCache()
        self.connections: dict[str, Connection] = {}
        self.draining = False
        self._stopped = False
        self._tasks: set[asyncio.Task[Any]] = set()
        # Imported here: the matchmaker and rematches use the node's other parts.
        from app.modules.realtime.matchmaking.service import Matchmaker
        from app.modules.realtime.rematch import Rematches

        self.matchmaker = Matchmaker(self)
        self.rematches = Rematches(self)

    async def start(self) -> None:
        await self.hub.start()
        await self.engine.start()
        self.matchmaker.start()
        log.info("rt.node_started", node_id=self.node_id)

    async def stop(self) -> None:
        self.draining = True
        self.rematches.stop()
        await self.matchmaker.stop()
        await self.engine.stop(release=True)
        self._stopped = True
        if self._tasks:
            _, pending = await asyncio.wait(self._tasks, timeout=3)
            for task in pending:
                task.cancel()
        await self.hub.stop()
        log.info("rt.node_stopped", node_id=self.node_id)

    def spawn(self, coroutine: Coroutine[Any, Any, Any]) -> None:
        if self._stopped:
            coroutine.close()
            return
        task = asyncio.create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # Connections

    def connection_value(self, conn: Connection) -> str:
        return f"{self.node_id}|{conn.conn_id}|{conn.session_id}"

    async def register(self, conn: Connection) -> None:
        """Make ``conn`` the user's one socket and tell older ones (anywhere) to close."""
        existing = self.connections.get(conn.uid)
        self.connections[conn.uid] = conn
        await self.redis.set(
            keys.connection(conn.uid),
            self.connection_value(conn),
            ex=int(self.settings.rt_stale_idle_s) + 30,
        )
        await self.hub.subscribe(keys.user_control(conn.uid), conn.on_control)
        await self.redis.publish(
            keys.user_control(conn.uid),
            orjson.dumps({"type": "supersede", "conn_id": conn.conn_id}),
        )
        if existing is not None and existing is not conn:
            existing.close_soon(protocol.CloseCode.SUPERSEDED, "playing on another device")
        await self.hub.subscribe(keys.user_events(conn.uid), conn.on_user_event)

    async def unregister(self, conn: Connection) -> bool:
        """Forget ``conn``; True if it was still the user's current socket."""
        if self.connections.get(conn.uid) is conn:
            del self.connections[conn.uid]
        await self.hub.unsubscribe(keys.user_events(conn.uid), conn.on_user_event)
        await self.hub.unsubscribe(keys.user_control(conn.uid), conn.on_control)
        for mid in list(conn.matches):
            await self.hub.unsubscribe(keys.match_events(mid), conn.on_match_event)
        conn.matches.clear()
        for tid in list(conn.tournaments):
            await self.hub.unsubscribe(keys.tournament_events(tid), conn.on_tournament_event)
        conn.tournaments.clear()
        released = bool(
            await _RELEASE_CONNECTION(
                self.redis, keys=[keys.connection(conn.uid)], args=[self.connection_value(conn)]
            )
        )
        if released:
            await self._presence(conn, None)
        return released

    @property
    def presence_ttl_s(self) -> int:
        """Presence outlives a heartbeat gap a little, like ``rt:conn``."""
        return int(self.settings.rt_stale_idle_s) + 30

    async def _presence(self, conn: Connection, state: str | None) -> None:
        """Social presence: ``online``, ``in_battle``, or cleared (best effort)."""
        try:
            await self.integrations.presence(self.redis, conn.user_id, state, self.presence_ttl_s)
        except RedisError:
            log.warning("rt.presence_failed", exc_info=True)

    @staticmethod
    def presence_state(conn: Connection) -> str:
        return "in_battle" if conn.state == "match" else "online"

    async def refresh_presence(self, conn: Connection) -> None:
        """Keep ``rt:conn`` and the social presence alive while the socket is (heartbeat)."""
        try:
            current = await rstr.get(self.redis, keys.connection(conn.uid))
            if current == self.connection_value(conn):
                await self.redis.expire(
                    keys.connection(conn.uid), int(self.settings.rt_stale_idle_s) + 30
                )
                await self._presence(conn, self.presence_state(conn))
        except RedisError:
            log.warning("rt.presence_failed", exc_info=True)

    async def busy(self, uid: str) -> str | None:
        return await rstr.get(self.redis, keys.busy(uid))

    async def refresh_state(self, conn: Connection, *, announce: bool = True) -> None:
        """Idle, queued or in a match: sets the heartbeat interval (announced with ``hb``,
        except before the welcome, which carries it)."""
        busy = await self.busy(conn.uid)
        state: State = "idle"
        if busy and busy.startswith("m:"):
            state = "match"
        elif busy and busy.startswith("q:"):
            state = "queue"
        if announce:
            conn.set_state(state)
        else:
            conn.state = state
        if not conn.closed:
            await self._presence(conn, self.presence_state(conn))

    async def active(self, uid: str) -> list[dict[str, Any]]:
        """``welcome.active``: what the user is in right now."""
        busy = await self.busy(uid)
        if busy is None:
            tournament = await self.active_tournament(uid)
            return [tournament] if tournament is not None else []
        kind, _, ident = busy.partition(":")
        if kind == "m":
            phase = await rstr.hget(self.redis, keys.match(ident), "phase")
            if phase is None or phase in scripts.TERMINAL_PHASES:
                return []
            return [{"kind": "match", "id": ident, "ch": f"m:{ident}", "state": phase}]
        if kind == "q":
            return [{"kind": "queue", "id": ident, "title": "Quick Battle"}]
        return []

    async def active_tournament(self, uid: str) -> dict[str, Any] | None:
        """A tournament that starts within 2 minutes or is running, from the busy registry."""
        async with self.sessionmaker() as db:
            found = await check_busy(db, self.redis, uuid.UUID(uid), self.clock.now_ms())
        if found is None:
            return None
        return {"kind": found.kind, "id": found.id, "title": found.title, "ch": f"t:{found.id}"}

    async def busy_details(self, busy: str) -> dict[str, Any]:
        """``details.active`` of a BUSY error."""
        kind, _, ident = busy.partition(":")
        if kind == "m":
            return {"kind": "match", "id": ident, "title": "Quick Battle"}
        if kind == "q":
            return {"kind": "queue", "id": ident, "title": "Quick Battle search"}
        if kind == "r":
            return {"kind": "room", "id": ident, "title": "Room"}
        return {"kind": "tournament", "id": ident, "title": "Tournament"}

    # Tournament channels

    async def follow_tournament(self, conn: Connection, tournament_id: uuid.UUID) -> bool:
        """``sub t:<id>``: the current ``t.standings`` now, then updates as they come."""
        async with self.sessionmaker() as db:
            snapshot = await self.integrations.standings(db, tournament_id)
        if snapshot is None or conn.closed:
            return False
        tid = str(tournament_id)
        if tid not in conn.tournaments:
            conn.tournaments.add(tid)
            await self.hub.subscribe(keys.tournament_events(tid), conn.on_tournament_event)
        rows = snapshot.get("rows", [])
        me = next((row for row in rows if row.get("uid") == conn.uid), None)
        conn.send(
            protocol.frame(
                "t.standings", {**snapshot, "me": me}, ch=f"t:{tid}", ts=self.clock.now_ms()
            )
        )
        return True

    async def unfollow_tournament(self, conn: Connection, tournament_id: str) -> None:
        if tournament_id in conn.tournaments:
            conn.tournaments.discard(tournament_id)
            await self.hub.unsubscribe(
                keys.tournament_events(tournament_id), conn.on_tournament_event
            )

    # Match channels

    async def is_player(self, mid: str, uid: str) -> bool:
        players = await rstr.hget(self.redis, keys.match(mid), "players")
        return players is not None and uid in orjson.loads(players)

    async def follow_match(self, conn: Connection, mid: str, *, last_seq: int | None) -> bool:
        """Start (or restart) forwarding ``m:<mid>`` to ``conn``: a replay from ``last_seq``
        when the log still reaches back that far, else a snapshot; then live events."""
        if conn.closed or not await self.is_player(mid, conn.uid):
            return False
        follow = conn.matches.get(mid)
        if follow is None:
            follow = conn.matches[mid] = MatchFollow()
            await self.hub.subscribe(keys.match_events(mid), conn.on_match_event)
            # The latency allowance measured so far on this socket applies to its answers.
            await scripts.set_latency(self.redis, mid, conn.uid, conn.lat_ms)
        else:
            follow.buffering = True
        try:
            if not await self._replay(conn, mid, follow, last_seq):
                frame = await views.snapshot(self.redis, mid, conn.uid, ts=self.clock.now_ms())
                if frame is None:
                    return False
                follow.last_seq = int(frame["seq"])
                conn.send(frame)
        finally:
            held, follow.held, follow.buffering = follow.held, [], False
            for envelope in sorted(held, key=lambda e: int(e.get("seq") or 0)):
                conn.forward(mid, follow, envelope)
        await self.refresh_state(conn)
        return True

    async def _replay(
        self, conn: Connection, mid: str, follow: MatchFollow, last_seq: int | None
    ) -> bool:
        if not last_seq or last_seq <= 0:
            return False
        current = int(await self.redis.hget(keys.match(mid), "seq") or 0)
        if last_seq > current:
            return False
        entries: list[tuple[str, dict[str, str]]] = await self.redis.xrange(  # type: ignore[assignment]
            keys.match_log(mid)
        )
        events = [orjson.loads(fields["ev"]) for _, fields in entries]
        missing = [event for event in events if int(event["seq"]) > last_seq]
        expected = list(range(last_seq + 1, current + 1))
        if [int(event["seq"]) for event in missing] != expected:
            return False  # the capped log no longer reaches back that far
        follow.last_seq = last_seq
        for event in missing:
            conn.forward(mid, follow, event)
        follow.last_seq = current
        return True

    async def match_connected(self, conn: Connection, mid: str) -> None:
        step = await scripts.connection(self.redis, mid, conn.uid, connected=True)
        self.engine.report(mid, ver=step.ver, due=step.due)

    async def match_dropped(self, uid: str, mid: str, *, restart: bool) -> None:
        extra = self.settings.match_drain_grace_ms if restart else 0
        step = await scripts.connection(self.redis, mid, uid, connected=False, extra_ms=extra)
        self.engine.report(mid, ver=step.ver, due=step.due)
