"""Helpers for the progression tests: IST times, activity rows and reads."""

import uuid
from datetime import date, datetime

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.modules.content.models import Subject
from app.modules.economy.models import LedgerEntry
from app.modules.economy.service import get_wallet
from app.modules.notifications.models import Notification
from app.modules.practice.models import UserDailyStats


def ist(day: date, hour: int = 12, minute: int = 0) -> datetime:
    """A moment on an IST calendar day."""
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=IST)


async def answered_on(db: AsyncSession, user_id: uuid.UUID, day: date, attempts: int) -> None:
    """Pretend the user answered ``attempts`` questions on ``day`` (IST)."""
    subject_id = await db.scalar(select(Subject.id).where(Subject.slug == "physics"))
    statement = insert(UserDailyStats).values(
        user_id=user_id, day=day, subject_id=subject_id, attempts=attempts, last_at=ist(day)
    )
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["user_id", "day", "subject_id"],
            set_={"attempts": UserDailyStats.__table__.c.attempts + attempts},
        )
    )


async def balance(db: AsyncSession, user_id: uuid.UUID) -> int:
    return (await get_wallet(db, user_id)).balance


async def ledger(db: AsyncSession, user_id: uuid.UUID) -> list[tuple[int, str, str]]:
    """(delta, reason, title) oldest first."""
    rows = await db.execute(
        select(LedgerEntry.delta, LedgerEntry.reason, LedgerEntry.title)
        .where(LedgerEntry.user_id == user_id)
        .order_by(LedgerEntry.created_at, LedgerEntry.id)
    )
    return [tuple(row) for row in rows.all()]  # type: ignore[misc]


async def inbox(
    db: AsyncSession, user_id: uuid.UUID, kind: str | None = None
) -> list[Notification]:
    statement = select(Notification).where(Notification.user_id == user_id)
    if kind is not None:
        statement = statement.where(Notification.kind == kind)
    return list(await db.scalars(statement.order_by(Notification.created_at, Notification.id)))


async def count_inbox(db: AsyncSession, user_id: uuid.UUID, kind: str) -> int:
    return (
        await db.scalar(
            select(func.count()).where(Notification.user_id == user_id, Notification.kind == kind)
        )
        or 0
    )
