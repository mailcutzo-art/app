"""Rooms on an rt node: the ``room.*`` messages, the ``r:<rid>`` channel and room timers
(``docs/protocol.md`` section 8).

- **Joining** (by code or room id): the code guess limit, then Postgres (blocks, friends only,
  tournaments that need the player), then ``room_join.lua`` (kicks, lock, capacity, the busy
  slot). The host hears about it (inbox, push, live). While a group battle runs, a joiner comes
  in late until halfway (scoring 0 for what they missed), and watches after that; a player who
  left comes back in.
- **Host controls**: settings (between games), start (at least 2 connected players; the game
  is an engine match of kind ``friend`` or ``group`` with the room's settings), kick (at most
  5 a minute; the player can't come back), lock, transfer and end (a running group game ends
  with ``ended_by_host``; a friend duel counts as the host leaving).
- **Presence**: sockets coming and going (``conn``) and the app going to the background
  (``away``) are shown in ``room.state``; a group host disconnected for 20 s hands over.
- **Timers**: ``rooms:timers`` is scanned by every node; ``room_tick.lua`` is idempotent, so
  whoever runs it first acts (a game ended, a friend duel's auto-start, a rematch window, the
  idle close, a host handover).
- **Channel**: ``r:<rid>`` is resumable like a match channel (log replay or a ``room.state``
  snapshot). ``room.kicked`` goes to the kicked player alone.
"""

import asyncio
import math
import uuid
from datetime import timedelta
from typing import TYPE_CHECKING, Any

import orjson
import structlog
from pydantic import ValidationError

from app.core.clock import utc_now
from app.core.errors import RateLimited, ServiceUnavailable
from app.core.ids import new_id
from app.core.ratelimit import consume
from app.modules.matches.creation import Contender, MatchUnavailable, prepare_match
from app.modules.matches.models import MatchKind
from app.modules.realtime import keys, protocol, rstr
from app.modules.realtime.connection import MatchFollow
from app.modules.realtime.engine import scripts
from app.modules.realtime.loops import every, stop_all
from app.modules.realtime.protocol import ErrorCode
from app.modules.rooms import live, service
from app.modules.rooms.busy import busy_elsewhere
from app.modules.rooms.models import RoomKind
from app.modules.rooms.schemas import RoomSettingsIn
from app.modules.rooms.service import Busy, RoomNotFound, SettingsInvalid

if TYPE_CHECKING:
    from app.modules.realtime.connection import Connection
    from app.modules.realtime.node import RtNode

log = structlog.stdlib.get_logger(__name__)

KICKS_PER_MINUTE = 5
TIMER_BATCH = 200

# Room script statuses that refuse a request: (error code, message).
_REFUSALS: dict[str, tuple[str, str]] = {
    "not_found": (ErrorCode.NOT_FOUND, "This room isn't open any more."),
    "not_member": (ErrorCode.NOT_FOUND, "You're not in this room."),
    "not_host": (ErrorCode.NOT_ALLOWED, "Only the host can do that."),
    "wrong_status": (ErrorCode.NOT_ALLOWED, "That can't be done right now."),
    "bad_target": (ErrorCode.BAD_REQUEST, "Pick a player in this room."),
    "expired": (ErrorCode.NOT_ALLOWED, "The rematch window has closed."),
    "stale": (ErrorCode.UNAVAILABLE, "Please try again."),
    "kicked": (ErrorCode.NOT_ALLOWED, "You can't join this room."),
    "locked": (ErrorCode.NOT_ALLOWED, "The host locked this room."),
    "full": (ErrorCode.NOT_ALLOWED, "This room is full."),
    "starting": (ErrorCode.UNAVAILABLE, "The game is starting. Try again in a moment."),
    "too_few": (ErrorCode.NOT_ALLOWED, "At least 2 connected players are needed."),
}


class Refused(Exception):
    """A request the room says no to: the error sent back."""

    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


def _refused(status: str, **details: Any) -> Refused:
    code, message = _REFUSALS.get(status, (ErrorCode.UNAVAILABLE, "Please try again."))
    if status in {"kicked", "locked", "full"}:
        details.setdefault("reason", status)
    return Refused(code, message, details)


def _room_id(d: dict[str, Any]) -> str:
    rid = d.get("room_id")
    try:
        return str(uuid.UUID(rid)) if isinstance(rid, str) else ""
    except ValueError:
        return ""


class RoomHub:
    def __init__(self, node: "RtNode") -> None:
        self.node = node
        self.redis = node.redis
        self.settings = node.settings
        self._loop: asyncio.Task[None] | None = None
        self._stop = asyncio.Event()

    def start(self) -> None:
        self._stop = asyncio.Event()
        self._loop = asyncio.create_task(
            every(self.settings.rt_scan_interval_s, self._stop, self.scan, name="rooms"),
            name="rt:rooms",
        )

    async def stop(self) -> None:
        await stop_all(self._stop, [self._loop] if self._loop else [])

    # Presence

    async def room_of(self, busy: str | None) -> str | None:
        """The room behind a busy slot: the room itself, or the room of a room game."""
        if busy is None:
            return None
        kind, _, ident = busy.partition(":")
        if kind == "r":
            return ident
        if kind == "m":
            return await rstr.hget(self.redis, keys.match(ident), "room") or None
        return None

    async def connected(self, uid: str, rid: str, *, connected: bool) -> None:
        await live.op(self.redis, rid, "conn", uid, {"connected": connected})

    async def away(self, uid: str, rid: str, *, away: bool) -> None:
        await live.op(self.redis, rid, "away", uid, {"away": away})

    # The r:<rid> channel

    async def follow(self, conn: "Connection", rid: str, *, last_seq: int | None) -> bool:
        """Forward ``r:<rid>`` to a member: a replay from ``last_seq`` or a snapshot, then
        live events."""
        if conn.closed or not await self.redis.hexists(keys.room_members(rid), conn.uid):
            return False
        follow = conn.rooms.get(rid)
        if follow is None:
            follow = conn.rooms[rid] = MatchFollow()
            await self.node.hub.subscribe(keys.room_events(rid), conn.on_room_event)
        else:
            follow.buffering = True
        sent = True
        try:
            if not await self._replay(conn, rid, follow, last_seq):
                frame = await live.snapshot(self.redis, rid, ts=self.node.clock.now_ms())
                if frame is None:
                    sent = False
                else:
                    follow.last_seq = int(frame["seq"])
                    conn.send(frame)
        finally:
            held, follow.held, follow.buffering = follow.held, [], False
            for envelope in sorted(held, key=lambda e: int(e.get("seq") or 0)):
                conn.forward_room(rid, follow, envelope)
        if not sent:
            await self.unfollow(conn, rid)
            return False
        await self.node.refresh_state(conn)
        return True

    async def _replay(
        self, conn: "Connection", rid: str, follow: MatchFollow, last_seq: int | None
    ) -> bool:
        if not last_seq or last_seq <= 0:
            return False
        current = int(await self.redis.hget(keys.room(rid), "seq") or 0)
        if last_seq > current:
            return False
        entries: list[tuple[str, dict[str, str]]] = await self.redis.xrange(  # type: ignore[assignment]
            keys.room_log(rid)
        )
        events = [orjson.loads(fields["ev"]) for _, fields in entries]
        missing = [event for event in events if int(event["seq"]) > last_seq]
        if [int(event["seq"]) for event in missing] != list(range(last_seq + 1, current + 1)):
            return False
        follow.last_seq = last_seq
        for event in missing:
            conn.forward_room(rid, follow, event)
        return True

    async def unfollow(self, conn: "Connection", rid: str) -> None:
        if conn.rooms.pop(rid, None) is not None:
            await self.node.hub.unsubscribe(keys.room_events(rid), conn.on_room_event)
        await self.node.refresh_state(conn)

    async def game_started(self, conn: "Connection", rid: str, mid: str) -> None:
        """``room.started`` reached a member: players and spectators follow the game."""
        if await self.node.can_view(mid, conn.uid):
            await self.node.follow_match(conn, mid, last_seq=None)

    # Messages

    async def handle(
        self, conn: "Connection", ref: str | None, event_type: str, d: dict[str, Any]
    ) -> None:
        handler = {
            "room.join": self._join,
            "room.leave": self._leave,
            "room.ready": self._ready,
            "room.settings": self._settings,
            "room.start": self._start,
            "room.kick": self._kick,
            "room.lock": self._lock,
            "room.transfer": self._transfer,
            "room.end": self._end,
            "room.rematch": self._rematch,
        }[event_type]
        try:
            rid = await handler(conn, ref, d)
        except Refused as exc:
            conn.error(ref, exc.code, exc.message, details=exc.details)
            return
        conn.reply(ref, "ack", {"room_id": rid}, ch=live.room_channel(rid))

    async def _member(self, conn: "Connection", d: dict[str, Any]) -> str:
        rid = _room_id(d)
        if not rid:
            raise Refused(ErrorCode.BAD_REQUEST, "room_id is missing.")
        if not await self.redis.hexists(keys.room_members(rid), conn.uid):
            raise _refused("not_member")
        return rid

    async def _op(
        self,
        rid: str,
        name: str,
        uid: str,
        arg: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> live.Outcome:
        outcome = await live.op(self.redis, rid, name, uid, arg, **kwargs)
        if outcome.status in _REFUSALS:
            raise _refused(outcome.status)
        return outcome

    async def _join(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        code = d.get("code")
        try:
            if isinstance(code, str):
                rid = await service.room_by_code(self.redis, conn.user_id, code)
            else:
                rid = _room_id(d)
                if not rid:
                    raise Refused(ErrorCode.BAD_REQUEST, "room.join needs a code or room_id.")
        except RoomNotFound as exc:
            raise Refused(ErrorCode.NOT_FOUND, exc.message) from exc
        except RateLimited as exc:
            raise Refused(
                ErrorCode.RATE_LIMITED,
                exc.message,
                {"retry_after_s": exc.retry_after or 1},
            ) from exc
        current = await live.read(self.redis, rid)
        if current is None or current["status"] == "closed":
            raise Refused(ErrorCode.NOT_FOUND, RoomNotFound.default_message)
        state = current["state"]
        uid = conn.uid
        member = any(m["uid"] == uid for m in state["members"])
        mode = "player"
        card: dict[str, Any] = {}
        now = utc_now()
        if not member:
            longest = service.longest_game_ms(self.settings, state["kind"], state["settings"])
            async with self.node.sessionmaker() as db:
                refusal = await service.join_refusal(db, state, conn.user_id)
                if refusal is not None:
                    raise Refused(
                        ErrorCode.NOT_ALLOWED,
                        "You can't join this room.",
                        {"reason": refusal},
                    )
                active = await busy_elsewhere(
                    db,
                    self.redis,
                    conn.user_id,
                    until=now + timedelta(milliseconds=longest),
                    allow=f"r:{rid}",
                )
                card = await service.socket_card(db, conn.user_id)
            if active is not None:
                raise Refused(
                    ErrorCode.BUSY,
                    "You're already in a game.",
                    {"active": active.model_dump(mode="json")},
                )
            if current["status"] in {"playing", "starting"}:
                late = await service.late_join_mode(self.redis, state)
                if late is None:
                    raise Refused(
                        ErrorCode.NOT_ALLOWED, "The game has started.", {"reason": "started"}
                    )
                mode = late
        outcome = await live.join(self.redis, rid, uid, card, spectator=mode == "spectator")
        if outcome.status == "busy":
            active_out = await self.node.busy_details(outcome.detail)
            raise Refused(ErrorCode.BUSY, "You're already in a game.", {"active": active_out})
        if outcome.status not in {"joined", "member"}:
            raise _refused(outcome.status)
        if outcome.status == "joined":
            async with self.node.sessionmaker() as db:
                await service.record_join(db, rid, conn.user_id, now)
                if uid != state["host"]:
                    await service.notify_host_joined(db, state, card)
                await db.commit()
            log.info("room.joined", room_id=rid, user_id=uid, mode=mode)
        await self.follow(conn, rid, last_seq=None)
        await self._into_game(conn, rid, spectator=outcome.detail == "spectator", card=card)
        return rid

    async def _into_game(
        self, conn: "Connection", rid: str, *, spectator: bool, card: dict[str, Any]
    ) -> None:
        """A member joining while the room's game runs: back in (after a drop, or after leaving
        a group battle), in late, or watching."""
        status, mid, kind = await rstr.hmget(
            self.redis, keys.room(rid), ["status", "match", "kind"]
        )
        if status != "playing" or not mid:
            return
        if await self.node.is_player(mid, conn.uid):
            if kind == RoomKind.GROUP:
                step = await scripts.join(
                    self.redis, mid, conn.uid, card, spectator=False, busy_ttl_s=service.ROOM_TTL_S
                )
                self.node.engine.report(mid, ver=step.ver, due=step.due)
            else:
                await self.node.match_connected(conn, mid)
        elif kind == RoomKind.GROUP:
            if not card:
                async with self.node.sessionmaker() as db:
                    card = await service.socket_card(db, conn.user_id)
            step = await scripts.join(
                self.redis, mid, conn.uid, card, spectator=spectator, busy_ttl_s=service.ROOM_TTL_S
            )
            if step.status in {"joined", "rejoined"}:
                self.node.engine.report(mid, ver=step.ver, due=step.due)
        await self.node.follow_match(conn, mid, last_seq=None)

    async def _leave(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        mid = await rstr.hget(self.redis, keys.room(rid), "match")
        async with self.node.sessionmaker() as db:
            _, step = await service.leave_room(db, self.redis, rid, conn.user_id, now=utc_now())
            await db.commit()
        if step is not None and mid:
            self.node.engine.report(mid, ver=step.ver, due=step.due, ended=step.ended)
        if mid and mid in conn.matches:
            conn.matches.pop(mid)
            await self.node.hub.unsubscribe(keys.match_events(mid), conn.on_match_event)
        await self.unfollow(conn, rid)
        return rid

    async def _ready(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        await self._op(rid, "ready", conn.uid, {"ready": d.get("ready") is not False})
        return rid

    async def _settings(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        kind = await rstr.hget(self.redis, keys.room(rid), "kind")
        try:
            raw = RoomSettingsIn.model_validate(d.get("settings"))
        except ValidationError as exc:
            raise Refused(ErrorCode.BAD_REQUEST, "Those settings aren't valid.") from exc
        async with self.node.sessionmaker() as db:
            try:
                room_settings = await service.resolve_settings(db, RoomKind(kind or "friend"), raw)
            except SettingsInvalid as exc:
                raise Refused(ErrorCode.BAD_REQUEST, exc.message, exc.details) from exc
            await self._op(rid, "settings", conn.uid, settings=room_settings)
            await service.record_settings(db, rid, room_settings)
            await db.commit()
        return rid

    async def _start(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        await self.start_game(rid, conn.uid)
        return rid

    async def start_game(self, rid: str, uid: str) -> str:
        """Start a game of the room (``uid`` is the host, or '' for an automatic start or an
        agreed rematch). Returns the match id; raises ``Refused``."""
        now = utc_now()
        async with self.node.sessionmaker() as db:
            try:
                await service.ensure_open(db, self.settings, now)
            except ServiceUnavailable as exc:
                raise Refused(ErrorCode.UNAVAILABLE, exc.message) from exc
        mid = new_id()
        status, players = await live.claim_start(self.redis, rid, uid, str(mid))
        if status != "ok":
            raise _refused(status)
        try:
            current = await live.read(self.redis, rid)
            if current is None:
                raise Refused(ErrorCode.NOT_FOUND, "This room isn't open any more.")
            state = current["state"]
            kind, room_settings = state["kind"], state["settings"]
            longest = service.longest_game_ms(self.settings, kind, room_settings)
            async with self.node.sessionmaker() as db:
                # A tournament that needs one of the players before this game could end wins.
                for player in players:
                    active = await busy_elsewhere(
                        db,
                        self.redis,
                        uuid.UUID(player),
                        until=now + timedelta(milliseconds=longest),
                        allow=f"r:{rid}",
                    )
                    if active is not None:
                        raise Refused(
                            ErrorCode.BUSY,
                            "A player is needed elsewhere soon.",
                            {"active": active.model_dump(mode="json"), "uid": player},
                        )
                prepared = await prepare_match(
                    db,
                    self.settings,
                    match_id=mid,
                    kind=MatchKind(kind),
                    subject_slug=room_settings["subject"],
                    contenders=[
                        Contender(user_id=uuid.UUID(player), chapter=None, joined_ms=index)
                        for index, player in enumerate(players)
                    ],
                    rules_in=service.game_rules(self.settings, rid, kind, room_settings),
                )
                await service.record_game(db, rid)
                await db.commit()
            await self.node.engine.start_match(
                str(mid), prepared.config, prepared.questions, ttl_s=prepared.ttl_s
            )
        except Refused:
            await live.op(self.redis, rid, "unstart", "")
            raise
        except MatchUnavailable as exc:
            await live.op(self.redis, rid, "unstart", "")
            raise Refused(ErrorCode.UNAVAILABLE, "There are no questions for this.") from exc
        except Exception:
            log.exception("room.start_failed", room_id=rid)
            await live.op(self.redis, rid, "unstart", "")
            raise Refused(ErrorCode.UNAVAILABLE, "The game couldn't start.") from None
        await live.op(self.redis, rid, "started", "", {"match_id": str(mid)})
        log.info("room.game_started", room_id=rid, match_id=str(mid), players=len(players))
        return str(mid)

    async def _kick(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        target = d.get("uid")
        if await rstr.hget(self.redis, keys.room(rid), "host") != conn.uid:
            raise _refused("not_host")
        if not isinstance(target, str) or target == conn.uid:
            raise _refused("bad_target")
        try:
            target_id = uuid.UUID(target)
        except ValueError as exc:
            raise _refused("bad_target") from exc
        limit = await consume(
            self.redis,
            f"rl:room.kick:user:{conn.uid}",
            capacity=KICKS_PER_MINUTE,
            refill_per_sec=KICKS_PER_MINUTE / 60,
        )
        if not limit.allowed:
            raise Refused(
                ErrorCode.RATE_LIMITED,
                "That's a lot of kicks. Wait a moment.",
                {"retry_after_s": math.ceil(limit.retry_after_ms / 1000)},
            )
        mid = await rstr.hget(self.redis, keys.room(rid), "match")
        async with self.node.sessionmaker() as db:
            outcome, step = await service.leave_room(
                db, self.redis, rid, target_id, now=utc_now(), kicked_by=conn.user_id
            )
            await db.commit()
        if outcome.status == "not_member":
            raise _refused("bad_target")
        if step is not None and mid:
            self.node.engine.report(mid, ver=step.ver, due=step.due, ended=step.ended)
        await protocol.publish_to_user(
            self.redis,
            target,
            "room.kicked",
            {"room_id": rid},
            ts=self.node.clock.now_ms(),
            ch=live.room_channel(rid),
        )
        return rid

    async def _lock(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        await self._op(rid, "lock", conn.uid, {"locked": d.get("locked") is not False})
        return rid

    async def _transfer(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        await self._op(rid, "transfer", conn.uid, {"uid": d.get("uid")})
        return rid

    async def _end(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        host, status, mid, kind = await rstr.hmget(
            self.redis, keys.room(rid), ["host", "status", "match", "kind"]
        )
        if host != conn.uid:
            raise _refused("not_host")
        if status == "playing" and mid:
            if kind == RoomKind.GROUP:
                step = await scripts.end(self.redis, mid, by_host=True)
            else:
                step = await scripts.forfeit(self.redis, mid, conn.uid)
            self.node.engine.report(mid, ver=step.ver, due=step.due, ended=step.ended)
        await self._op(rid, "end", conn.uid)
        async with self.node.sessionmaker() as db:
            await service.record_close(db, self.redis, rid, "host_ended", utc_now())
            await db.commit()
        return rid

    async def _rematch(self, conn: "Connection", ref: str | None, d: dict[str, Any]) -> str:
        rid = await self._member(conn, d)
        outcome = await self._op(rid, "rematch", conn.uid, {"accept": d.get("accept") is not False})
        if outcome.status == "start":
            await self.start_game(rid, "")
        return rid

    # From matchmaking: "Invite a friend" after a long search

    async def create_friend_room(
        self, conn: "Connection", subject: str, chapter: str | None
    ) -> dict[str, Any]:
        """A friend lobby with the searcher as host; raises ``Refused``."""
        try:
            async with self.node.sessionmaker() as db:
                created = await service.create_room(
                    db,
                    self.redis,
                    self.settings,
                    conn.user_id,
                    RoomKind.FRIEND,
                    RoomSettingsIn(subject=subject, chapter=chapter),
                    now=utc_now(),
                )
                await db.commit()
        except Busy as exc:
            raise Refused(ErrorCode.BUSY, exc.message, exc.details) from exc
        except SettingsInvalid:
            async with self.node.sessionmaker() as db:
                created = await service.create_room(
                    db,
                    self.redis,
                    self.settings,
                    conn.user_id,
                    RoomKind.FRIEND,
                    RoomSettingsIn(subject=subject),
                    now=utc_now(),
                )
                await db.commit()
        rid = str(created.room_id)
        await self.connected(conn.uid, rid, connected=True)
        await self.follow(conn, rid, last_seq=None)
        return created.model_dump(mode="json")

    # Timers

    async def scan(self) -> None:
        """Run the timers of rooms that are due."""
        now = self.node.clock.now_ms()
        due = await self.redis.zrangebyscore(
            keys.ROOM_TIMERS, "-inf", now, start=0, num=TIMER_BATCH
        )
        for raw in due:
            rid = rstr.as_str(raw)
            outcome = await live.tick(self.redis, rid)
            if outcome.status == "autostart":
                self.node.spawn(self._autostart(rid))
            elif outcome.status == "closed":
                async with self.node.sessionmaker() as db:
                    await service.record_close(db, self.redis, rid, outcome.detail, utc_now())
                    await db.commit()

    async def _autostart(self, rid: str) -> None:
        try:
            await self.start_game(rid, "")
        except Refused as exc:
            log.info("room.autostart_skipped", room_id=rid, reason=exc.message)
