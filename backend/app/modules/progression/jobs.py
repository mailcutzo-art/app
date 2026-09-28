"""Worker jobs for streaks: the nightly rollover and the evening reminder (IST).

- **Rollover** (first tick after ``ROLLOVER_HOUR_IST``): every streak not yet settled for
  yesterday is evaluated, so ``streak_freeze_used`` and ``streak_lost`` reach players in the
  morning rather than whenever they next open the app. It also forgets progress-event ids older
  than ``DEDUPE_KEEP``.
- **Reminder** (first tick after ``RISK_HOUR_IST``): players with a live streak who have done
  nothing at all today get a ``streak_risk`` notice.

Each user is handled in their own transaction, so one failure doesn't hold up the rest.
"""

import uuid
from collections.abc import Sequence
from datetime import datetime, timedelta

import structlog
from sqlalchemy import ColumnElement, delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import IST, Clock, utc_now
from app.core.jobs import once_per_day
from app.core.resources import Resources
from app.modules.notifications.service import notify
from app.modules.progression import streaks
from app.modules.progression.models import ProgressEventDedupe, UserStreak

log = structlog.stdlib.get_logger("app.worker")

ROLLOVER_HOUR_IST = 0
RISK_HOUR_IST = 19
DEDUPE_KEEP = timedelta(days=14)
BATCH = 500


async def _users(
    db: AsyncSession, *where: ColumnElement[bool], after: uuid.UUID | None
) -> Sequence[uuid.UUID]:
    statement = select(UserStreak.user_id).where(UserStreak.current > 0, *where)
    if after is not None:
        statement = statement.where(UserStreak.user_id > after)
    rows = (await db.scalars(statement.order_by(UserStreak.user_id).limit(BATCH))).all()
    await db.commit()
    return rows


async def roll_over_streaks(
    sessionmaker: async_sessionmaker[AsyncSession], *, now: datetime
) -> int:
    """Evaluate every live streak whose yesterday isn't settled yet; returns how many."""
    yesterday = now.astimezone(IST).date() - timedelta(days=1)
    unsettled = UserStreak.checked_through.is_(None) | (UserStreak.checked_through < yesterday)
    evaluated = 0
    after: uuid.UUID | None = None
    while True:
        async with sessionmaker() as db:
            batch = await _users(db, unsettled, after=after)
        for user_id in batch:
            async with sessionmaker() as db:
                await streaks.evaluate(db, user_id, now=now)
                await db.commit()
            evaluated += 1
        if len(batch) < BATCH:
            break
        after = batch[-1]
    async with sessionmaker() as db:
        await db.execute(
            delete(ProgressEventDedupe).where(ProgressEventDedupe.created_at < now - DEDUPE_KEEP)
        )
        await db.commit()
    return evaluated


async def remind_streaks_at_risk(
    sessionmaker: async_sessionmaker[AsyncSession], *, now: datetime
) -> int:
    """``streak_risk`` for live streaks with nothing done today; returns how many were sent."""
    today = now.astimezone(IST).date()
    sent = 0
    after: uuid.UUID | None = None
    while True:
        async with sessionmaker() as db:
            batch = await _users(db, UserStreak.last_day < today, after=after)
        for user_id in batch:
            async with sessionmaker() as db:
                status = await streaks.evaluate(db, user_id, now=now)
                if status.days > 0 and not await streaks.did_anything(db, user_id, today):
                    created = await notify(
                        db,
                        user_id,
                        kind="streak_risk",
                        title=f"Keep your {status.days}-day streak",
                        body=(
                            f"Answer {streaks.MIN_ANSWERS} questions or finish a battle before "
                            "midnight to keep it going."
                        ),
                        icon="flame",
                        action=streaks.KEEP_GOING,
                        key=f"streak_risk:{today.isoformat()}",
                    )
                    sent += created is not None
                await db.commit()
        if len(batch) < BATCH:
            break
        after = batch[-1]
    return sent


async def streaks_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()
    local = now.astimezone(IST)
    today = local.date()

    async def rollover() -> None:
        evaluated = await roll_over_streaks(resources.sessionmaker, now=now)
        log.info("streaks.rolled_over", evaluated=evaluated)

    async def remind() -> None:
        sent = await remind_streaks_at_risk(resources.sessionmaker, now=now)
        log.info("streaks.reminded", sent=sent)

    if local.hour >= ROLLOVER_HOUR_IST:
        await once_per_day(resources.redis, "streak_rollover", today, rollover, lease_ttl_s=1800)
    if local.hour >= RISK_HOUR_IST:
        await once_per_day(resources.redis, "streak_risk", today, remind, lease_ttl_s=1800)
