"""Awarding XP: idempotent events, the running total, daily caps and level-ups.

The formulas (XP per answer and game, the cap rule, the level curve) live in
``app.modules.progression.levels``; ``xp_rules()`` is the one place that connects them.

Daily caps (IST days): practice 300, group battles 200 and Practice Bot games 60; other games
are uncapped. Reaching a level credits ``LEVEL_UP_COINS`` coins per level gained, puts a
``level_up`` notice in the inbox and tells the player's friends (the activity feed).
"""

import uuid
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.ids import new_id
from app.modules.analytics.service import track
from app.modules.economy.models import CoinReason, RefKind
from app.modules.economy.service import Ref, credit
from app.modules.notifications.service import notify
from app.modules.practice.schemas import XpOut
from app.modules.progression import achievements, levels
from app.modules.progression.levels import GameKind, GameOutcome
from app.modules.progression.models import Metric, UserProgress, XpEvent, XpSource
from app.modules.social.activity import record_activity

PRACTICE_DAILY_CAP = 300
GAME_DAILY_CAPS: Mapping[GameKind, int] = {GameKind.GROUP: 200, GameKind.BOT: 60}
LEVEL_UP_COINS = 20


@dataclass(frozen=True, slots=True)
class LevelProgress:
    level: int
    into_level: int  # XP earned since this level started
    level_size: int  # XP this level spans ("for_next" in the API)


@dataclass(frozen=True, slots=True)
class XpRules:
    practice_xp: Callable[[bool], int]  # XP for one practice answer (correct or not)
    cap_daily: Callable[[int, int, int], int]  # (already today, award, cap) -> award allowed
    progress: Callable[[int], LevelProgress]  # total XP -> level


def xp_rules() -> XpRules:
    """The XP formulas from ``app.modules.progression.levels``."""
    return XpRules(
        practice_xp=levels.practice_xp,
        cap_daily=levels.cap_daily,
        progress=lambda xp: LevelProgress(*levels.progress(xp)),
    )


@dataclass(frozen=True, slots=True)
class XpAward:
    """One award and where it left the user: ``match.settled.xp`` (see ``fragment``)."""

    delta: int
    total: int
    level: int
    into_level: int
    for_next: int
    level_up: bool
    capped: bool  # the daily cap cut this award
    resets_at: datetime | None  # when the cap resets, if it cut the award

    def fragment(self) -> dict[str, Any]:
        return {
            "delta": self.delta,
            "level": self.level,
            "into_level": self.into_level,
            "for_next": self.for_next,
            "level_up": self.level_up,
            "capped": self.capped,
        }


def next_ist_midnight(now: datetime) -> datetime:
    tomorrow = now.astimezone(IST).date() + timedelta(days=1)
    return datetime.combine(tomorrow, time(), tzinfo=IST)


def _xp_out(rules: XpRules, *, delta: int, total: int, capped: bool, now: datetime) -> XpOut:
    level = rules.progress(total)
    return XpOut(
        delta=delta,
        total=total,
        level=level.level,
        into_level=level.into_level,
        for_next=level.level_size,
        capped=capped,
        resets_at=next_ist_midnight(now) if capped else None,
    )


async def _locked_progress(db: AsyncSession, user_id: uuid.UUID) -> UserProgress:
    """The user's progress row, created if missing and locked for this transaction."""
    await db.execute(insert(UserProgress).values(user_id=user_id).on_conflict_do_nothing())
    return await db.get_one(UserProgress, user_id, with_for_update=True, populate_existing=True)


async def _grow(
    db: AsyncSession,
    user_id: uuid.UUID,
    progress: UserProgress,
    amount: int,
    rules: XpRules,
    *,
    now: datetime,
) -> bool:
    """Add ``amount`` to the locked total; on a new level credit the coins, tell the player and
    move the level achievements. True if the level went up."""
    before = rules.progress(progress.xp).level
    progress.xp += amount
    await db.flush()
    after = rules.progress(progress.xp).level
    if after <= before:
        return False
    for level in range(before + 1, after + 1):
        await credit(
            db,
            user_id,
            LEVEL_UP_COINS,
            reason=CoinReason.LEVEL_UP,
            title=f"Level {level} reached",
            key=f"level:{user_id}:{level}",
            ref=Ref(RefKind.LEVEL, str(level)),
        )
    gained = LEVEL_UP_COINS * (after - before)
    await notify(
        db,
        user_id,
        kind="level_up",
        title=f"Level {after}!",
        body=f"You reached level {after} · +{gained} coins",
        icon="level",
        action={"route": "/profile", "params": {}},
        key=f"level_up:{after}",
    )
    await track(db, "level_up", user_id, {"level": after}, now=now)
    await record_activity(db, user_id, "level_up", {"level": after}, key=f"level_up:{after}")
    await achievements.signal(db, user_id, Metric.LEVEL, amount=after, event_id=f"level:{after}")
    return True


def _practice_today(progress: UserProgress | None, today: date) -> int:
    if progress is None or progress.practice_xp_day != today:
        return 0
    return progress.practice_xp_today


async def award_practice_xp(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    session_id: uuid.UUID,
    source_key: str,
    correct: Sequence[bool],
    now: datetime,
) -> XpOut:
    """Award XP for newly accepted practice answers, within the day's cap (IST).

    ``source_key`` identifies the batch: awarding the same key again changes nothing.
    """
    rules = xp_rules()
    today = now.astimezone(IST).date()
    progress = await _locked_progress(db, user_id)
    already = _practice_today(progress, today)
    requested = sum(rules.practice_xp(ok) for ok in correct)
    amount = rules.cap_daily(already, requested, PRACTICE_DAILY_CAP)
    event_id = await db.scalar(
        insert(XpEvent)
        .values(
            id=new_id(),
            user_id=user_id,
            source=XpSource.PRACTICE.value,
            source_key=source_key,
            amount=amount,
            ref_id=session_id,
            ist_day=today,
            total_after=progress.xp + amount,
        )
        .on_conflict_do_nothing()
        .returning(XpEvent.id)
    )
    if event_id is None:  # this batch was awarded before
        return _xp_out(rules, delta=0, total=progress.xp, capped=False, now=now)
    progress.practice_xp_day = today
    progress.practice_xp_today = already + amount
    await _grow(db, user_id, progress, amount, rules, now=now)
    return _xp_out(rules, delta=amount, total=progress.xp, capped=amount < requested, now=now)


async def session_xp(
    db: AsyncSession, user_id: uuid.UUID, session_id: uuid.UUID, *, now: datetime
) -> XpOut:
    """XP earned in one practice session, with the user's total and level.

    ``capped`` says the day's practice XP is used up, so later answers earn none until
    ``resets_at``.
    """
    rules = xp_rules()
    earned = await db.scalar(
        select(func.coalesce(func.sum(XpEvent.amount), 0)).where(
            XpEvent.user_id == user_id,
            XpEvent.source == XpSource.PRACTICE.value,
            XpEvent.ref_id == session_id,
        )
    )
    progress = await db.get(UserProgress, user_id)
    today = now.astimezone(IST).date()
    return _xp_out(
        rules,
        delta=int(earned or 0),
        total=progress.xp if progress else 0,
        capped=_practice_today(progress, today) >= PRACTICE_DAILY_CAP,
        now=now,
    )


def _award(
    rules: XpRules, *, delta: int, total: int, level_up: bool, capped: bool, now: datetime
) -> XpAward:
    level = rules.progress(total)
    return XpAward(
        delta=delta,
        total=total,
        level=level.level,
        into_level=level.into_level,
        for_next=level.level_size,
        level_up=level_up,
        capped=capped,
        resets_at=next_ist_midnight(now) if capped else None,
    )


async def _earlier(db: AsyncSession, user_id: uuid.UUID, source_key: str) -> XpEvent | None:
    return await db.scalar(
        select(XpEvent).where(XpEvent.user_id == user_id, XpEvent.source_key == source_key)
    )


def _replay(rules: XpRules, event: XpEvent, *, requested: int, now: datetime) -> XpAward:
    """The award as it was first made (``total_after`` pins the level it reached)."""
    total = event.total_after if event.total_after is not None else event.amount
    return _award(
        rules,
        delta=event.amount,
        total=total,
        level_up=rules.progress(total - event.amount).level < rules.progress(total).level,
        capped=event.amount < requested,
        now=now,
    )


async def award_game_xp(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    mode: GameKind | str,
    result: GameOutcome | str,
    match_id: uuid.UUID,
    now: datetime,
) -> XpAward:
    """XP for one finished game, within the kind's daily cap; once per match and player.

    ``mode`` is the game kind (``quick_rated``, ``quick_casual``, ``friend``, ``bot``,
    ``group``, ``tournament``); ``result`` is ``win``, ``draw`` or ``loss`` (in a group battle
    ``win`` means 1st place). A replay returns the first award unchanged.
    """
    kind, outcome = GameKind(mode), GameOutcome(result)
    rules = xp_rules()
    requested = levels.game_xp(kind, outcome)
    source_key = f"match:{match_id}"
    progress = await _locked_progress(db, user_id)
    earlier = await _earlier(db, user_id, source_key)
    if earlier is not None:
        return _replay(rules, earlier, requested=requested, now=now)
    today = now.astimezone(IST).date()
    amount = requested
    cap = GAME_DAILY_CAPS.get(kind)
    if cap is not None:
        already = await db.scalar(
            select(func.coalesce(func.sum(XpEvent.amount), 0)).where(
                XpEvent.user_id == user_id,
                XpEvent.ist_day == today,
                XpEvent.game_kind == kind.value,
            )
        )
        amount = rules.cap_daily(int(already or 0), requested, cap)
        if amount < requested:
            await track(db, "cap_reached", user_id, {"kind": f"xp_{kind.value}"}, now=now)
    await db.execute(
        insert(XpEvent).values(
            id=new_id(),
            user_id=user_id,
            source=XpSource.MATCH.value,
            source_key=source_key,
            amount=amount,
            ref_id=match_id,
            ist_day=today,
            game_kind=kind.value,
            total_after=progress.xp + amount,
        )
    )
    level_up = await _grow(db, user_id, progress, amount, rules, now=now)
    return _award(
        rules,
        delta=amount,
        total=progress.xp,
        level_up=level_up,
        capped=amount < requested,
        now=now,
    )


async def award_xp(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    *,
    source: XpSource,
    source_key: str,
    ref_id: uuid.UUID | None,
    now: datetime,
) -> XpAward:
    """Uncapped XP (missions, the missions bonus); once per ``source_key``."""
    rules = xp_rules()
    progress = await _locked_progress(db, user_id)
    earlier = await _earlier(db, user_id, source_key)
    if earlier is not None:
        return _replay(rules, earlier, requested=amount, now=now)
    await db.execute(
        insert(XpEvent).values(
            id=new_id(),
            user_id=user_id,
            source=source.value,
            source_key=source_key,
            amount=amount,
            ref_id=ref_id,
            ist_day=now.astimezone(IST).date(),
            total_after=progress.xp + amount,
        )
    )
    level_up = await _grow(db, user_id, progress, amount, rules, now=now)
    return _award(rules, delta=amount, total=progress.xp, level_up=level_up, capped=False, now=now)
