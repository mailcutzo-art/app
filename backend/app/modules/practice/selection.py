"""Choosing a practice session's questions.

Every mode serves only questions suited to the player's exam and never those reserved for
battles. Within what matches, questions the player has never answered come first (in random
order), then those answered longest ago.
"""

import uuid
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import ColumnElement, Select, and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationFailed
from app.modules.content.models import (
    Category,
    Chapter,
    ContentStatus,
    Passage,
    Question,
    QuestionKind,
    Subject,
    Topic,
)
from app.modules.content.queries import difficulty_filter, practice_pool, suits_goal
from app.modules.practice.models import PracticeMode, UserQuestion
from app.modules.practice.schemas import SessionIn

CATEGORY_LABELS = {
    Category.CONCEPT: "Concepts",
    Category.NUMERICAL: "Numericals",
    Category.FACTUAL: "Facts",
    Category.APPLICATION: "Applications",
}
_SUBJECT_MODES = {
    PracticeMode.CHAPTER,
    PracticeMode.TOPIC,
    PracticeMode.CATEGORY,
    PracticeMode.CHALLENGE,
}


@dataclass(frozen=True, slots=True)
class Scope:
    """A validated request resolved against the catalog."""

    mode: PracticeMode
    goal: str
    subject: Subject | None
    chapters: list[Chapter] = field(default_factory=list)
    topic: Topic | None = None
    category: str | None = None
    passage: Passage | None = None

    @property
    def title(self) -> str:
        subject = self.subject.name if self.subject else None
        match self.mode:
            case PracticeMode.CHAPTER:
                if len(self.chapters) == 1:
                    detail: str | None = self.chapters[0].name
                else:
                    detail = f"{len(self.chapters)} chapters" if self.chapters else None
            case PracticeMode.TOPIC:
                detail = self.topic.name if self.topic else None
            case PracticeMode.CATEGORY:
                detail = CATEGORY_LABELS[Category(self.category)] if self.category else None
            case PracticeMode.REVIEW:
                detail = "Review"
            case PracticeMode.BOOKMARKS:
                detail = "Bookmarks"
            case PracticeMode.CHALLENGE:
                detail = "Self Challenge"
            case PracticeMode.PASSAGE:
                return f"Fun & Learn · {self.passage.title}" if self.passage else "Fun & Learn"
        return " · ".join(part for part in (subject, detail) if part) or "Practice"


def _mode_problems(body: SessionIn) -> dict[str, str]:
    """Fields that are missing for, or don't apply to, the requested mode."""
    mode = PracticeMode(body.mode)
    problems: dict[str, str] = {}
    if mode in _SUBJECT_MODES and body.subject is None:
        problems["subject"] = "Choose a subject."
    if mode == PracticeMode.TOPIC and body.topic is None:
        problems["topic"] = "Choose a topic."
    elif mode != PracticeMode.TOPIC and body.topic is not None:
        problems["topic"] = "A topic is only used for topic practice."
    if mode == PracticeMode.CATEGORY and body.category is None:
        problems["category"] = "Choose a question type."
    elif mode != PracticeMode.CATEGORY and body.category is not None:
        problems["category"] = "A question type is only used for question-type practice."
    if mode not in {PracticeMode.CHAPTER, PracticeMode.CHALLENGE} and body.chapters:
        problems["chapters"] = "Chapters are only used for chapter practice and Self Challenge."
    elif len(set(body.chapters)) != len(body.chapters):
        problems["chapters"] = "List each chapter once."
    if mode == PracticeMode.CHALLENGE and body.time_limit_s is None:
        problems["time_limit_s"] = "Choose a time limit."
    elif mode != PracticeMode.CHALLENGE and body.time_limit_s is not None:
        problems["time_limit_s"] = "A total time limit is only used for Self Challenge."
    if mode == PracticeMode.CHALLENGE and body.timed:
        problems["timed"] = "Self Challenge has one time limit for the whole set."
    elif body.timed and body.per_question_s is None:
        problems["per_question_s"] = "Choose the time per question."
    elif not body.timed and body.per_question_s is not None:
        problems["per_question_s"] = "Turn on timed practice to set a time per question."
    if mode == PracticeMode.PASSAGE and body.passage_id is None:
        problems["passage_id"] = "Choose a passage."
    elif mode != PracticeMode.PASSAGE and body.passage_id is not None:
        problems["passage_id"] = "A passage is only used for Fun & Learn."
    return problems


async def resolve_scope(db: AsyncSession, body: SessionIn, *, goal: str) -> Scope:
    """Check the request against its mode and the catalog; 422 with every problem found."""
    problems = _mode_problems(body)
    subject = None
    if body.subject is not None:
        subject = await db.scalar(select(Subject).where(Subject.slug == body.subject))
        if subject is None:
            problems["subject"] = "Choose a subject from the list."
    chapters: list[Chapter] = []
    if subject is not None and body.chapters and "chapters" not in problems:
        found = {
            chapter.slug: chapter
            for chapter in await db.scalars(
                select(Chapter).where(
                    Chapter.subject_id == subject.id,
                    Chapter.slug.in_(body.chapters),
                    Chapter.is_active,
                )
            )
        }
        if len(found) != len(body.chapters):
            problems["chapters"] = f"Choose chapters of {subject.name}."
        chapters = [found[slug] for slug in body.chapters if slug in found]
    topic = None
    if subject is not None and body.topic is not None and "topic" not in problems:
        topic = await db.scalar(
            select(Topic)
            .join(Chapter, Chapter.id == Topic.chapter_id)
            .where(
                Chapter.subject_id == subject.id,
                Chapter.is_active,
                Topic.slug == body.topic,
                Topic.is_active,
            )
        )
        if topic is None:
            problems["topic"] = f"Choose a topic of {subject.name}."
    passage = None
    if body.passage_id is not None and "passage_id" not in problems:
        passage = await db.scalar(
            select(Passage).where(
                Passage.id == body.passage_id, Passage.status == ContentStatus.PUBLISHED.value
            )
        )
        if passage is None:
            problems["passage_id"] = "This passage isn't available."
        else:
            subject = await db.get(Subject, passage.subject_id)
    if problems:
        raise ValidationFailed(details={"fields": problems})
    return Scope(
        mode=PracticeMode(body.mode),
        goal=goal,
        subject=subject,
        chapters=chapters,
        topic=topic,
        category=body.category,
        passage=passage,
    )


def _seen_first(statement: Select[uuid.UUID]) -> Select[uuid.UUID]:
    """Never-answered questions first (shuffled), then those answered longest ago."""
    return statement.order_by(UserQuestion.last_at.asc().nulls_first(), func.random())


async def select_questions(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    scope: Scope,
    body: SessionIn,
    now: datetime,
) -> list[uuid.UUID]:
    """The question ids for a new session, in order (at most ``body.count``)."""
    mine = and_(UserQuestion.question_id == Question.id, UserQuestion.user_id == user_id)
    conditions: list[ColumnElement[bool]] = [practice_pool(), suits_goal(scope.goal)]
    if scope.passage is not None:  # Fun & Learn: the passage's questions as authored
        statement = (
            select(Question.id)
            .where(Question.passage_id == scope.passage.id, *conditions)
            .order_by(Question.external_id)
        )
        return list(await db.scalars(statement))

    conditions.append(Question.kind == QuestionKind.MCQ_SINGLE.value)
    if scope.subject is not None:
        conditions.append(Question.subject_id == scope.subject.id)
    if (difficulty := difficulty_filter(body.difficulty)) is not None:
        conditions.append(difficulty)
    if scope.chapters:
        conditions.append(Question.chapter_id.in_([chapter.id for chapter in scope.chapters]))
    if scope.topic is not None:
        conditions.append(Question.topic_id == scope.topic.id)
    if scope.category is not None:
        conditions.append(Question.category == scope.category)

    if scope.mode == PracticeMode.REVIEW:
        statement = (
            select(Question.id)
            .join(UserQuestion, mine)
            .where(
                *conditions,
                UserQuestion.review_box.is_not(None),
                UserQuestion.review_due_at <= now,
            )
            .order_by(UserQuestion.review_due_at, Question.id)
        )
    elif scope.mode == PracticeMode.BOOKMARKS:
        statement = _seen_first(
            select(Question.id)
            .join(UserQuestion, mine)
            .where(*conditions, UserQuestion.bookmarked_at.is_not(None))
        )
    else:
        statement = _seen_first(
            select(Question.id).outerjoin(UserQuestion, mine).where(*conditions)
        )
        if body.unseen_only:
            statement = statement.where(func.coalesce(UserQuestion.attempts, 0) == 0)
    return list(await db.scalars(statement.limit(body.count)))
