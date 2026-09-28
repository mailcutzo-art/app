"""Choosing a battle's questions and hiding their answers behind fresh option ids.

- Only published single-answer questions with ``battle_pool <> 'none'``, from the source
  chapters (or the whole subject), suited to every player's exam.
- The difficulty mix follows the players' average rating (``rules.difficulty_mix``).
- Questions none of the players has answered come first, in random order, then those answered
  longest ago: a thin chapter repeats questions rather than blocking the match. If a chapter
  runs out altogether, the rest come from the whole subject.
- Options are shuffled and get random 5-character ids; which id is correct is known only to
  Redis and ``match_questions.option_map``.
"""

import secrets
import string
import uuid
from collections.abc import Collection, Sequence
from dataclasses import dataclass

from sqlalchemy import ColumnElement, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import (
    BattlePool,
    Chapter,
    ContentStatus,
    Question,
    QuestionKind,
)
from app.modules.content.queries import suits_goal
from app.modules.practice.models import UserQuestion
from app.modules.realtime.matchmaking.rules import DIFFICULTY_BANDS, difficulty_mix

OPTION_ID_LENGTH = 5
_OPTION_ALPHABET = string.ascii_letters + string.digits
_random = secrets.SystemRandom()


@dataclass(frozen=True, slots=True)
class PickedQuestion:
    question: Question
    chapter: Chapter


@dataclass(frozen=True, slots=True)
class ShuffledOptions:
    ids: list[str]  # the option id shown in each position
    order: list[int]  # the authored index shown in each position
    correct: str  # the correct option's id

    def option_map(self) -> dict[str, object]:
        return {"ids": self.ids, "order": self.order, "correct": self.correct}

    def authored_index(self, option_id: str) -> int | None:
        return self.order[self.ids.index(option_id)] if option_id in self.ids else None


def shuffle_options(question: Question) -> ShuffledOptions:
    order = list(range(len(question.options)))
    _random.shuffle(order)
    ids: list[str] = []
    while len(ids) < len(order):
        candidate = "".join(_random.choice(_OPTION_ALPHABET) for _ in range(OPTION_ID_LENGTH))
        if candidate not in ids:
            ids.append(candidate)
    return ShuffledOptions(ids=ids, order=order, correct=ids[order.index(question.answer)])


def battle_pool(subject_id: int, goals: Collection[str]) -> list[ColumnElement[bool]]:
    """Conditions for questions a battle between players of these exams may use."""
    return [
        Question.subject_id == subject_id,
        Question.status == ContentStatus.PUBLISHED.value,
        Question.battle_pool != BattlePool.NONE.value,
        Question.kind == QuestionKind.MCQ_SINGLE.value,
        *(suits_goal(goal) for goal in sorted(set(goals))),
    ]


async def pick_questions(
    db: AsyncSession,
    *,
    subject_id: int,
    sources: Sequence[tuple[int | None, int]],
    user_ids: Collection[uuid.UUID],
    goals: Collection[str],
    avg_rating: float,
) -> list[PickedQuestion]:
    """Questions for a match: ``sources`` is (chapter id or None for the subject, count)."""
    last_seen = (
        select(func.max(UserQuestion.last_at))
        .where(
            UserQuestion.question_id == Question.id,
            UserQuestion.user_id.in_(list(user_ids)),
            UserQuestion.attempts > 0,
        )
        .correlate(Question)
        .scalar_subquery()
    )
    base = battle_pool(subject_id, goals)
    chosen: list[uuid.UUID] = []

    async def take(conditions: list[ColumnElement[bool]], count: int) -> None:
        if count <= 0:
            return
        statement = (
            select(Question.id)
            .join(Chapter, Chapter.id == Question.chapter_id)
            .where(*base, Chapter.is_active, *conditions)
            .order_by(last_seen.asc().nulls_first(), func.random())
            .limit(count)
        )
        if chosen:
            statement = statement.where(Question.id.not_in(chosen))
        chosen.extend(await db.scalars(statement))

    for chapter_id, count in sources:
        scope = [] if chapter_id is None else [Question.chapter_id == chapter_id]
        start = len(chosen)
        for band, wanted in difficulty_mix(avg_rating, count).items():
            await take([*scope, Question.difficulty.in_(DIFFICULTY_BANDS[band])], wanted)
        await take(scope, count - (len(chosen) - start))  # any difficulty
        await take([], count - (len(chosen) - start))  # the whole subject

    rows = await db.execute(
        select(Question, Chapter)
        .join(Chapter, Chapter.id == Question.chapter_id)
        .where(Question.id.in_(chosen))
    )
    by_id = {question.id: PickedQuestion(question, chapter) for question, chapter in rows}
    picked = [by_id[question_id] for question_id in chosen]
    _random.shuffle(picked)
    return picked
