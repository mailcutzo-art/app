"""Players reporting a question that looks wrong, has a typo or is unclear."""

import math
import uuid
from datetime import datetime, time, timedelta

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.errors import NotFound, RateLimited
from app.modules.content.models import QuestionReport, ReportStatus
from app.modules.content.views import visible_view

MAX_REPORTS_PER_DAY = 20  # per player, per day in India


async def report_question(
    db: AsyncSession,
    user_id: uuid.UUID,
    question_id: uuid.UUID,
    *,
    reason: str,
    note: str | None,
    now: datetime,
) -> None:
    """File a report. Idempotent while the player's earlier report on it is still open."""
    if await visible_view(db, user_id, question_id) is None:
        raise NotFound("This question doesn't exist.", code="QUESTION_NOT_FOUND")
    open_report = await db.scalar(
        select(QuestionReport.id).where(
            QuestionReport.user_id == user_id,
            QuestionReport.question_id == question_id,
            QuestionReport.status == ReportStatus.OPEN.value,
        )
    )
    if open_report is not None:
        return
    today = now.astimezone(IST).date()
    day_start = datetime.combine(today, time(), tzinfo=IST)
    filed_today = await db.scalar(
        select(func.count()).where(
            QuestionReport.user_id == user_id, QuestionReport.created_at >= day_start
        )
    )
    if (filed_today or 0) >= MAX_REPORTS_PER_DAY:
        seconds_left = (day_start + timedelta(days=1) - now).total_seconds()
        raise RateLimited(
            retry_after=math.ceil(seconds_left),
            message="You've sent the most reports allowed today. Thank you for helping!",
        )
    await db.execute(
        insert(QuestionReport)
        .values(
            user_id=user_id,
            question_id=question_id,
            reason=reason,
            note=note,
            created_at=now,
        )
        .on_conflict_do_nothing()  # a report filed concurrently from another phone
    )
