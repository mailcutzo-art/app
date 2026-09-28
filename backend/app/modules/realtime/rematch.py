"""Casual rematches (``match.rematch`` and ``rematch.status``, ``docs/protocol.md`` section 6).

Only after a finished casual Quick Battle, within 15 s of ``match.end``, and at most 3 in a row.
The first acceptance is announced as ``offered``; when both players accept, a new 5-coin entry is
held from each and a new match starts with the same subject and chapters (``mm.found``). The
offer lapses (``expired``) when the window closes, and fails when a player can't pay
(``insufficient_coins``) or has gone (``opponent_left``). ``rematch.status`` is a shared event
on the old match's channel.
"""

import asyncio
import uuid
from typing import TYPE_CHECKING, Any

import orjson
import structlog

from app.core.ids import new_id
from app.modules.matches.creation import Contender, MatchUnavailable, prepare_match
from app.modules.matches.models import Match, MatchKind
from app.modules.matches.ports import InsufficientCoins
from app.modules.realtime import keys, rstr
from app.modules.realtime.engine import scripts
from app.modules.realtime.protocol import ErrorCode

if TYPE_CHECKING:
    from app.modules.realtime.connection import Connection
    from app.modules.realtime.node import RtNode

log = structlog.stdlib.get_logger(__name__)


class Rematches:
    def __init__(self, node: "RtNode") -> None:
        self.node = node
        self.redis = node.redis
        self.settings = node.settings
        self._timers: dict[str, asyncio.TimerHandle] = {}

    async def respond(self, conn: "Connection", ref: str | None, mid: str, *, accept: bool) -> None:
        kind, phase, finished_ms, humans_raw, meta_raw = await rstr.hmget(
            self.redis, keys.match(mid), ["kind", "phase", "finished_ms", "humans", "meta"]
        )
        if kind != MatchKind.QUICK_CASUAL or phase != "finished" or humans_raw is None:
            conn.error(ref, ErrorCode.NOT_ALLOWED, "Rematches are for casual battles.")
            return
        humans: list[str] = orjson.loads(humans_raw)
        chain = int(orjson.loads(meta_raw or "{}").get("rematch_chain", 0))
        if chain >= self.settings.match_rematch_max:
            conn.error(ref, ErrorCode.NOT_ALLOWED, "That's enough rematches for now.")
            return
        now = self.node.clock.now_ms()
        until = int(finished_ms or 0) + self.settings.match_rematch_window_ms
        key = keys.match_rematch(mid)
        state = await rstr.hget(self.redis, key, "state")
        if state in {"accepted", "declined", "expired", "failed"}:
            await self._status(mid, state, conn.uid, None)
            return
        if now > until:
            await self._close(mid, "expired", conn.uid, None)
            return
        if not accept:
            await self._close(mid, "declined", conn.uid, None)
            return
        async with self.redis.pipeline(transaction=True) as pipe:
            pipe.hsetnx(key, f"accept:{conn.uid}", 1)
            pipe.hset(key, "state", "open")
            pipe.pexpire(key, self.settings.match_rematch_window_ms + 60_000)
            first_accept, _, _ = await pipe.execute()
        accepted = [uid for uid in humans if await self.redis.hexists(key, f"accept:{uid}")]
        if len(accepted) < len(humans):
            if first_accept:
                await self._status(mid, "offered", conn.uid, None)
                self._timers[mid] = asyncio.get_running_loop().call_later(
                    max(0.0, (until - now) / 1000),
                    lambda: self.node.spawn(self._expire(mid)),
                )
            return
        # Both accepted: exactly one caller wins the right to start the new match.
        if not await self.redis.hsetnx(key, "starting", 1):
            return
        await self._start(mid, humans, chain, by=conn.uid)

    def stop(self) -> None:
        for handle in self._timers.values():
            handle.cancel()
        self._timers.clear()

    async def _expire(self, mid: str) -> None:
        self._timers.pop(mid, None)
        if await rstr.hget(self.redis, keys.match_rematch(mid), "state") == "open":
            await self._close(mid, "expired", None, None)

    async def _close(self, mid: str, state: str, by: str | None, reason: str | None) -> None:
        await self.redis.hset(keys.match_rematch(mid), "state", state)
        await self._status(mid, state, by, reason)

    async def _status(self, mid: str, state: str, by: str | None, reason: str | None) -> None:
        await scripts.emit(
            self.redis,
            mid,
            "rematch.status",
            {"match_id": mid, "state": state, "by": by, "reason": reason},
        )

    async def _start(self, mid: str, humans: list[str], chain: int, *, by: str) -> None:
        online = await self.redis.mget([keys.connection(uid) for uid in humans])
        if not all(online):
            gone = humans[[bool(v) for v in online].index(False)]
            await self._close(mid, "failed", gone, "opponent_left")
            return
        for uid in humans:
            busy = await rstr.get(self.redis, keys.busy(uid))
            if busy is not None and busy != f"m:{mid}":
                await self._close(mid, "failed", uid, "opponent_left")
                return
        new_mid = new_id()
        holds: dict[str, str] = {}
        async with self.node.sessionmaker() as db:
            match = await db.get_one(Match, uuid.UUID(mid))
            requested = match.config.get("requested", [])
            escrow = self.node.integrations.escrow
            try:
                for uid in humans:
                    holds[uid] = await escrow.hold(
                        db,
                        user_id=uuid.UUID(uid),
                        amount=self.settings.casual_fee,
                        key=f"rm:{new_mid}:{uid}",
                    )
            except InsufficientCoins:
                short = next(uid for uid in humans if uid not in holds)
                for uid, hold_id in holds.items():
                    await escrow.release(db, hold_id=hold_id, key=f"rm:{new_mid}:{uid}:refund")
                await db.commit()
                await self._close(mid, "failed", short, "insufficient_coins")
                return
            contenders = [
                Contender(
                    user_id=uuid.UUID(uid),
                    chapter=_chapter(requested, index),
                    joined_ms=index,
                    hold_id=holds[uid],
                )
                for index, uid in enumerate(humans)
            ]
            subject = await self._subject(db, match)
            try:
                prepared = await prepare_match(
                    db,
                    self.settings,
                    match_id=new_mid,
                    kind=MatchKind.QUICK_CASUAL,
                    subject_slug=subject,
                    contenders=contenders,
                    rematch_of=uuid.UUID(mid),
                    rematch_chain=chain + 1,
                )
            except MatchUnavailable:
                await db.rollback()
                await self._close(mid, "failed", by, None)
                return
            await db.commit()
        await self.node.engine.start_match(
            str(new_mid), prepared.config, prepared.questions, ttl_s=prepared.ttl_s
        )
        await self._close(mid, "accepted", by, None)
        await self.node.matchmaker.announce(prepared.found)
        log.info("rematch.started", match_id=str(new_mid), rematch_of=mid)

    @staticmethod
    async def _subject(db: Any, match: Match) -> str:
        from app.modules.content.models import Subject

        subject = await db.get_one(Subject, match.subject_id)
        return str(subject.slug)


def _chapter(requested: list[dict[str, Any]], index: int) -> str | None:
    if index < len(requested):
        chapter = requested[index].get("chapter")
        return chapter if isinstance(chapter, str) else None
    return None
