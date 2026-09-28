"""Streaks: days in a row with at least 10 answers or 1 finished battle (IST days).

A streak is evaluated lazily by ``evaluate``: when the player (or a worker job) next looks, every
day since the last evaluation is settled in order. A past day that qualified extends the streak;
one that didn't uses a freeze if the player holds one (the day shows as frozen and the streak
survives without growing), and otherwise ends the streak. Today only ever extends: it can't be
missed before it is over.

Freezes: hold at most ``MAX_FREEZES``, bought for ``FREEZE_PRICE`` coins. Day 7 and day 30 of a
streak pay ``STREAK_REWARDS`` coins. Finished battles are counted per day in ``streak_days``
(``record_battle``); answers come from ``user_daily_stats``.
"""

import uuid
from bisect import bisect_right
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.errors import Conflict
from app.modules.analytics.service import track
from app.modules.economy.models import CoinReason, LedgerEntry, RefKind
from app.modules.economy.service import Ref, credit, debit
from app.modules.notifications.service import notify
from app.modules.practice.models import UserDailyStats
from app.modules.progression import achievements
from app.modules.progression.models import Metric, StreakDay, StreakState, UserStreak

MIN_ANSWERS = 10
MIN_BATTLES = 1
MAX_FREEZES = 2
FREEZE_PRICE = 50
STREAK_REWARDS = {7: 30, 30: 100}
KEEP_GOING = {"route": "/learn", "params": {}}


class FreezeLimit(Conflict):
    default_code = "FREEZE_LIMIT"
    default_message = f"You can hold at most {MAX_FREEZES} streak freezes."


@dataclass(frozen=True, slots=True)
class StreakStatus:
    days: int
    best: int
    freezes: int
    today_done: bool
    extended: bool  # this evaluation made today count

    def home(self) -> dict[str, int | bool]:
        """Home's ``missions.streak``."""
        return {"days": self.days, "today_done": self.today_done, "freezes": self.freezes}


def ist_day(now: datetime) -> date:
    return now.astimezone(IST).date()


async def record_battle(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> None:
    """Count one finished battle on today's (IST) streak day. Callers de-duplicate."""
    statement = insert(StreakDay).values(user_id=user_id, day=ist_day(now), battles_finished=1)
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["user_id", "day"],
            set_={"battles_finished": StreakDay.__table__.c.battles_finished + 1},
        )
    )


async def _locked(db: AsyncSession, user_id: uuid.UUID) -> UserStreak:
    await db.execute(insert(UserStreak).values(user_id=user_id).on_conflict_do_nothing())
    return await db.get_one(UserStreak, user_id, with_for_update=True, populate_existing=True)


async def active_days(db: AsyncSession, user_id: uuid.UUID, start: date, end: date) -> list[date]:
    """Days in ``[start, end]`` that qualify, in order."""
    answered = select(UserDailyStats.day).where(
        UserDailyStats.user_id == user_id, UserDailyStats.day.between(start, end)
    )
    answered = answered.group_by(UserDailyStats.day).having(
        func.sum(UserDailyStats.attempts) >= MIN_ANSWERS
    )
    battled = select(StreakDay.day).where(
        StreakDay.user_id == user_id,
        StreakDay.day.between(start, end),
        StreakDay.battles_finished >= MIN_BATTLES,
    )
    days = set(await db.scalars(answered)) | set(await db.scalars(battled))
    return sorted(days)


async def _mark(db: AsyncSession, user_id: uuid.UUID, day: date, state: StreakState) -> None:
    statement = insert(StreakDay).values(user_id=user_id, day=day, state=state.value)
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["user_id", "day"], set_={"state": statement.excluded.state}
        )
    )


async def evaluate(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> StreakStatus:
    """Settle every day up to today and return the streak (locks the user's streak row)."""
    streak = await _locked(db, user_id)
    today = ist_day(now)
    # A first evaluation also settles yesterday, so a late-night battle isn't lost.
    start = (streak.checked_through or today - timedelta(days=2)) + timedelta(days=1)
    active = await active_days(db, user_id, start, today) if start <= today else []
    day = start
    while day < today:
        if streak.last_day is not None and day <= streak.last_day:
            pass  # counted already (it was "today" at the last evaluation)
        elif day in active:
            await _extend(db, streak, day, now=now)
        elif streak.current > 0:
            if streak.freezes > 0:
                await _freeze(db, streak, day, now=now)
            else:
                await _lose(db, streak, day, now=now)
        if streak.current == 0:
            # Nothing to protect: skip ahead to the next day that counts.
            later = bisect_right(active, day)
            day = active[later] if later < len(active) else today
        else:
            day += timedelta(days=1)
    streak.checked_through = max(streak.checked_through or date.min, today - timedelta(days=1))
    extended = False
    if today in active and streak.last_day != today:
        await _extend(db, streak, today, now=now)
        extended = True
    await db.flush()
    return StreakStatus(
        days=streak.current,
        best=streak.best,
        freezes=streak.freezes,
        today_done=streak.last_day == today and streak.current > 0,
        extended=extended,
    )


async def _extend(db: AsyncSession, streak: UserStreak, day: date, *, now: datetime) -> None:
    alive = streak.current > 0 and streak.last_day == day - timedelta(days=1)
    if alive:
        streak.current += 1
    else:
        streak.current = 1
        streak.started_on = day
    streak.last_day = day
    streak.best = max(streak.best, streak.current)
    await db.flush()
    await _mark(db, streak.user_id, day, StreakState.ACTIVE)
    started = (streak.started_on or day).isoformat()
    reward = STREAK_REWARDS.get(streak.current)
    if reward is not None:
        await credit(
            db,
            streak.user_id,
            reward,
            reason=CoinReason.STREAK_BONUS,
            title=f"{streak.current}-day streak",
            key=f"streak:{streak.user_id}:{started}:{streak.current}",
            ref=Ref(RefKind.STREAK, started),
        )
    await track(db, "streak_extended", streak.user_id, {"days": streak.current}, now=now)
    await achievements.signal(
        db,
        streak.user_id,
        Metric.STREAK,
        amount=streak.current,
        event_id=f"{started}:{streak.current}",
    )


async def _freeze(db: AsyncSession, streak: UserStreak, day: date, *, now: datetime) -> None:
    streak.freezes -= 1
    streak.last_day = day
    await db.flush()
    await _mark(db, streak.user_id, day, StreakState.FROZEN)
    await notify(
        db,
        streak.user_id,
        kind="streak_freeze_used",
        title="Streak freeze used",
        body=(
            f"You missed {day.day} {day:%b}, so a freeze kept your {streak.current}-day "
            f"streak. {streak.freezes} left."
        ),
        icon="freeze",
        action=KEEP_GOING,
        key=f"streak_freeze:{day.isoformat()}",
    )
    await track(db, "streak_freeze_used", streak.user_id, {"days": streak.current}, now=now)


async def _lose(db: AsyncSession, streak: UserStreak, day: date, *, now: datetime) -> None:
    lost, started = streak.current, streak.started_on
    streak.current = 0
    streak.started_on = None
    await db.flush()
    await notify(
        db,
        streak.user_id,
        kind="streak_lost",
        title="Streak lost",
        body=(
            f"Your {lost}-day streak ended. Answer {MIN_ANSWERS} questions or finish a battle "
            "today to start a new one."
        ),
        icon="flame",
        action=KEEP_GOING,
        key=f"streak_lost:{(started or day).isoformat()}",
    )
    await track(db, "streak_lost", streak.user_id, {"days": lost}, now=now)


async def buy_freeze(
    db: AsyncSession, user_id: uuid.UUID, *, key: str, now: datetime
) -> StreakStatus:
    """Buy one freeze for ``FREEZE_PRICE`` coins; ``key`` (the request's Idempotency-Key)
    makes a retry return the same result instead of buying again."""
    status = await evaluate(db, user_id, now=now)
    streak = await _locked(db, user_id)
    coin_key = f"streak_freeze:{user_id}:{key}"
    bought = await db.scalar(select(LedgerEntry.id).where(LedgerEntry.idempotency_key == coin_key))
    if bought is not None:
        return status
    if streak.freezes >= MAX_FREEZES:
        raise FreezeLimit()
    await debit(
        db,
        user_id,
        FREEZE_PRICE,
        reason=CoinReason.STREAK_FREEZE,
        title="Streak freeze",
        key=coin_key,
        ref=Ref(RefKind.STREAK, "freeze"),
    )
    streak.freezes += 1
    await db.flush()
    return StreakStatus(
        days=status.days,
        best=status.best,
        freezes=streak.freezes,
        today_done=status.today_done,
        extended=False,
    )


@dataclass(frozen=True, slots=True)
class CalendarDay:
    day: date
    state: StreakState | None


async def calendar(
    db: AsyncSession, user_id: uuid.UUID, *, days: int, now: datetime
) -> list[CalendarDay]:
    """The last ``days`` IST days up to today, oldest first. Call ``evaluate`` first."""
    today = ist_day(now)
    first = today - timedelta(days=days - 1)
    rows = await db.execute(
        select(StreakDay.day, StreakDay.state).where(
            StreakDay.user_id == user_id,
            StreakDay.day.between(first, today),
            StreakDay.state.is_not(None),
        )
    )
    states = {day: StreakState(state) for day, state in rows.all() if state is not None}
    return [
        CalendarDay(day, states.get(day))
        for day in (first + timedelta(days=n) for n in range(days))
    ]


async def did_anything(db: AsyncSession, user_id: uuid.UUID, day: date) -> bool:
    """Any answer or finished battle on ``day``."""
    answers = await db.scalar(
        select(func.coalesce(func.sum(UserDailyStats.attempts), 0)).where(
            UserDailyStats.user_id == user_id, UserDailyStats.day == day
        )
    )
    battles = await db.scalar(
        select(StreakDay.battles_finished).where(StreakDay.user_id == user_id, StreakDay.day == day)
    )
    return bool(answers) or bool(battles)
