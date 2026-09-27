"""Search and Fun & Learn passages."""

import re
import uuid

from sqlalchemy import case, func, literal_column, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationFailed
from app.modules.content.models import Chapter, ContentStatus, Passage, Question, Subject
from app.modules.content.queries import practice_pool, subjects_of_goal, suits_goal
from app.modules.content.schemas import NamedRef, PassageItemOut
from app.modules.content.views import QuestionView, load_views
from app.modules.practice.models import UserQuestion

SUBJECT_MESSAGE = "Choose a subject from the list."
MIN_QUERY_LENGTH = 2

_WORD = re.compile(r"\w+")
# The same expression as the full-text index (ix_questions_search_fts), so the index applies.
_SEARCH_VECTOR = func.to_tsvector(literal_column("'simple'"), Question.search_text)


async def subject_id_for(
    db: AsyncSession, slug: str | None, *, field: str = "subject"
) -> int | None:
    """The id of subject ``slug`` (``None`` for ``None``); 422 on the field if unknown."""
    if slug is None:
        return None
    subject_id = await db.scalar(select(Subject.id).where(Subject.slug == slug))
    if subject_id is None:
        raise ValidationFailed(details={"fields": {field: SUBJECT_MESSAGE}})
    return subject_id


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


async def search_questions(
    db: AsyncSession, *, goal: str, query: str, subject_id: int | None, limit: int
) -> list[QuestionView]:
    """Questions the player could practise whose text matches ``query``.

    Words match as prefixes in the full-text index ("kine" finds "kinematics"); anything else
    falls back to a substring match served by the trigram index.
    """
    query = " ".join(query.split())
    if len(query) < MIN_QUERY_LENGTH:
        raise ValidationFailed(details={"fields": {"q": "Type at least 2 characters."}})
    words = _WORD.findall(query.lower())
    substring = Question.search_text.ilike(f"%{_escape_like(query)}%", escape="\\")
    if words:
        tsquery = func.to_tsquery(literal_column("'simple'"), " & ".join(f"{w}:*" for w in words))
        matches = or_(_SEARCH_VECTOR.op("@@")(tsquery), substring)
        rank = case((_SEARCH_VECTOR.op("@@")(tsquery), 0), else_=1)
    else:
        matches, rank = substring, case((substring, 0), else_=1)
    statement = (
        select(Question.id)
        .where(practice_pool(), suits_goal(goal), matches)
        .order_by(
            rank,
            func.word_similarity(query, Question.search_text).desc(),
            Question.subject_id,
            Question.seq,
        )
        .limit(limit)
    )
    if subject_id is not None:
        statement = statement.where(Question.subject_id == subject_id)
    ids = list(await db.scalars(statement))
    views = await load_views(db, ids)
    return [views[question_id] for question_id in ids]


async def list_passages(
    db: AsyncSession, *, user_id: uuid.UUID, goal: str, subject_id: int | None
) -> list[PassageItemOut]:
    """Published passages of the exam's subjects, with the player's progress on each."""
    statement = (
        select(Passage, Subject.slug, Chapter.slug, Chapter.name)
        .join(Subject, Subject.id == Passage.subject_id)
        .outerjoin(Chapter, Chapter.id == Passage.chapter_id)
        .where(
            Passage.status == ContentStatus.PUBLISHED.value,
            Passage.subject_id.in_(subjects_of_goal(goal)),
        )
        .order_by(Subject.sort, Passage.external_id)
    )
    if subject_id is not None:
        statement = statement.where(Passage.subject_id == subject_id)
    rows = (await db.execute(statement)).all()
    progress = await db.execute(
        select(
            Question.passage_id,
            func.count(),
            func.count().filter(UserQuestion.attempts > 0),
        )
        .outerjoin(
            UserQuestion,
            (UserQuestion.question_id == Question.id) & (UserQuestion.user_id == user_id),
        )
        .where(
            Question.passage_id.in_([passage.id for passage, *_ in rows]),
            Question.status == ContentStatus.PUBLISHED.value,
        )
        .group_by(Question.passage_id)
    )
    counts = {passage_id: (total, answered) for passage_id, total, answered in progress}
    items = []
    for passage, subject, chapter_slug, chapter_name in rows:
        total, answered = counts.get(passage.id, (0, 0))
        if total == 0:
            continue  # nothing to practise
        items.append(
            PassageItemOut(
                id=passage.id,
                title=passage.title,
                subject=subject,
                chapter=NamedRef(slug=chapter_slug, name=chapter_name) if chapter_slug else None,
                difficulty=passage.difficulty,
                question_count=total,
                done=answered == total,
            )
        )
    return items
