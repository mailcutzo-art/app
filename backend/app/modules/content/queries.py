"""Query building blocks shared by the catalog, practice selection and search."""

from sqlalchemy import ColumnElement, ScalarSelect, and_, any_, or_, select

from app.modules.content.models import (
    EASY_MAX_DIFFICULTY,
    BattlePool,
    ContentStatus,
    ExamGoal,
    GoalSubject,
    Question,
)

# Practice difficulty filters: easy is 1-2, medium 3 and hard 4-5.
DIFFICULTY_RANGES: dict[str, tuple[int, int]] = {
    "easy": (1, EASY_MAX_DIFFICULTY),
    "medium": (3, 3),
    "hard": (4, 5),
}


def subjects_of_goal(goal: str) -> ScalarSelect[int]:
    """The ids of the exam's subjects, for ``column.in_(...)``."""
    return (
        select(GoalSubject.subject_id)
        .join(ExamGoal, ExamGoal.id == GoalSubject.goal_id)
        .where(ExamGoal.slug == goal)
        .scalar_subquery()
    )


def suits_goal(goal: str) -> ColumnElement[bool]:
    """Questions this exam's players can get.

    The subject must belong to the exam, and the question either names no exams (every exam
    that includes the subject) or names this one.
    """
    return and_(
        Question.subject_id.in_(subjects_of_goal(goal)),
        or_(Question.exams.is_(None), any_(Question.exams) == goal),
    )


def practice_pool() -> ColumnElement[bool]:
    """Published questions that practice may serve: never those reserved for battles."""
    return and_(
        Question.status == ContentStatus.PUBLISHED.value,
        Question.battle_pool != BattlePool.RESERVED.value,
    )


def difficulty_filter(difficulty: str) -> ColumnElement[bool] | None:
    """``None`` for "mixed"."""
    bounds = DIFFICULTY_RANGES.get(difficulty)
    return Question.difficulty.between(*bounds) if bounds else None
