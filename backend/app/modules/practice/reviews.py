"""Review (Leitner boxes) and bookmarks.

A wrong answer puts a question in box 1; boxes come due after 1, 3, 7, 14 and 30 days (see
``answers.REVIEW_DAYS``). Counts include only what a review session can serve: published chapter
questions suited to the exam, never ones reserved for battles.
"""

import uuid
from datetime import datetime

from sqlalchemy import delete, func, select, tuple_, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Conflict, NotFound
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.content.models import Question, QuestionKind
from app.modules.content.queries import practice_pool, suits_goal
from app.modules.content.views import load_views, visible_view
from app.modules.practice.models import UserQuestion
from app.modules.practice.schemas import BookmarkOut, BookmarksOut

MAX_BOOKMARKS = 5000


async def review_counts(
    db: AsyncSession, user_id: uuid.UUID, *, goal: str, now: datetime
) -> tuple[int, int]:
    """(due now, in review at all)."""
    due, total = (
        await db.execute(
            select(func.count().filter(UserQuestion.review_due_at <= now), func.count())
            .select_from(UserQuestion)
            .join(Question, Question.id == UserQuestion.question_id)
            .where(
                UserQuestion.user_id == user_id,
                UserQuestion.review_box.is_not(None),
                Question.kind == QuestionKind.MCQ_SINGLE.value,
                practice_pool(),
                suits_goal(goal),
            )
        )
    ).one()
    return due, total


async def add_bookmark(
    db: AsyncSession, user_id: uuid.UUID, question_id: uuid.UUID, *, now: datetime
) -> None:
    """Idempotent: bookmarking again keeps the original time. 409 at the limit."""
    if await visible_view(db, user_id, question_id) is None:
        raise NotFound("This question doesn't exist.", code="QUESTION_NOT_FOUND")
    # One writer per user at a time, so two phones can't both squeeze past the limit.
    await db.execute(select(func.pg_advisory_xact_lock(func.hashtext(f"bookmarks:{user_id}"))))
    mine = (UserQuestion.user_id == user_id) & (UserQuestion.question_id == question_id)
    if await db.scalar(select(UserQuestion.bookmarked_at).where(mine)) is not None:
        return
    count = await db.scalar(
        select(func.count()).where(
            UserQuestion.user_id == user_id, UserQuestion.bookmarked_at.is_not(None)
        )
    )
    if (count or 0) >= MAX_BOOKMARKS:
        raise Conflict(
            f"You can keep up to {MAX_BOOKMARKS:,} bookmarks. Remove some to add more.",
            code="BOOKMARK_LIMIT",
        )
    statement = insert(UserQuestion).values(
        user_id=user_id, question_id=question_id, bookmarked_at=now
    )
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["user_id", "question_id"],
            set_={"bookmarked_at": statement.excluded.bookmarked_at},
        )
    )


async def remove_bookmark(db: AsyncSession, user_id: uuid.UUID, question_id: uuid.UUID) -> None:
    """Idempotent. A row that only held the bookmark goes away."""
    mine = (UserQuestion.user_id == user_id) & (UserQuestion.question_id == question_id)
    await db.execute(update(UserQuestion).where(mine).values(bookmarked_at=None))
    await db.execute(
        delete(UserQuestion).where(
            mine, UserQuestion.attempts == 0, UserQuestion.review_box.is_(None)
        )
    )


class BookmarkCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


async def list_bookmarks(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    subject_id: int | None,
    cursor: str | None,
    limit: int,
) -> BookmarksOut:
    """Newest first."""
    statement = (
        select(UserQuestion.question_id, UserQuestion.bookmarked_at)
        .where(UserQuestion.user_id == user_id, UserQuestion.bookmarked_at.is_not(None))
        .order_by(UserQuestion.bookmarked_at.desc(), UserQuestion.question_id.desc())
        .limit(limit + 1)
    )
    if subject_id is not None:
        statement = statement.join(Question, Question.id == UserQuestion.question_id).where(
            Question.subject_id == subject_id
        )
    if cursor is not None:
        position = decode_cursor(cursor, BookmarkCursor)
        statement = statement.where(
            tuple_(UserQuestion.bookmarked_at, UserQuestion.question_id)
            < tuple_(position.at, position.id)
        )
    rows = [(question_id, at) for question_id, at in await db.execute(statement) if at]
    page = rows[:limit]
    views = await load_views(db, [question_id for question_id, _ in page])
    items = []
    for question_id, bookmarked_at in page:
        summary = views[question_id].summary()
        items.append(
            BookmarkOut(
                ref=summary.ref,
                stem=summary.stem,
                subject=summary.subject,
                chapter=summary.chapter,
                topic=summary.topic,
                bookmarked_at=bookmarked_at,
            )
        )
    next_cursor = None
    if len(rows) > limit:
        last_id, last_at = page[-1]
        next_cursor = encode_cursor(BookmarkCursor(at=last_at, id=last_id))
    return BookmarksOut(items=items, next_cursor=next_cursor)
