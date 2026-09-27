"""The question bank: exams, subjects, chapters, topics, questions, passages and word puzzles.

Published questions are never edited: a correction is a new row pointing at the old one through
``supersedes_id``, and the old row is retired, so past answers keep pointing at exactly what was
asked. See ``docs/data-model.md``.
"""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Identity,
    Index,
    SmallInteger,
    Text,
    UniqueConstraint,
    func,
    text,
    true,
)
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, TimestampMixin, UUIDv7Pk, one_of


class QuestionKind(StrEnum):
    MCQ_SINGLE = "mcq_single"
    PASSAGE_MCQ = "passage_mcq"


class Category(StrEnum):
    """What kind of thinking a question tests (see ``docs/content-format.md``)."""

    CONCEPT = "concept"
    NUMERICAL = "numerical"
    FACTUAL = "factual"
    APPLICATION = "application"


class BattlePool(StrEnum):
    NONE = "none"  # practice only
    SHARED = "shared"  # practice and battles
    RESERVED = "reserved"  # battles only, never sent to practice


class ContentStatus(StrEnum):
    DRAFT = "draft"
    REVIEW = "review"
    PUBLISHED = "published"
    RETIRED = "retired"


class ReportReason(StrEnum):
    WRONG_ANSWER = "wrong_answer"
    TYPO = "typo"
    UNCLEAR = "unclear"
    OTHER = "other"


class ReportStatus(StrEnum):
    OPEN = "open"
    RESOLVED = "resolved"
    DISMISSED = "dismissed"


class ContentSource(StrEnum):
    """Where a row came from, so the seed only retires what the content files own."""

    CONTENT = "content"  # the YAML files in content/, loaded by the seed command
    IMPORT = "import"  # admin imports (later)


EXAMS = ("neet", "jee")
TONES = ("sky", "mint", "lemon", "lavender", "peach", "rose", "lime")
# Difficulty 1-2 counts as easy, 3 as medium and 4-5 as hard.
EASY_MAX_DIFFICULTY = 2


class ExamGoal(Base):
    """An exam students prepare for (NEET, JEE); ``users.goal`` holds its slug."""

    __tablename__ = "goals"

    id: Mapped[int] = mapped_column(SmallInteger, Identity(), primary_key=True)
    slug: Mapped[str] = mapped_column(unique=True)
    name: Mapped[str]


class Subject(Base):
    __tablename__ = "subjects"
    __table_args__ = (CheckConstraint(one_of("tone", TONES), name="tone"),)

    id: Mapped[int] = mapped_column(SmallInteger, Identity(), primary_key=True)
    slug: Mapped[str] = mapped_column(unique=True)
    name: Mapped[str]
    tone: Mapped[str]  # the pastel colour of the subject tile
    icon: Mapped[str]
    sort: Mapped[int] = mapped_column(SmallInteger)


class GoalSubject(Base):
    """Which subjects an exam includes (Physics and Chemistry belong to both)."""

    __tablename__ = "goal_subjects"

    goal_id: Mapped[int] = mapped_column(
        SmallInteger, ForeignKey("goals.id", ondelete="CASCADE"), primary_key=True
    )
    subject_id: Mapped[int] = mapped_column(
        SmallInteger, ForeignKey("subjects.id", ondelete="CASCADE"), primary_key=True
    )


class Chapter(Base):
    __tablename__ = "chapters"
    __table_args__ = (UniqueConstraint("subject_id", "slug"),)

    id: Mapped[int] = mapped_column(Identity(), primary_key=True)
    subject_id: Mapped[int] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    slug: Mapped[str]
    name: Mapped[str]
    sort: Mapped[int] = mapped_column(SmallInteger)
    is_active: Mapped[bool] = mapped_column(server_default=true())


class Topic(Base):
    """The smallest unit a student revises on its own; what coach tips talk about."""

    __tablename__ = "topics"
    __table_args__ = (UniqueConstraint("chapter_id", "slug"),)

    id: Mapped[int] = mapped_column(Identity(), primary_key=True)
    chapter_id: Mapped[int] = mapped_column(ForeignKey("chapters.id"))
    slug: Mapped[str]
    name: Mapped[str]
    sort: Mapped[int] = mapped_column(SmallInteger)
    # Topics dropped from the content files stay for history (answers point at them).
    is_active: Mapped[bool] = mapped_column(server_default=true())


_STATUS_CHECK = one_of("status", [status.value for status in ContentStatus])
_SOURCE_CHECK = one_of("source", [source.value for source in ContentSource])


class Passage(TimestampMixin, Base):
    """A Fun & Learn text; its questions are ``questions`` rows of kind ``passage_mcq``."""

    __tablename__ = "passages"
    __table_args__ = (
        CheckConstraint("difficulty BETWEEN 1 AND 5", name="difficulty"),
        CheckConstraint(_STATUS_CHECK, name="status"),
        CheckConstraint(_SOURCE_CHECK, name="source"),
    )

    id: Mapped[UUIDv7Pk]
    external_id: Mapped[str] = mapped_column(unique=True)
    subject_id: Mapped[int] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    chapter_id: Mapped[int | None] = mapped_column(ForeignKey("chapters.id"))
    title: Mapped[str]
    body: Mapped[str]
    difficulty: Mapped[int] = mapped_column(SmallInteger)
    status: Mapped[str]
    source: Mapped[str]


class Question(TimestampMixin, Base):
    __tablename__ = "questions"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in QuestionKind]), name="kind"),
        CheckConstraint(one_of("category", [c.value for c in Category]), name="category"),
        CheckConstraint(one_of("battle_pool", [p.value for p in BattlePool]), name="battle_pool"),
        CheckConstraint(_STATUS_CHECK, name="status"),
        CheckConstraint(_SOURCE_CHECK, name="source"),
        CheckConstraint("difficulty BETWEEN 1 AND 5", name="difficulty"),
        CheckConstraint("cardinality(options) = 4", name="options"),
        CheckConstraint("answer BETWEEN 0 AND 3", name="answer"),
        CheckConstraint(
            "exams IS NULL OR (cardinality(exams) > 0 AND exams <@ ARRAY['neet', 'jee']::text[])",
            name="exams",
        ),
        # Passage questions (and only they) belong to a passage; every other question has a
        # chapter and a topic.
        CheckConstraint("(kind = 'passage_mcq') = (passage_id IS NOT NULL)", name="passage"),
        CheckConstraint(
            "kind = 'passage_mcq' OR (chapter_id IS NOT NULL AND topic_id IS NOT NULL)",
            name="placement",
        ),
        UniqueConstraint("subject_id", "seq"),
        # Superseded versions keep their external id; only one row per id is ever live.
        Index(
            "uq_questions_external_id_live",
            "external_id",
            unique=True,
            postgresql_where=text("status <> 'retired'"),
        ),
        Index(
            "ix_questions_chapter_difficulty_published",
            "chapter_id",
            "difficulty",
            postgresql_where=text("status = 'published'"),
        ),
        Index(
            "ix_questions_topic_published",
            "topic_id",
            postgresql_where=text("status = 'published'"),
        ),
        Index(
            "ix_questions_battle_published",
            "chapter_id",
            postgresql_where=text("status = 'published' AND battle_pool <> 'none'"),
        ),
        Index(
            "ix_questions_passage_id",
            "passage_id",
            postgresql_where=text("passage_id IS NOT NULL"),
        ),
        Index(
            "ix_questions_search_trgm",
            "search_text",
            postgresql_using="gin",
            postgresql_ops={"search_text": "gin_trgm_ops"},
        ),
        Index(
            "ix_questions_search_fts",
            text("to_tsvector('simple'::regconfig, search_text)"),
            postgresql_using="gin",
        ),
    )

    id: Mapped[UUIDv7Pk]
    external_id: Mapped[str]
    subject_id: Mapped[int] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    chapter_id: Mapped[int | None] = mapped_column(ForeignKey("chapters.id"))
    topic_id: Mapped[int | None] = mapped_column(ForeignKey("topics.id"))
    passage_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("passages.id"))
    kind: Mapped[str]
    category: Mapped[str]
    # Exams the question suits; NULL means every exam that includes the subject.
    exams: Mapped[list[str] | None] = mapped_column(ARRAY(Text))
    difficulty: Mapped[int] = mapped_column(SmallInteger)
    battle_pool: Mapped[str] = mapped_column(server_default=BattlePool.NONE.value)
    status: Mapped[str]
    stem: Mapped[str]
    options: Mapped[list[str]] = mapped_column(ARRAY(Text))  # authored order
    answer: Mapped[int] = mapped_column(SmallInteger)  # index into options
    explanation: Mapped[str]
    tags: Mapped[list[str]] = mapped_column(ARRAY(Text), server_default=text("'{}'"))
    # Stem, options, tags, topic and chapter with the markup stripped (trigram + full-text).
    search_text: Mapped[str]
    # SHA-256 of stem, options and answer: a change makes a new version.
    content_hash: Mapped[str]
    supersedes_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("questions.id"))
    seq: Mapped[int]  # dense per subject
    source: Mapped[str]


class QuestionStats(Base):
    """Per-question figures rebuilt nightly from the answers (no hot counters)."""

    __tablename__ = "question_stats"

    question_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("questions.id", ondelete="CASCADE"), primary_key=True
    )
    attempts: Mapped[int] = mapped_column(server_default=text("0"))
    correct: Mapped[int] = mapped_column(server_default=text("0"))
    # Median time of correct answers over the last 90 days; NULL until there are enough.
    typical_ms: Mapped[int | None]
    timed_correct: Mapped[int] = mapped_column(server_default=text("0"))
    p_correct: Mapped[float | None]
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now())


class WordPuzzle(TimestampMixin, Base):
    """A Guess the Word term (served with the coin economy in a later phase)."""

    __tablename__ = "word_puzzles"
    __table_args__ = (
        CheckConstraint("word ~ '^[A-Z]{3,12}$'", name="word"),
        CheckConstraint("difficulty BETWEEN 1 AND 5", name="difficulty"),
        CheckConstraint(_STATUS_CHECK, name="status"),
        CheckConstraint(_SOURCE_CHECK, name="source"),
    )

    id: Mapped[UUIDv7Pk]
    external_id: Mapped[str] = mapped_column(unique=True)
    subject_id: Mapped[int] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    word: Mapped[str]
    clue: Mapped[str]
    difficulty: Mapped[int] = mapped_column(SmallInteger)
    status: Mapped[str]
    source: Mapped[str]


class QuestionReport(Base):
    """A player's report that a question is wrong or unclear, for moderators to review."""

    __tablename__ = "question_reports"
    __table_args__ = (
        CheckConstraint(one_of("reason", [reason.value for reason in ReportReason]), name="reason"),
        CheckConstraint(one_of("status", [status.value for status in ReportStatus]), name="status"),
        # One open report per player and question; reporting again changes nothing.
        Index(
            "uq_question_reports_open",
            "user_id",
            "question_id",
            unique=True,
            postgresql_where=text("status = 'open'"),
        ),
        Index("ix_question_reports_question_id", "question_id"),
        Index("ix_question_reports_user_created", "user_id", "created_at"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    question_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("questions.id"))
    reason: Mapped[str]
    note: Mapped[str | None]
    status: Mapped[str] = mapped_column(server_default=ReportStatus.OPEN.value)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
