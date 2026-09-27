"""Questions as clients see them: with subject, chapter and topic names, and bookmark state."""

import uuid
from collections.abc import Collection, Sequence
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import BattlePool, Chapter, ContentStatus, Question, Subject, Topic
from app.modules.content.refs import question_ref
from app.modules.content.schemas import NamedRef, OptionOut, QuestionOut, QuestionSummaryOut
from app.modules.practice.models import UserQuestion

AUTHORED_ORDER = (0, 1, 2, 3)


@dataclass(frozen=True, slots=True)
class QuestionView:
    question: Question
    subject: str  # slug
    chapter: NamedRef | None
    topic: NamedRef | None

    def fields(self, *, bookmarked: bool, order: Sequence[int] = AUTHORED_ORDER) -> dict[str, Any]:
        """``QuestionOut`` fields; ``order`` lists the authored option indexes in display order."""
        q = self.question
        return {
            "ref": question_ref(q.id),
            "stem": q.stem,
            "options": [OptionOut(id=index, text=q.options[index]) for index in order],
            "answer": q.answer,
            "explanation": q.explanation,
            "difficulty": q.difficulty,
            "category": q.category,
            "chapter": self.chapter,
            "topic": self.topic,
            "bookmarked": bookmarked,
        }

    def out(self, *, bookmarked: bool) -> QuestionOut:
        """The full question with its options in authored order."""
        return QuestionOut(**self.fields(bookmarked=bookmarked))

    def summary(self) -> QuestionSummaryOut:
        return QuestionSummaryOut(
            ref=question_ref(self.question.id),
            stem=self.question.stem,
            subject=self.subject,
            chapter=self.chapter,
            topic=self.topic,
        )


async def load_views(db: AsyncSession, ids: Collection[uuid.UUID]) -> dict[uuid.UUID, QuestionView]:
    """The questions with these ids (in any status), by id."""
    if not ids:
        return {}
    rows = await db.execute(
        select(Question, Subject.slug, Chapter.slug, Chapter.name, Topic.slug, Topic.name)
        .join(Subject, Subject.id == Question.subject_id)
        .outerjoin(Chapter, Chapter.id == Question.chapter_id)
        .outerjoin(Topic, Topic.id == Question.topic_id)
        .where(Question.id.in_(list(ids)))
    )
    views = {}
    for question, subject, chapter_slug, chapter_name, topic_slug, topic_name in rows:
        views[question.id] = QuestionView(
            question=question,
            subject=subject,
            chapter=NamedRef(slug=chapter_slug, name=chapter_name) if chapter_slug else None,
            topic=NamedRef(slug=topic_slug, name=topic_name) if topic_slug else None,
        )
    return views


async def bookmarked_ids(
    db: AsyncSession, user_id: uuid.UUID, ids: Collection[uuid.UUID]
) -> set[uuid.UUID]:
    if not ids:
        return set()
    rows = await db.scalars(
        select(UserQuestion.question_id).where(
            UserQuestion.user_id == user_id,
            UserQuestion.question_id.in_(list(ids)),
            UserQuestion.bookmarked_at.is_not(None),
        )
    )
    return set(rows)


def openly_visible(question: Question) -> bool:
    """Anyone may look at published questions that are not reserved for battles."""
    return (
        question.status == ContentStatus.PUBLISHED and question.battle_pool != BattlePool.RESERVED
    )


async def visible_view(
    db: AsyncSession, user_id: uuid.UUID, question_id: uuid.UUID
) -> QuestionView | None:
    """The question if the user may see it: openly visible, or one they already met (answered
    or bookmarked, e.g. a battle question or a version since retired)."""
    view = (await load_views(db, [question_id])).get(question_id)
    if view is None or openly_visible(view.question):
        return view
    met = await db.scalar(
        select(UserQuestion.question_id).where(
            UserQuestion.user_id == user_id, UserQuestion.question_id == question_id
        )
    )
    return view if met is not None else None
