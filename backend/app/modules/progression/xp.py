"""Awarding XP: idempotent events, the running total and the daily practice cap.

The formulas (XP per answer, the cap rule, the level curve) live in
``app.modules.progression.levels``, which is written separately; ``xp_rules()`` is the one place
that connects them. Until it does, practice awards nothing and responses carry ``"xp": null``.
"""

import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.ids import new_id
from app.modules.practice.schemas import XpOut
from app.modules.progression.models import UserProgress, XpEvent, XpSource

PRACTICE_DAILY_CAP = 300


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


def xp_rules() -> XpRules | None:
    """The XP formulas, or ``None`` while ``app.modules.progression.levels`` isn't wired in."""
    return None


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
) -> XpOut | None:
    """Award XP for newly accepted practice answers, within the day's cap (IST).

    ``source_key`` identifies the batch: awarding the same key again changes nothing.
    """
    rules = xp_rules()
    if rules is None:
        return None
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
        )
        .on_conflict_do_nothing()
        .returning(XpEvent.id)
    )
    if event_id is None:  # this batch was awarded before
        return _xp_out(rules, delta=0, total=progress.xp, capped=False, now=now)
    progress.xp += amount
    progress.practice_xp_day = today
    progress.practice_xp_today = already + amount
    await db.flush()
    return _xp_out(rules, delta=amount, total=progress.xp, capped=amount < requested, now=now)


async def session_xp(
    db: AsyncSession, user_id: uuid.UUID, session_id: uuid.UUID, *, now: datetime
) -> XpOut | None:
    """XP earned in one practice session, with the user's total and level.

    ``capped`` says the day's practice XP is used up, so later answers earn none until
    ``resets_at``.
    """
    rules = xp_rules()
    if rules is None:
        return None
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
