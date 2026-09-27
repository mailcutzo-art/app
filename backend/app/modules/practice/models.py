"""Practice sessions, answer records and each user's per-question state and running totals.

See ``docs/data-model.md`` ("Answers" and "Per-user progress").
"""

import uuid
from datetime import date, datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    ForeignKey,
    Index,
    SmallInteger,
    Uuid,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of
from app.core.ids import new_id
from app.modules.content.models import Category


class PracticeMode(StrEnum):
    CHAPTER = "chapter"
    TOPIC = "topic"
    CATEGORY = "category"
    REVIEW = "review"
    BOOKMARKS = "bookmarks"
    CHALLENGE = "challenge"
    PASSAGE = "passage"


class AttemptMode(StrEnum):
    """``question_attempts.mode``: the practice modes, then the live game kinds."""

    CHAPTER = "chapter"
    TOPIC = "topic"
    CATEGORY = "category"
    CHALLENGE = "challenge"
    REVIEW = "review"
    BOOKMARKS = "bookmarks"
    FUN_LEARN = "fun_learn"
    QUICK_RATED = "quick_rated"
    QUICK_CASUAL = "quick_casual"
    BOT = "bot"
    FRIEND = "friend"
    GROUP = "group"
    TOURNAMENT = "tournament"


class Outcome(StrEnum):
    CORRECT = "correct"
    WRONG = "wrong"
    SKIPPED = "skipped"
    TIMEOUT = "timeout"


SPEEDS = ("fast", "slow", "even")
SPEED_BASES = ("opponents", "typical")
_OUTCOMES = [outcome.value for outcome in Outcome]
_CATEGORY_CHECK = one_of("category", [category.value for category in Category])


class PracticeSession(Base):
    __tablename__ = "practice_sessions"
    __table_args__ = (
        CheckConstraint(one_of("mode", [mode.value for mode in PracticeMode]), name="mode"),
        CheckConstraint(
            "cardinality(question_ids) BETWEEN 1 AND 50"
            " AND array_length(option_orders, 1) = cardinality(question_ids)",
            name="questions",
        ),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    mode: Mapped[str]
    subject_id: Mapped[int | None] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    passage_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("passages.id"))
    title: Mapped[str]
    settings: Mapped[dict[str, Any]]  # the validated request
    question_ids: Mapped[list[uuid.UUID]] = mapped_column(ARRAY(Uuid))  # in order
    # Display order of the authored options for each question, so a resumed session looks
    # the same: [[2, 0, 3, 1], ...].
    option_orders: Mapped[list[list[int]]] = mapped_column(ARRAY(SmallInteger, dimensions=2))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    expires_at: Mapped[datetime]
    finished_at: Mapped[datetime | None]


# "Continue practice": the user's latest unfinished session.
Index(
    "ix_practice_sessions_open",
    PracticeSession.user_id,
    PracticeSession.created_at.desc(),
    postgresql_where=text("finished_at IS NULL"),
)
# The worker closes sessions past their expiry.
Index(
    "ix_practice_sessions_expiring",
    PracticeSession.expires_at,
    postgresql_where=text("finished_at IS NULL"),
)


class PracticeAnswer(Base):
    """The first answer per question of a practice session (read back when resuming)."""

    __tablename__ = "practice_answers"
    __table_args__ = (
        CheckConstraint(one_of("outcome", _OUTCOMES), name="outcome"),
        CheckConstraint("selected_option BETWEEN 0 AND 3", name="selected_option"),
        CheckConstraint("time_ms >= 0", name="time_ms"),
    )

    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("practice_sessions.id", ondelete="CASCADE"), primary_key=True
    )
    position: Mapped[int] = mapped_column(SmallInteger, primary_key=True)  # from 1
    question_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("questions.id"))
    client_answer_id: Mapped[str]
    selected_option: Mapped[int | None] = mapped_column(SmallInteger)  # authored index
    outcome: Mapped[str]
    time_ms: Mapped[int]
    answer_changes: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    answered_at: Mapped[datetime]


class AttemptKey(Base):
    """Claims the app's answer id, so retries and offline re-uploads never count twice."""

    __tablename__ = "attempt_keys"
    __table_args__ = (Index("ix_attempt_keys_created_at", "created_at"),)

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    client_answer_id: Mapped[str] = mapped_column(primary_key=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class QuestionAttempt(Base):
    """One row per answer in every mode. Partitioned by month on ``answered_at``.

    Subject, chapter, topic, category and difficulty are copied from the question when it is
    answered, so grouping needs no joins and history stays stable if content is reorganised.
    Partitions are created by ``ensure_attempt_partitions()`` (migration 0003, then the worker).
    """

    __tablename__ = "question_attempts"
    __table_args__ = (
        CheckConstraint(one_of("mode", [mode.value for mode in AttemptMode]), name="mode"),
        CheckConstraint(one_of("outcome", _OUTCOMES), name="outcome"),
        CheckConstraint(one_of("speed", SPEEDS), name="speed"),
        CheckConstraint(one_of("speed_basis", SPEED_BASES), name="speed_basis"),
        CheckConstraint(_CATEGORY_CHECK, name="category"),
        CheckConstraint("difficulty BETWEEN 1 AND 5", name="difficulty"),
        CheckConstraint("selected_option BETWEEN 0 AND 3", name="selected_option"),
        CheckConstraint("time_ms >= 0", name="time_ms"),
        Index("ix_question_attempts_question_answered", "question_id", "answered_at"),
        {"postgresql_partition_by": "RANGE (answered_at)"},
    )

    # A unique key must include the partition key; de-duplication uses attempt_keys instead.
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=new_id)
    answered_at: Mapped[datetime] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    question_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("questions.id"))
    subject_id: Mapped[int] = mapped_column(SmallInteger)
    chapter_id: Mapped[int | None]
    topic_id: Mapped[int | None]
    category: Mapped[str]
    difficulty: Mapped[int] = mapped_column(SmallInteger)
    mode: Mapped[str]
    session_id: Mapped[uuid.UUID]  # the practice session or the match
    position: Mapped[int] = mapped_column(SmallInteger)
    selected_option: Mapped[int | None] = mapped_column(SmallInteger)  # authored index
    outcome: Mapped[str]
    time_ms: Mapped[int]
    time_limit_ms: Mapped[int | None]
    speed: Mapped[str | None]
    speed_basis: Mapped[str | None]
    peer_time_ms: Mapped[int | None]
    answer_changes: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    first_try: Mapped[bool]
    points: Mapped[int | None] = mapped_column(SmallInteger)
    ist_day: Mapped[date]


# Recent answers per user (tips read the last 30 days).
Index(
    "ix_question_attempts_user_answered",
    QuestionAttempt.user_id,
    QuestionAttempt.answered_at.desc(),
)


class UserQuestion(Base):
    """One row per user and question they have met: seen, review box and bookmark."""

    __tablename__ = "user_questions"
    __table_args__ = (
        CheckConstraint(one_of("last_outcome", _OUTCOMES), name="last_outcome"),
        CheckConstraint("review_box BETWEEN 1 AND 5", name="review_box"),
        CheckConstraint("(review_box IS NULL) = (review_due_at IS NULL)", name="review"),
        Index(
            "ix_user_questions_review_due",
            "user_id",
            "review_due_at",
            postgresql_where=text("review_box IS NOT NULL"),
        ),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    question_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("questions.id"), primary_key=True)
    # NULL while the question is only bookmarked, never answered.
    first_at: Mapped[datetime | None]
    last_at: Mapped[datetime | None]
    attempts: Mapped[int] = mapped_column(server_default=text("0"))
    correct: Mapped[int] = mapped_column(server_default=text("0"))
    last_outcome: Mapped[str | None]
    review_box: Mapped[int | None] = mapped_column(SmallInteger)  # Leitner box 1-5
    review_due_at: Mapped[datetime | None]
    bookmarked_at: Mapped[datetime | None]


Index(
    "ix_user_questions_bookmarks",
    UserQuestion.user_id,
    UserQuestion.bookmarked_at.desc(),
    postgresql_where=text("bookmarked_at IS NOT NULL"),
)


class _Totals:
    """Columns shared by the topic, chapter and category running totals."""

    attempts: Mapped[int] = mapped_column(server_default=text("0"))
    correct: Mapped[int] = mapped_column(server_default=text("0"))
    time_ms: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    correct_time_ms: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    last_at: Mapped[datetime]
    # Speed against opponents in live games.
    fast: Mapped[int] = mapped_column(server_default=text("0"))
    slow: Mapped[int] = mapped_column(server_default=text("0"))
    even: Mapped[int] = mapped_column(server_default=text("0"))
    # Against the question's typical time: the average of ln(time / typical) says how much
    # slower or faster than other students.
    typical_compared: Mapped[int] = mapped_column(server_default=text("0"))
    typical_log_ratio_sum: Mapped[float] = mapped_column(server_default=text("0"))
    fast_wrong: Mapped[int] = mapped_column(server_default=text("0"))
    # Difficulty 1-2.
    easy_attempts: Mapped[int] = mapped_column(server_default=text("0"))
    easy_correct: Mapped[int] = mapped_column(server_default=text("0"))


class UserTopicStats(_Totals, Base):
    __tablename__ = "user_topic_stats"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    topic_id: Mapped[int] = mapped_column(ForeignKey("topics.id"), primary_key=True)


class UserChapterStats(_Totals, Base):
    __tablename__ = "user_chapter_stats"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    chapter_id: Mapped[int] = mapped_column(ForeignKey("chapters.id"), primary_key=True)
    seen: Mapped[int] = mapped_column(server_default=text("0"))  # distinct questions answered


class UserCategoryStats(_Totals, Base):
    __tablename__ = "user_category_stats"
    __table_args__ = (CheckConstraint(_CATEGORY_CHECK, name="category"),)

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    subject_id: Mapped[int] = mapped_column(
        SmallInteger, ForeignKey("subjects.id"), primary_key=True
    )
    category: Mapped[str] = mapped_column(primary_key=True)


class UserDailyStats(Base):
    """Answers per IST day and subject: streaks, missions and this-week comparisons."""

    __tablename__ = "user_daily_stats"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    day: Mapped[date] = mapped_column(primary_key=True)  # in India time
    subject_id: Mapped[int] = mapped_column(
        SmallInteger, ForeignKey("subjects.id"), primary_key=True
    )
    attempts: Mapped[int] = mapped_column(server_default=text("0"))
    correct: Mapped[int] = mapped_column(server_default=text("0"))
    time_ms: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    last_at: Mapped[datetime]
