"""The Learn tab's personal figures, "Continue practice" and practice history."""

import uuid
from datetime import datetime, timedelta
from typing import Literal

from redis.asyncio import Redis
from sqlalchemy import func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.coach.service import top_tip
from app.modules.content.catalog import goal_subjects
from app.modules.content.models import Chapter
from app.modules.practice.models import (
    Outcome,
    PracticeAnswer,
    PracticeSession,
    UserCategoryStats,
    UserChapterStats,
)
from app.modules.practice.reviews import review_counts
from app.modules.practice.schemas import (
    ChapterProgressOut,
    ContinueOut,
    HistoryItemOut,
    HistoryOut,
    ProgressOut,
    SubjectProgressOut,
)
from app.modules.practice.sessions import (
    HISTORY_DAYS,
    NEET_CORRECT,
    NEET_WRONG,
    challenge_deadline,
)

# Chapter labels: a word per chapter, never a chart. Accuracy is smoothed as (c + 2) / (n + 4)
# so a couple of answers can't swing it.
STRONG_MIN_ANSWERS, STRONG_ACCURACY = 10, 0.75
NEEDS_WORK_MIN_ANSWERS, NEEDS_WORK_ACCURACY = 5, 0.5


def chapter_label(answered: int, correct: int) -> Literal["strong", "needs_work"] | None:
    smoothed = (correct + 2) / (answered + 4)
    if answered >= STRONG_MIN_ANSWERS and smoothed >= STRONG_ACCURACY:
        return "strong"
    if answered >= NEEDS_WORK_MIN_ANSWERS and smoothed <= NEEDS_WORK_ACCURACY:
        return "needs_work"
    return None


async def continue_session(
    db: AsyncSession, user_id: uuid.UUID, *, now: datetime
) -> ContinueOut | None:
    """The latest unfinished session that can still take answers."""
    candidates = await db.scalars(
        select(PracticeSession)
        .where(
            PracticeSession.user_id == user_id,
            PracticeSession.finished_at.is_(None),
            PracticeSession.expires_at > now,
        )
        .order_by(PracticeSession.created_at.desc())
        .limit(5)
    )
    for session in candidates:
        deadline = challenge_deadline(session)
        if deadline is not None and deadline <= now:
            continue  # a challenge whose time is up can't be resumed
        answered = await db.scalar(
            select(func.count()).where(PracticeAnswer.session_id == session.id)
        )
        return ContinueOut(
            session_id=session.id,
            title=session.title,
            answered=answered or 0,
            count=len(session.question_ids),
        )
    return None


async def build_progress(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, goal: str, now: datetime
) -> ProgressOut:
    subjects = await goal_subjects(db, goal)
    subject_ids = [subject.id for subject in subjects]
    chapters = (
        await db.scalars(
            select(Chapter)
            .where(Chapter.subject_id.in_(subject_ids), Chapter.is_active)
            .order_by(Chapter.sort, Chapter.id)
        )
    ).all()
    chapter_stats = {
        stats.chapter_id: stats
        for stats in await db.scalars(
            select(UserChapterStats).where(
                UserChapterStats.user_id == user_id,
                UserChapterStats.chapter_id.in_([chapter.id for chapter in chapters]),
            )
        )
    }
    # Every answer in a subject counts, passage questions included.
    subject_totals = {
        subject_id: (answered, correct)
        for subject_id, answered, correct in await db.execute(
            select(
                UserCategoryStats.subject_id,
                func.sum(UserCategoryStats.attempts),
                func.sum(UserCategoryStats.correct),
            )
            .where(
                UserCategoryStats.user_id == user_id,
                UserCategoryStats.subject_id.in_(subject_ids),
            )
            .group_by(UserCategoryStats.subject_id)
        )
    }
    out = []
    for subject in subjects:
        rows = []
        for chapter in chapters:
            if chapter.subject_id != subject.id:
                continue
            stats = chapter_stats.get(chapter.id)
            answered, correct = (stats.attempts, stats.correct) if stats else (0, 0)
            rows.append(
                ChapterProgressOut(
                    slug=chapter.slug,
                    answered=answered,
                    correct=correct,
                    seen=stats.seen if stats else 0,
                    label=chapter_label(answered, correct),
                )
            )
        answered, correct = subject_totals.get(subject.id, (0, 0))
        out.append(
            SubjectProgressOut(slug=subject.slug, answered=answered, correct=correct, chapters=rows)
        )
    due, _ = await review_counts(db, user_id, goal=goal, now=now)
    return ProgressOut(
        subjects=out,
        reviews_due=due,
        continue_=await continue_session(db, user_id, now=now),
        tip=await top_tip(db, redis, user_id, goal=goal, now=now),
    )


class HistoryCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


async def practice_history(
    db: AsyncSession, user_id: uuid.UUID, *, cursor: str | None, limit: int, now: datetime
) -> HistoryOut:
    """The user's sessions of the last ``HISTORY_DAYS`` days, newest first."""
    statement = (
        select(PracticeSession)
        .where(
            PracticeSession.user_id == user_id,
            PracticeSession.created_at > now - timedelta(days=HISTORY_DAYS),
        )
        .order_by(PracticeSession.created_at.desc(), PracticeSession.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, HistoryCursor)
        statement = statement.where(
            tuple_(PracticeSession.created_at, PracticeSession.id)
            < tuple_(position.at, position.id)
        )
    sessions = (await db.scalars(statement)).all()
    page = sessions[:limit]
    totals = {
        session_id: (answered, correct, wrong)
        for session_id, answered, correct, wrong in await db.execute(
            select(
                PracticeAnswer.session_id,
                func.count(),
                func.count().filter(PracticeAnswer.outcome == Outcome.CORRECT.value),
                func.count().filter(PracticeAnswer.outcome == Outcome.WRONG.value),
            )
            .where(PracticeAnswer.session_id.in_([session.id for session in page]))
            .group_by(PracticeAnswer.session_id)
        )
    }
    items = []
    for session in page:
        answered, correct, wrong = totals.get(session.id, (0, 0, 0))
        neet = session.settings.get("marking") == "neet"
        items.append(
            HistoryItemOut(
                session_id=session.id,
                mode=session.mode,
                title=session.title,
                created_at=session.created_at,
                finished_at=session.finished_at,
                answered=answered,
                correct=correct,
                score=NEET_CORRECT * correct + NEET_WRONG * wrong if neet else None,
                max_score=NEET_CORRECT * len(session.question_ids) if neet else None,
            )
        )
    next_cursor = None
    if len(sessions) > limit:
        last = page[-1]
        next_cursor = encode_cursor(HistoryCursor(at=last.created_at, id=last.id))
    return HistoryOut(items=items, next_cursor=next_cursor)
