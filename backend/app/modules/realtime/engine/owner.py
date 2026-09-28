"""Match owners: the per-node asyncio timers that move matches on, and failover.

Whoever creates a match takes its lease (``m:{mid}:lease``, ``SET NX PX``) and keeps one timer
for it at the ``due`` time the scripts return. The timer runs ``advance.lua`` with the version
it last saw; a newer version means another node already moved the match, so the owner simply
re-arms from the returned ``due``. One call per second renews every lease the node holds.

Every script mirrors ``due`` in ``rt:timers``. A scanner reads it every 250 ms: overdue matches
this node owns fire at once (another node's answer may have revealed early), and matches overdue
by more than a second whose owner's lease lapsed are adopted.

The Practice Bot's answers are scheduled by the owner when a question opens, from the pure bot
model seeded by (match, question), so a new owner after failover computes the same answer.
"""

import asyncio
import contextlib
import random
from collections.abc import Awaitable, Callable, Coroutine
from dataclasses import dataclass
from typing import Any

import orjson
import structlog
from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.core.config import Settings
from app.modules.realtime import keys, rstr
from app.modules.realtime.bots.model import bot_answer
from app.modules.realtime.clock import SharedClock
from app.modules.realtime.engine import scripts
from app.modules.realtime.loops import every, stop_all

log = structlog.stdlib.get_logger(__name__)

# How many times a timer re-runs advance at once after finding a newer version already due.
_MAX_STALE_RETRIES = 5


@dataclass(slots=True)
class _Owned:
    ver: int
    due: int
    timer: asyncio.TimerHandle | None = None
    firing: bool = False
    bot: str | None = None  # the bot's uid, "" for a human-only match, None until read
    bot_q: int = 0  # the last question the bot's answer was scheduled for
    bot_timer: asyncio.TimerHandle | None = None

    def cancel_timers(self) -> None:
        for handle in (self.timer, self.bot_timer):
            if handle is not None:
                handle.cancel()


class MatchEngine:
    def __init__(
        self,
        *,
        redis: Redis,
        settings: Settings,
        node_id: str,
        clock: SharedClock,
        settle: Callable[[str], Awaitable[bool]],
    ) -> None:
        self.redis = redis
        self.settings = settings
        self.node_id = node_id
        self.clock = clock
        self._settle_fn = settle
        self._owned: dict[str, _Owned] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._loops: list[asyncio.Task[None]] = []
        self._stop = asyncio.Event()
        self._stopped = False

    @property
    def owned(self) -> set[str]:
        return set(self._owned)

    async def start(self) -> None:
        await self.clock.sync(self.redis)
        self._stop = asyncio.Event()
        self._stopped = False
        self._loops = [
            asyncio.create_task(
                every(self.settings.rt_lease_renew_s, self._stop, self._renew, name="leases"),
                name="rt:leases",
            ),
            asyncio.create_task(
                every(self.settings.rt_scan_interval_s, self._stop, self.scan, name="scanner"),
                name="rt:scanner",
            ),
        ]

    async def stop(self, *, release: bool = True) -> None:
        """Stop timers and loops. ``release`` hands the leases back so other nodes adopt the
        matches at once (a graceful shutdown); without it they wait for the leases to lapse."""
        self._stopped = True  # no new timers or tasks from here on
        await stop_all(self._stop, self._loops)
        self._loops = []
        for owned in self._owned.values():
            owned.cancel_timers()
        mids = list(self._owned)
        self._owned.clear()
        if self._tasks:
            _, pending = await asyncio.wait(self._tasks, timeout=5)
            for task in pending:
                task.cancel()
        if release and mids:
            with contextlib.suppress(RedisError):
                await scripts.release_leases(
                    self.redis, [keys.match_lease(mid) for mid in mids], self.node_id
                )
        log.info("rt.engine_stopped", released=len(mids) if release else 0)

    # Starting and following matches

    async def start_match(
        self, mid: str, config: dict[str, Any], questions: list[dict[str, Any]], *, ttl_s: int
    ) -> scripts.Step:
        """Create the live state of a prepared match and own it."""
        step = await scripts.create(self.redis, mid, config, questions, ttl_s=ttl_s)
        await self._take(mid, step.ver, step.due)
        return step

    def report(self, mid: str, *, ver: int, due: int, ended: bool = False) -> None:
        """A script run on this node changed the match (an answer, a ready, a drop...)."""
        owned = self._owned.get(mid)
        if ended:
            self._disown(mid)
            self._spawn(self._settle(mid))
            return
        if owned is None or ver < owned.ver:
            return
        owned.ver, owned.due = ver, due
        self._arm(mid)
        self._spawn(self._ensure_bot(mid))

    async def _take(self, mid: str, ver: int, due: int) -> bool:
        lease = keys.match_lease(mid)
        acquired = await self.redis.set(lease, self.node_id, nx=True, px=self.settings.rt_lease_ms)
        if not acquired and await self.redis.get(lease) != self.node_id:
            return False
        self._owned[mid] = _Owned(ver=ver, due=due)
        self._arm(mid)
        return True

    def _disown(self, mid: str) -> None:
        owned = self._owned.pop(mid, None)
        if owned is not None:
            owned.cancel_timers()

    def _arm(self, mid: str) -> None:
        owned = self._owned[mid]
        if owned.timer is not None:
            owned.timer.cancel()
            owned.timer = None
        if owned.due > 0 and not self._stopped:
            loop = asyncio.get_running_loop()
            owned.timer = loop.call_later(
                self.clock.delay_s(owned.due), lambda: self._spawn(self._fire(mid))
            )

    def _spawn(self, coroutine: Coroutine[Any, Any, Any]) -> None:
        if self._stopped:
            coroutine.close()
            return
        task = asyncio.create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _fire(self, mid: str) -> None:
        owned = self._owned.get(mid)
        if owned is None or owned.firing:
            return
        owned.firing = True
        try:
            for _ in range(_MAX_STALE_RETRIES):
                step = await scripts.advance(self.redis, mid, owned.ver)
                if step.status in {"missing", "done"}:
                    self._disown(mid)
                    if step.status == "done":
                        self._spawn(self._settle(mid))
                    return
                if step.ended:
                    self._disown(mid)
                    self._spawn(self._settle(mid))
                    return
                owned.ver, owned.due = step.ver, step.due
                if step.status != "stale" or step.due > self.clock.now_ms():
                    break
            self._arm(mid)
        except RedisError:
            log.warning("rt.advance_failed", match_id=mid, exc_info=True)
            owned.due = self.clock.now_ms() + 250
            self._arm(mid)
            return
        finally:
            owned.firing = False
        await self._ensure_bot(mid)

    # The Practice Bot

    async def _ensure_bot(self, mid: str) -> None:
        """Schedule the bot's answer to the open question, once per question."""
        owned = self._owned.get(mid)
        if owned is None or owned.bot == "":
            return
        match_key = keys.match(mid)
        bot, phase, q_raw, accuracy = await rstr.hmget(
            self.redis, match_key, ["bot", "phase", "q", "bot_acc"]
        )
        owned.bot = bot or ""
        if not bot or phase != "q_open" or q_raw is None:
            return
        q = int(q_raw)
        if owned.bot_q >= q:
            return
        owned.bot_q = q
        question_key = keys.match_question(mid, q)
        shown_at, correct, options, limit, answered = await rstr.hmget(
            self.redis, question_key, ["shown_at", "correct", "options", "limit_ms", f"a:{bot}"]
        )
        if (
            answered is not None
            or shown_at is None
            or correct is None
            or options is None
            or limit is None
        ):
            return
        rng = random.Random(f"{mid}:{q}")  # noqa: S311 - a game opponent, not security
        scale = self.settings.match_bot_time_scale
        right, model_ms = bot_answer(
            rng, accuracy=float(accuracy or 0.5), limit_ms=round(int(limit) / scale)
        )
        if model_ms is None:
            return  # the bot times out on this one
        time_ms = round(model_ms * scale)
        ids = [option["id"] for option in orjson.loads(options)]
        option = correct if right else rng.choice([i for i in ids if i != correct])
        delay = self.clock.delay_s(int(shown_at) + time_ms)
        if owned.bot_timer is not None:
            owned.bot_timer.cancel()
        owned.bot_timer = asyncio.get_running_loop().call_later(
            delay, lambda: self._spawn(self._bot_answers(mid, bot, q, option, time_ms))
        )

    async def _bot_answers(self, mid: str, bot: str, q: int, option: str, time_ms: int) -> None:
        try:
            step = await scripts.answer(
                self.redis, mid, bot, q=q, opt=option, el_ms=time_ms, bot_ms=time_ms
            )
        except RedisError:
            log.warning("rt.bot_answer_failed", match_id=mid, exc_info=True)
            return
        if not step.dup:
            self.report(mid, ver=step.ver, due=step.due)

    # Settlement

    async def _settle(self, mid: str) -> None:
        try:
            await self._settle_fn(mid)
        except Exception:  # the worker retries it
            log.exception("rt.settle_failed", match_id=mid)

    # Leases and failover

    async def _renew(self) -> None:
        await self.clock.sync(self.redis)
        mids = list(self._owned)
        lost = await scripts.renew_leases(
            self.redis,
            [keys.match_lease(mid) for mid in mids],
            self.node_id,
            self.settings.rt_lease_ms,
        )
        for index in lost:
            log.warning("rt.lease_lost", match_id=mids[index])
            self._disown(mids[index])

    async def scan(self) -> None:
        """Fire owned matches that are due and adopt overdue ones nobody owns."""
        now = self.clock.now_ms()
        due: list[tuple[str, float]] = await self.redis.zrangebyscore(
            keys.TIMERS, "-inf", now, start=0, num=500, withscores=True
        )  # type: ignore[assignment]
        for raw_mid, raw_score in due:
            mid, score = rstr.as_str(raw_mid), int(raw_score)
            owned = self._owned.get(mid)
            if owned is not None:
                if not owned.firing:
                    self._spawn(self._fire(mid))
            elif now - score > self.settings.rt_overdue_ms:
                ver = await rstr.hget(self.redis, keys.match(mid), "ver")
                if ver is None:
                    await self.redis.zrem(keys.TIMERS, mid)
                elif await self._take(mid, int(ver), score):
                    log.info("rt.match_adopted", match_id=mid, overdue_ms=now - score)
                    self._spawn(self._fire(mid))
