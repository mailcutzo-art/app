"""What the coach's tip rules read, aggregated from the database.

Per area (topic, chapter, or a subject's category): answers from the last 30 days, or all-time
running totals where the area has too little recent data. Plus the counts the unlock and review
tips need, and the exam's chapters the player hasn't tried.
"""

import math
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Literal

from sqlalchemy import ColumnElement, Float, and_, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import (
    EASY_MAX_DIFFICULTY,
    Chapter,
    Subject,
    Topic,
)
from app.modules.content.queries import subjects_of_goal
from app.modules.practice.models import (
    Outcome,
    QuestionAttempt,
    UserCategoryStats,
    UserChapterStats,
    UserTopicStats,
)
from app.modules.practice.reviews import review_counts

RECENT = timedelta(days=30)
# An area with fewer recent answers than this falls back to its all-time totals.
MIN_RECENT_ANSWERS = 5

AreaKind = Literal["topic", "chapter", "category"]


@dataclass(frozen=True, slots=True)
class AreaStats:
    kind: AreaKind
    subject: str  # subject slug
    subject_name: str
    key: str  # topic or chapter slug, or the category
    name: str  # topic or chapter name, or the category
    chapter: str | None  # the chapter slug, for topics
    attempts: int
    correct: int
    fast: int  # against opponents
    slow: int
    even: int
    typical_compared: int
    typical_ratio: float | None  # geometric mean of time / typical time
    fast_wrong: int
    easy_attempts: int
    easy_correct: int
    recent: bool  # from the last 30 days rather than all-time totals


@dataclass(frozen=True, slots=True)
class UntriedChapter:
    subject: str
    slug: str
    name: str


@dataclass(frozen=True, slots=True)
class CoachData:
    total_answers: int  # all-time, for unlocking tips
    areas: list[AreaStats]
    reviews_due: int
    untried_chapters: list[UntriedChapter]


_COUNTERS = (
    "attempts",
    "correct",
    "fast",
    "slow",
    "even",
    "typical_compared",
    "fast_wrong",
    "easy_attempts",
    "easy_correct",
)


def _recent_columns() -> list[ColumnElement[Any]]:
    """Aggregates over question_attempts matching the running-total columns."""
    a = QuestionAttempt
    correct = a.outcome == Outcome.CORRECT.value
    opponents = a.speed_basis == "opponents"
    typical = and_(a.speed_basis == "typical", a.peer_time_ms > 0)
    easy = a.difficulty <= EASY_MAX_DIFFICULTY
    log_ratio = func.ln(cast(func.greatest(a.time_ms, 1), Float) / a.peer_time_ms)
    return [
        func.count().label("attempts"),
        func.count().filter(correct).label("correct"),
        func.count().filter(opponents, a.speed == "fast").label("fast"),
        func.count().filter(opponents, a.speed == "slow").label("slow"),
        func.count().filter(opponents, a.speed == "even").label("even"),
        func.count().filter(typical).label("typical_compared"),
        func.sum(log_ratio).filter(typical).label("log_ratio_sum"),
        func.count()
        .filter(a.speed == "fast", a.outcome == Outcome.WRONG.value)
        .label("fast_wrong"),
        func.count().filter(easy).label("easy_attempts"),
        func.count().filter(easy, correct).label("easy_correct"),
    ]


def _ratio(log_ratio_sum: float | None, compared: int) -> float | None:
    return math.exp(log_ratio_sum / compared) if compared and log_ratio_sum is not None else None


def _counts(row: Any) -> dict[str, Any]:
    return {name: int(getattr(row, name) or 0) for name in _COUNTERS}


async def load_coach_data(
    db: AsyncSession, user_id: uuid.UUID, *, goal: str, now: datetime
) -> CoachData:
    subject_ids = subjects_of_goal(goal)
    since = now - RECENT
    mine = QuestionAttempt.user_id == user_id
    recent_filter = [mine, QuestionAttempt.answered_at >= since]

    subjects = {
        subject.id: subject
        for subject in await db.scalars(select(Subject).where(Subject.id.in_(subject_ids)))
    }
    chapters = {
        chapter.id: chapter
        for chapter in await db.scalars(
            select(Chapter).where(Chapter.subject_id.in_(subject_ids), Chapter.is_active)
        )
    }
    topics = {
        topic.id: topic
        for topic in await db.scalars(
            select(Topic).where(Topic.chapter_id.in_(list(chapters)), Topic.is_active)
        )
    }

    areas: list[AreaStats] = []
    # Topics.
    recent_topics = {
        row.topic_id: row
        for row in await db.execute(
            select(QuestionAttempt.topic_id, *_recent_columns())
            .where(*recent_filter, QuestionAttempt.topic_id.in_(list(topics)))
            .group_by(QuestionAttempt.topic_id)
        )
    }
    all_time_topics = {
        row.topic_id: row
        for row in await db.scalars(
            select(UserTopicStats).where(
                UserTopicStats.user_id == user_id, UserTopicStats.topic_id.in_(list(topics))
            )
        )
    }
    for topic_id, topic_totals in all_time_topics.items():
        topic = topics[topic_id]
        chapter = chapters[topic.chapter_id]
        areas.append(
            _area(
                "topic",
                subjects[chapter.subject_id],
                topic.slug,
                topic.name,
                chapter.slug,
                recent_topics.get(topic_id),
                topic_totals,
            )
        )
    # Chapters.
    recent_chapters = {
        row.chapter_id: row
        for row in await db.execute(
            select(QuestionAttempt.chapter_id, *_recent_columns())
            .where(*recent_filter, QuestionAttempt.chapter_id.in_(list(chapters)))
            .group_by(QuestionAttempt.chapter_id)
        )
    }
    all_time_chapters = {
        row.chapter_id: row
        for row in await db.scalars(
            select(UserChapterStats).where(
                UserChapterStats.user_id == user_id,
                UserChapterStats.chapter_id.in_(list(chapters)),
            )
        )
    }
    for chapter_id, chapter_totals in all_time_chapters.items():
        chapter = chapters[chapter_id]
        areas.append(
            _area(
                "chapter",
                subjects[chapter.subject_id],
                chapter.slug,
                chapter.name,
                None,
                recent_chapters.get(chapter_id),
                chapter_totals,
            )
        )
    # Categories per subject.
    recent_categories = {
        (row.subject_id, row.category): row
        for row in await db.execute(
            select(QuestionAttempt.subject_id, QuestionAttempt.category, *_recent_columns())
            .where(*recent_filter, QuestionAttempt.subject_id.in_(list(subjects)))
            .group_by(QuestionAttempt.subject_id, QuestionAttempt.category)
        )
    }
    for category_totals in await db.scalars(
        select(UserCategoryStats).where(
            UserCategoryStats.user_id == user_id,
            UserCategoryStats.subject_id.in_(list(subjects)),
        )
    ):
        areas.append(
            _area(
                "category",
                subjects[category_totals.subject_id],
                category_totals.category,
                category_totals.category,
                None,
                recent_categories.get((category_totals.subject_id, category_totals.category)),
                category_totals,
            )
        )

    total_answers = await db.scalar(
        select(func.coalesce(func.sum(UserCategoryStats.attempts), 0)).where(
            UserCategoryStats.user_id == user_id
        )
    )
    due, _ = await review_counts(db, user_id, goal=goal, now=now)
    tried = set(all_time_chapters)
    untried = [
        UntriedChapter(subjects[c.subject_id].slug, c.slug, c.name)
        for c in sorted(chapters.values(), key=lambda c: (subjects[c.subject_id].sort, c.sort))
        if c.id not in tried
    ]
    return CoachData(
        total_answers=int(total_answers or 0),
        areas=areas,
        reviews_due=due,
        untried_chapters=untried,
    )


def _area(
    kind: AreaKind,
    subject: Subject,
    key: str,
    name: str,
    chapter: str | None,
    recent: Any,
    totals: UserTopicStats | UserChapterStats | UserCategoryStats,
) -> AreaStats:
    """Recent figures when there are enough of them, else the all-time totals."""
    use_recent = recent is not None and int(recent.attempts) >= MIN_RECENT_ANSWERS
    if use_recent:
        counts = _counts(recent)
        ratio = _ratio(recent.log_ratio_sum, counts["typical_compared"])
    else:
        counts = _counts(totals)
        ratio = _ratio(totals.typical_log_ratio_sum, totals.typical_compared)
    return AreaStats(
        kind=kind,
        subject=subject.slug,
        subject_name=subject.name,
        key=key,
        name=name,
        chapter=chapter,
        typical_ratio=ratio,
        recent=use_recent,
        **counts,
    )


def by_kind(data: CoachData, kind: AreaKind) -> Sequence[AreaStats]:
    return [area for area in data.areas if area.kind == kind]
