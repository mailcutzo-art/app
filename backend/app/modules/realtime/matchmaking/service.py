"""Quick Battle matchmaking: ``mm.join``, ``mm.cancel``, ``mm.respond`` and the queue leaders.

**Joining** runs on the player's node: rate limit (10 a minute), cooldown, the busy slot, the
subject and chapter, then for casual play a coin hold through the ``EscrowPort``, then
``mm_join.lua``. A Practice Bot game (``mode: bot``) starts at once instead.

**Queue leaders.** One node per queue (``mm:lead:{mode}:{subject}``) ticks every 500 ms:
drops tickets past their deadline (105 s, or 60 s after "keep searching"), offline or in the
background for more than 10 s; pairs the oldest tickets first with the pure rules in
``rules.py`` plus the guards (never blocked pairs, never one device, at most 3 rated games a
pair a day, and players in the moderation shadow pool only with each other); creates the
match (Postgres rows first, then ``create.lua``; ``mm_unpair.lua`` if that fails); and sends
``mm.status`` when a search widens and ``mm.timeout`` at 45 s (20 s on a first-ever search).
"""

import asyncio
import math
import statistics
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

import orjson
import structlog
from sqlalchemy import exists, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.ids import new_id
from app.core.ratelimit import consume
from app.modules.content.catalog import MIN_BATTLE_QUESTIONS
from app.modules.content.models import Chapter, Question, Subject
from app.modules.matches.busy import check_busy
from app.modules.matches.creation import (
    Contender,
    MatchUnavailable,
    max_duration_ms,
    prepare_match,
)
from app.modules.matches.models import Match, MatchKind, MatchParticipant
from app.modules.matches.ports import (
    InsufficientCoins,
    never_blocked,
    never_shadowed,
    no_tracking,
)
from app.modules.matches.questions import battle_pool
from app.modules.ratings.service import load_ratings, to_glicko
from app.modules.realtime import keys, protocol, rstr
from app.modules.realtime.engine import scripts
from app.modules.realtime.loops import every, stop_all
from app.modules.realtime.matchmaking import rules, tickets
from app.modules.realtime.protocol import ErrorCode
from app.modules.system.runtime import RuntimeConfig

if TYPE_CHECKING:
    from app.modules.realtime.connection import Connection
    from app.modules.realtime.node import RtNode

log = structlog.stdlib.get_logger(__name__)

MODES = ("rated", "casual", "bot")
QUEUED_MODES = ("rated", "casual")
KIND_OF_MODE = {"rated": MatchKind.QUICK_RATED, "casual": MatchKind.QUICK_CASUAL}
IDEM_TTL_S = 600
FOUND_TTL_S = 600
WAIT_SAMPLES = 200
WAIT_TTL_S = 8 * 86_400
SEARCHED_TTL_S = 400 * 86_400
PAIR_WINDOW_MS = 24 * 3600 * 1000
# New searches stop this long before planned maintenance.
MAINTENANCE_LEAD_S = 600


@dataclass(frozen=True, slots=True)
class QueuedTicket:
    ticket_id: str
    fields: dict[str, str]

    @property
    def uid(self) -> str:
        return self.fields["uid"]

    @property
    def joined_ms(self) -> int:
        return int(self.fields["joined_ms"])

    @property
    def chapter(self) -> str | None:
        chapter = self.fields.get("chapter", tickets.ALL_CHAPTERS)
        return None if chapter == tickets.ALL_CHAPTERS else chapter

    def rules_ticket(self) -> rules.Ticket:
        return rules.Ticket(
            user_id=self.uid,
            rating=float(self.fields["rating"]),
            rd=float(self.fields["rd"]),
            subject=self.fields["subject"],
            chapter=self.chapter,
            joined_ms=self.joined_ms,
            device_hash=self.fields.get("device", ""),
        )

    def contender(self) -> Contender:
        return Contender(
            user_id=uuid.UUID(self.uid),
            chapter=self.chapter,
            joined_ms=self.joined_ms,
            ticket_id=self.ticket_id,
            ticket=self.fields,
            hold_id=self.fields.get("hold_id") or None,
        )


def searches_closed(config: RuntimeConfig, now: datetime) -> bool:
    """Maintenance, or planned maintenance starting within 10 minutes."""
    if config.maintenance:
        return True
    start = config.maintenance_at
    return start is not None and 0 <= (start - now).total_seconds() <= MAINTENANCE_LEAD_S


async def first_search(db: AsyncSession, redis: Any, uid: str) -> bool:
    """Never searched and never played a quick or bot game."""
    if await redis.exists(f"mm:searched:{uid}"):
        return False
    played = await db.scalar(
        select(
            exists().where(
                MatchParticipant.user_id == uuid.UUID(uid),
                MatchParticipant.match_id == Match.id,
                Match.kind.in_(["quick_rated", "quick_casual", "bot"]),
            )
        )
    )
    return not played


async def battle_ready(db: AsyncSession, subject_id: int, chapter_id: int) -> bool:
    """A chapter hosts battles once it has enough battle questions for one."""
    count = await db.scalar(
        select(func.count())
        .select_from(Question)
        .where(*battle_pool(subject_id, []), Question.chapter_id == chapter_id)
    )
    return int(count or 0) >= MIN_BATTLE_QUESTIONS


async def online_stats(redis: Any, subject: str, now_ms: int) -> tuple[int, int | None]:
    """(players searching in the subject now, the median wait at this IST hour)."""
    async with redis.pipeline(transaction=False) as pipe:
        for mode in QUEUED_MODES:
            pipe.zcard(keys.queue(mode, subject))
        pipe.lrange(keys.waits(subject, _hour(now_ms)), 0, -1)
        *counts, waits = await pipe.execute()
    p50 = round(statistics.median(int(w) for w in waits)) if waits else None
    return sum(int(c) for c in counts), p50


def _hour(now_ms: int) -> int:
    return datetime.fromtimestamp(now_ms / 1000, UTC).astimezone(IST).hour


class Matchmaker:
    def __init__(self, node: "RtNode") -> None:
        self.node = node
        self.redis = node.redis
        self.settings = node.settings
        self._leader: asyncio.Task[None] | None = None
        self._stop = asyncio.Event()

    def start(self) -> None:
        self._stop = asyncio.Event()
        self._leader = asyncio.create_task(
            every(self.settings.mm_tick_s, self._stop, self._lead, name="matchmaking"),
            name="rt:matchmaking",
        )

    async def stop(self) -> None:
        await stop_all(self._stop, [self._leader] if self._leader else [])

    # mm.join

    async def join(self, conn: "Connection", ref: str | None, d: Mapping[str, Any]) -> None:
        mode, subject, chapter = d.get("mode"), d.get("subject"), d.get("chapter")
        idem = d.get("idem")
        if (
            mode not in MODES
            or not isinstance(subject, str)
            or not (chapter is None or isinstance(chapter, str))
            or not isinstance(idem, str)
            or not 1 <= len(idem) <= 64
        ):
            conn.error(ref, ErrorCode.BAD_REQUEST, "mm.join needs mode, subject, chapter and idem.")
            return
        busy = await self.node.busy(conn.uid)
        if busy is not None and await rstr.get(self.redis, keys.join_idem(conn.uid, idem)) == busy:
            await self._repeat(conn, busy)  # a retry of this very join
            return
        async with self.node.sessionmaker() as db:
            config = await self.node.runtime_config.get(db, self.settings)
        if searches_closed(config, datetime.now(UTC)):
            conn.error(ref, ErrorCode.UNAVAILABLE, "Battles are paused for maintenance.")
            return
        limit = await consume(
            self.redis, f"rl:mm.join:user:{conn.uid}", capacity=10, refill_per_sec=10 / 60
        )
        if not limit.allowed:
            conn.error(
                ref,
                ErrorCode.RATE_LIMITED,
                "Too many searches. Try again in a moment.",
                details={"retry_after_s": math.ceil(limit.retry_after_ms / 1000)},
                retryable=True,
            )
            return
        if busy is not None:
            conn.error(
                ref,
                ErrorCode.BUSY,
                "You're already in a game.",
                details={"active": await self.node.busy_details(busy)},
            )
            return
        # A tournament that needs the player before this game could possibly end has priority.
        longest = max_duration_ms(self.settings, self.settings.match_questions)
        if mode != "bot":
            longest += round(self.settings.mm_max_wait_s * 1000)
        async with self.node.sessionmaker() as db:
            taken = await check_busy(
                db, self.redis, conn.user_id, self.node.clock.now_ms() + longest
            )
        if taken is not None:
            conn.error(
                ref,
                ErrorCode.BUSY,
                "Your tournament starts soon.",
                details={"active": taken.model_dump(mode="json")},
            )
            return
        if mode != "bot":
            until = await tickets.cooldown_until(self.redis, conn.uid)
            if until is not None:
                conn.error(
                    ref,
                    ErrorCode.COOLDOWN,
                    "Too many cancelled matches. Try again in a few minutes.",
                    details={"until": until},
                )
                return
        async with self.node.sessionmaker() as db:
            if not await self._available(db, subject, chapter):
                conn.error(ref, ErrorCode.NOT_FOUND, "This subject or chapter isn't available.")
                return
            first = await first_search(db, self.redis, conn.uid)
        if mode == "bot":
            mid = await self.start_bot(conn.uid, subject, chapter)
            if mid is None:
                conn.error(ref, ErrorCode.UNAVAILABLE, "The Practice Bot couldn't start.")
            else:
                await self.redis.set(keys.join_idem(conn.uid, idem), f"m:{mid}", ex=IDEM_TTL_S)
            return
        await self.redis.set(
            keys.last_selection(conn.uid),
            orjson.dumps({"subject": subject, "chapter": chapter, "mode": mode}),
            ex=SEARCHED_TTL_S,
        )
        await self._queue(conn, ref, mode, subject, chapter, idem, first=first)

    async def _available(self, db: AsyncSession, subject: str, chapter: str | None) -> bool:
        row = await db.scalar(select(Subject).where(Subject.slug == subject))
        if row is None:
            return False
        if chapter is None:
            return True
        chapter_id = await db.scalar(
            select(Chapter.id).where(
                Chapter.subject_id == row.id, Chapter.slug == chapter, Chapter.is_active
            )
        )
        return chapter_id is not None and await battle_ready(db, row.id, chapter_id)

    async def _queue(
        self,
        conn: "Connection",
        ref: str | None,
        mode: str,
        subject: str,
        chapter: str | None,
        idem: str,
        *,
        first: bool,
    ) -> None:
        ticket_id = tickets.new_ticket_id()
        hold_id = ""
        async with self.node.sessionmaker() as db:
            rating = (await load_ratings(db, [conn.user_id], subject)).get(conn.user_id)
            shadow = await self._shadowed(db, conn.user_id)
            if mode == "casual":
                try:
                    hold_id = await self.node.integrations.escrow.hold(
                        db,
                        user_id=conn.user_id,
                        amount=self.settings.casual_fee,
                        key=f"mm:{ticket_id}",
                    )
                except InsufficientCoins as exc:
                    conn.error(
                        ref,
                        ErrorCode.INSUFFICIENT_COINS,
                        "You need 5 coins to play Casual.",
                        details={"balance": exc.balance, "needed": self.settings.casual_fee},
                    )
                    return
                await db.commit()
        glicko = to_glicko(rating)
        window = self._window(0, mode, glicko.rd)
        fields = {
            "uid": conn.uid,
            "mode": mode,
            "subject": subject,
            "chapter": chapter or tickets.ALL_CHAPTERS,
            "rating": glicko.rating,
            "rd": glicko.rd,
            "device": conn.device,
            "hold_id": hold_id,
            "first": "1" if first else "0",
            "shadow": "1" if shadow else "0",
            # The status sent below; the leader only sends changes from here on.
            "last_status": f"0:{window}",
        }
        ok, value = await tickets.queue_ticket(self.redis, self.settings, ticket_id, fields)
        if not ok:
            await self._release(hold_id, key=f"mm:{ticket_id}:refund")
            conn.error(
                ref,
                ErrorCode.BUSY,
                "You're already in a game.",
                details={"active": await self.node.busy_details(value)},
            )
            return
        await self.redis.set(keys.join_idem(conn.uid, idem), f"q:{ticket_id}", ex=IDEM_TTL_S)
        await self.redis.set(f"mm:searched:{conn.uid}", 1, ex=SEARCHED_TTL_S)
        conn.send(
            protocol.frame(
                "mm.queued",
                {
                    "ticket_id": ticket_id,
                    "mode": mode,
                    "subject": subject,
                    "chapter": chapter,
                    "joined_at": int(value),
                },
                ts=self.node.clock.now_ms(),
            )
        )
        online, p50 = await online_stats(self.redis, subject, self.node.clock.now_ms())
        conn.reply(
            None,
            "mm.status",
            {
                "waited_s": 0,
                "widened": False,
                "window": window,
                "online": online,
                "p50_wait_s": p50,
            },
        )
        await self.node.refresh_state(conn)
        await self._track(
            "mm_join",
            conn.uid,
            {"mode": mode, "subject": subject, "chapter": chapter is not None, "online": online},
        )
        log.info("mm.queued", user_id=conn.uid, mode=mode, subject=subject, chapter=chapter)

    @staticmethod
    def _window(waited_s: float, mode: str, rd: Any) -> int | None:
        window = rules.rating_window(waited_s, rated=mode == "rated", rd=float(rd))
        return None if window is None else round(window)

    async def _repeat(self, conn: "Connection", busy: str) -> None:
        """Answer a repeated ``mm.join`` with the state its first send created."""
        kind, _, ident = busy.partition(":")
        if kind == "q":
            fields = await rstr.hgetall(self.redis, keys.ticket(ident))
            if fields:
                chapter = fields.get("chapter")
                conn.reply(
                    None,
                    "mm.queued",
                    {
                        "ticket_id": ident,
                        "mode": fields["mode"],
                        "subject": fields["subject"],
                        "chapter": None if chapter == tickets.ALL_CHAPTERS else chapter,
                        "joined_at": int(fields["joined_ms"]),
                    },
                )
                return
        found = await rstr.get(self.redis, f"mm:found:{conn.uid}")
        if found is not None:
            conn.reply(None, "mm.found", orjson.loads(found))

    async def _shadowed(self, db: AsyncSession, user_id: uuid.UUID) -> bool:
        check = self.node.integrations.shadow_pool
        return False if check is never_shadowed else await check(db, user_id)

    async def _track(self, name: str, uid: str, props: Mapping[str, Any]) -> None:
        """An analytics funnel event (best effort: a failure never stops the game)."""
        tracker = self.node.integrations.track
        if tracker is no_tracking:
            return
        try:
            async with self.node.sessionmaker() as db:
                await tracker(db, name, uuid.UUID(uid), props)
                await db.commit()
        except Exception:
            log.warning("mm.track_failed", event_name=name, exc_info=True)

    async def _release(self, hold_id: str, *, key: str) -> int:
        if not hold_id:
            return 0
        async with self.node.sessionmaker() as db:
            refunded = await self.node.integrations.escrow.release(db, hold_id=hold_id, key=key)
            await db.commit()
        return refunded

    # mm.cancel and mm.respond

    async def cancel(self, conn: "Connection", ref: str | None) -> None:
        busy = await self.node.busy(conn.uid)
        if busy is not None and busy.startswith("m:"):
            conn.error(
                ref,
                ErrorCode.ALREADY_MATCHED,
                "A match was just found.",
                details={"match_id": busy[2:]},
            )
            return
        if busy is None or not busy.startswith("q:"):
            conn.ack(ref)
            return
        status = await self.cancel_ticket(conn.uid, busy[2:], reason="user")
        if status == "matched":
            matched = await self.node.busy(conn.uid)
            conn.error(
                ref,
                ErrorCode.ALREADY_MATCHED,
                "A match was just found.",
                details={"match_id": (matched or "m:")[2:]},
            )
            return
        conn.ack(ref)

    async def cancel_ticket(self, uid: str, ticket_id: str, *, reason: str) -> str:
        """End a ticket, refund any hold and send ``mm.cancelled``; returns the script status."""
        joined_ms = await rstr.hget(self.redis, keys.ticket(ticket_id), "joined_ms")
        status, value = await tickets.end_ticket(self.redis, uid, ticket_id)
        if status != "cancelled":
            return status
        refunded = await self._release(value, key=f"mm:{ticket_id}:refund")
        waited_s = max(0, (self.node.clock.now_ms() - int(joined_ms or 0)) // 1000)
        await self._track(
            "mm_cancelled", uid, {"reason": reason, "waited_s": waited_s if joined_ms else 0}
        )
        await protocol.publish_to_user(
            self.redis,
            uid,
            "mm.cancelled",
            {"reason": reason, "refunded": refunded},
            ts=self.node.clock.now_ms(),
        )
        log.info("mm.cancelled", user_id=uid, reason=reason, refunded=refunded)
        return status

    async def respond(self, conn: "Connection", ref: str | None, d: Mapping[str, Any]) -> None:
        choice = d.get("choice")
        if choice not in {"keep", "bot", "invite", "cancel"}:
            conn.error(ref, ErrorCode.BAD_REQUEST, "choice must be keep, bot, invite or cancel.")
            return
        busy = await self.node.busy(conn.uid)
        if busy is None or not busy.startswith("q:"):
            if busy is not None and busy.startswith("m:"):
                conn.error(
                    ref,
                    ErrorCode.ALREADY_MATCHED,
                    "A match was just found.",
                    details={"match_id": busy[2:]},
                )
            else:
                conn.error(ref, ErrorCode.NOT_FOUND, "You're not searching.")
            return
        ticket_id = busy[2:]
        if choice == "keep":
            deadline = self.node.clock.now_ms() + round(self.settings.mm_keep_s * 1000)
            current = await rstr.hget(self.redis, keys.ticket(ticket_id), "deadline_ms")
            await self.redis.hset(
                keys.ticket(ticket_id), "deadline_ms", max(deadline, int(current or 0))
            )
            conn.ack(ref)
            return
        subject, chapter = await rstr.hmget(
            self.redis, keys.ticket(ticket_id), ["subject", "chapter"]
        )
        status = await self.cancel_ticket(conn.uid, ticket_id, reason="user")
        if status == "matched":
            matched = await self.node.busy(conn.uid)
            conn.error(
                ref,
                ErrorCode.ALREADY_MATCHED,
                "A match was just found.",
                details={"match_id": (matched or "m:")[2:]},
            )
            return
        conn.ack(ref)
        if choice == "bot" and subject is not None:
            await self.start_bot(
                conn.uid, subject, None if chapter in {None, tickets.ALL_CHAPTERS} else chapter
            )

    # Practice Bot

    async def start_bot(self, uid: str, subject: str, chapter: str | None) -> str | None:
        """Start a Practice Bot game at once and send ``mm.found {bot: true}``."""
        mid = new_id()
        try:
            async with self.node.sessionmaker() as db:
                prepared = await prepare_match(
                    db,
                    self.settings,
                    match_id=mid,
                    kind=MatchKind.BOT,
                    subject_slug=subject,
                    contenders=[
                        Contender(
                            user_id=uuid.UUID(uid),
                            chapter=chapter,
                            joined_ms=self.node.clock.now_ms(),
                        )
                    ],
                    with_bot=True,
                )
                await db.commit()
            await self.node.engine.start_match(
                str(mid), prepared.config, prepared.questions, ttl_s=prepared.ttl_s
            )
        except MatchUnavailable:
            log.warning("mm.bot_unavailable", user_id=uid, subject=subject)
            return None
        await self.announce(prepared.found)
        return str(mid)

    async def announce(self, found: Mapping[uuid.UUID, Mapping[str, Any]]) -> None:
        """Send each player their ``mm.found`` (kept briefly for a repeated ``mm.join``)."""
        now = self.node.clock.now_ms()
        for user_id, payload in found.items():
            await self.redis.set(f"mm:found:{user_id}", orjson.dumps(payload), ex=FOUND_TTL_S)
            await protocol.publish_to_user(
                self.redis, str(user_id), "mm.found", dict(payload), ts=now
            )

    # Queue leaders

    async def _lead(self) -> None:
        """Tick every queue this node leads."""
        queues = sorted(rstr.as_str(q) for q in await self.redis.smembers(keys.QUEUES))
        for queue in queues:
            mode, _, subject = queue.partition(":")
            if mode in QUEUED_MODES and await self._leads(mode, subject):
                await self.tick(mode, subject)

    async def _leads(self, mode: str, subject: str) -> bool:
        key = keys.queue_leader(mode, subject)
        ttl_ms = max(1000, round(self.settings.mm_tick_s * 4000))
        if await self.redis.set(key, self.node.node_id, nx=True, px=ttl_ms):
            return True
        lost = await scripts.renew_leases(self.redis, [key], self.node.node_id, ttl_ms)
        return not lost

    async def tick(self, mode: str, subject: str) -> None:
        """One leader tick of a queue: drop, pair, then status and timeout offers."""
        queue = keys.queue(mode, subject)
        ticket_ids = [rstr.as_str(t) for t in await self.redis.zrange(queue, 0, -1)]
        if not ticket_ids:
            return
        async with self.redis.pipeline(transaction=False) as pipe:
            for ticket_id in ticket_ids:
                pipe.hgetall(keys.ticket(ticket_id))
            hashes = await pipe.execute()
        now = self.node.clock.now_ms()
        waiting: list[QueuedTicket] = []
        for ticket_id, fields in zip(ticket_ids, hashes, strict=True):
            if not fields:
                await self.redis.zrem(queue, ticket_id)
                continue
            ticket = QueuedTicket(ticket_id, fields)
            reason = self._drop_reason(ticket, now)
            if reason is not None:
                await self.cancel_ticket(ticket.uid, ticket_id, reason=reason)
            else:
                waiting.append(ticket)
        waiting.sort(key=lambda t: (t.joined_ms, t.uid))
        paired: set[str] = set()
        for index, a in enumerate(waiting):
            if a.ticket_id in paired:
                continue
            for b in await self._candidates(
                a, waiting[index + 1 :] + waiting[:index], paired, mode, now
            ):
                if await self._pair(mode, subject, a, b, now):
                    paired.update({a.ticket_id, b.ticket_id})
                    break
        for ticket in waiting:
            if ticket.ticket_id not in paired:
                await self._offer(ticket, mode, subject, now)

    def _drop_reason(self, ticket: QueuedTicket, now: int) -> str | None:
        fields = ticket.fields
        disconnected = int(fields.get("disc_ms") or 0)
        background = int(fields.get("bg_ms") or 0)
        if now >= int(fields.get("deadline_ms") or 0):
            return "timeout"
        if disconnected and now - disconnected > self.settings.mm_offline_s * 1000:
            return "disconnected"
        if background and now - background > self.settings.mm_background_s * 1000:
            return "background"
        return None

    async def _candidates(
        self,
        a: QueuedTicket,
        others: list[QueuedTicket],
        paired: set[str],
        mode: str,
        now: int,
    ) -> list[QueuedTicket]:
        """Compatible partners for ``a``, closest rating first (then longest waiting)."""
        rated = mode == "rated"
        ta = a.rules_ticket()
        # The shadow pool (moderation) only ever plays itself.
        shadow = a.fields.get("shadow", "0")
        found = [
            b
            for b in others
            if b.ticket_id not in paired
            and b.fields.get("shadow", "0") == shadow
            and rules.compatible(ta, b.rules_ticket(), now, rated=rated)
        ]
        found.sort(key=lambda b: (abs(float(b.fields["rating"]) - ta.rating), b.joined_ms))
        allowed = []
        for b in found:
            if (
                rated
                and await self._rated_games(a.uid, b.uid, now) >= self.settings.mm_rated_pair_limit
            ):
                continue
            if await self._blocked(a.uid, b.uid):
                continue
            allowed.append(b)
        return allowed

    async def _blocked(self, a: str, b: str) -> bool:
        check = self.node.integrations.are_blocked
        if check is never_blocked:  # nothing registered: skip the database
            return False
        async with self.node.sessionmaker() as db:
            return await check(db, uuid.UUID(a), uuid.UUID(b))

    async def _rated_games(self, a: str, b: str, now: int) -> int:
        lo, hi = sorted((a, b))
        return int(await self.redis.zcount(keys.pair_games(lo, hi), now - PAIR_WINDOW_MS, "+inf"))

    async def _pair(
        self, mode: str, subject: str, a: QueuedTicket, b: QueuedTicket, now: int
    ) -> bool:
        mid = new_id()
        paired = await scripts.mm_pair(
            self.redis,
            (a.uid, a.ticket_id),
            (b.uid, b.ticket_id),
            mode=mode,
            subject=subject,
            mid=str(mid),
            busy_ttl_s=tickets.busy_ttl_s(self.settings),
        )
        if not paired:
            return False
        try:
            async with self.node.sessionmaker() as db:
                prepared = await prepare_match(
                    db,
                    self.settings,
                    match_id=mid,
                    kind=KIND_OF_MODE[mode],
                    subject_slug=subject,
                    contenders=[a.contender(), b.contender()],
                )
                await db.commit()
            await self.node.engine.start_match(
                str(mid), prepared.config, prepared.questions, ttl_s=prepared.ttl_s
            )
        except Exception:
            log.exception("mm.match_failed", match_id=str(mid))
            await scripts.mm_unpair(
                self.redis,
                (a.uid, a.ticket_id, a.fields),
                (b.uid, b.ticket_id, b.fields),
                mode=mode,
                subject=subject,
                mid=str(mid),
                busy_ttl_s=tickets.busy_ttl_s(self.settings),
            )
            for ticket in (a, b):
                await protocol.publish_to_user(
                    self.redis,
                    ticket.uid,
                    "mm.requeued",
                    {"reason": "match_failed", "waited_s": (now - ticket.joined_ms) // 1000},
                    ts=now,
                )
            return True  # both are back in the queue; don't pair them again this tick
        if mode == "rated":
            lo, hi = sorted((a.uid, b.uid))
            await self.redis.zadd(keys.pair_games(lo, hi), {str(mid): now})
            await self.redis.pexpire(keys.pair_games(lo, hi), PAIR_WINDOW_MS)
        waits = keys.waits(subject, _hour(now))
        async with self.redis.pipeline(transaction=False) as pipe:
            for ticket in (a, b):
                pipe.lpush(waits, (now - ticket.joined_ms) // 1000)
            pipe.ltrim(waits, 0, WAIT_SAMPLES - 1)
            pipe.expire(waits, WAIT_TTL_S)
            await pipe.execute()
        await self.announce(prepared.found)
        for ticket in (a, b):
            await self._track(
                "mm_found",
                ticket.uid,
                {"mode": mode, "subject": subject, "waited_s": (now - ticket.joined_ms) // 1000},
            )
        log.info("mm.paired", match_id=str(mid), mode=mode, subject=subject)
        return True

    async def _offer(self, ticket: QueuedTicket, mode: str, subject: str, now: int) -> None:
        """``mm.status`` when the search widens or its window grows; ``mm.timeout`` offers."""
        waited_ms = max(0, now - ticket.joined_ms)
        waited_s = waited_ms / 1000
        widened = ticket.chapter is not None and waited_ms >= rules.CHAPTER_WIDEN_MS
        window = self._window(waited_s, mode, ticket.fields["rd"])
        status = f"{int(widened)}:{window}"
        key = keys.ticket(ticket.ticket_id)
        if status != ticket.fields.get("last_status"):
            online, p50 = await online_stats(self.redis, subject, now)
            await self.redis.hset(key, "last_status", status)
            await protocol.publish_to_user(
                self.redis,
                ticket.uid,
                "mm.status",
                {
                    "waited_s": int(waited_s),
                    "widened": widened,
                    "window": window,
                    "online": online,
                    "p50_wait_s": p50,
                },
                ts=now,
            )
        offers = [self.settings.mm_timeout_s]
        if ticket.fields.get("first") == "1":
            offers = sorted({self.settings.mm_first_timeout_s, self.settings.mm_timeout_s})
        sent = int(ticket.fields.get("timeouts") or 0)
        if sent < len(offers) and waited_s >= offers[sent]:
            await self.redis.hincrby(key, "timeouts", 1)
            await protocol.publish_to_user(
                self.redis,
                ticket.uid,
                "mm.timeout",
                {"waited_s": int(waited_s), "options": tickets.TIMEOUT_OPTIONS},
                ts=now,
            )
