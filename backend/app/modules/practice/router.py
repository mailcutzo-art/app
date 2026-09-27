"""Practice sessions, the Learn tab's progress, practice history, bookmarks and reviews."""

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from starlette.responses import Response

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.errors import NotFound
from app.core.idempotency import IdempotencyDep
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.coach.service import mark_acted, session_tip
from app.modules.content.catalog import resolve_goal
from app.modules.content.refs import parse_ref
from app.modules.content.service import subject_id_for
from app.modules.practice import answers, progress, reviews, sessions
from app.modules.practice.schemas import (
    AnswersIn,
    AnswersOut,
    BookmarksOut,
    FinishOut,
    HistoryOut,
    ProgressOut,
    ReviewSummaryOut,
    SessionDetailOut,
    SessionIn,
    SessionOut,
)
from app.modules.progression.xp import session_xp

router = APIRouter(tags=["practice"])

CursorQuery = Annotated[str | None, Query(max_length=512)]
LimitQuery = Annotated[int, Query(ge=1, le=100)]


@router.post(
    "/practice/sessions",
    status_code=201,
    response_model=SessionOut,
    dependencies=[
        # 30 sessions an hour: sessions carry answer keys, so this also slows scraping.
        Depends(
            rate_limit("practice.sessions", capacity=30, refill_per_sec=30 / 3600, scope="user")
        )
    ],
    responses={409: {"description": "NO_QUESTIONS: nothing matches these settings"}},
)
async def create_session(
    body: SessionIn,
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    clock: ClockDep,
    idem: IdempotencyDep,
) -> Response:
    """Start a session. Needs an ``Idempotency-Key``: a retry returns the same session."""
    now = clock()
    session = await sessions.create_session(db, auth.user_id, body, now=now)
    await mark_acted(db, redis, auth.user_id, session, now=now)
    out = await sessions.session_out(db, auth.user_id, session)
    return await idem.complete(out, status_code=201)


@router.get("/practice/sessions/{session_id}")
async def read_session(
    session_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> SessionDetailOut:
    """The session as created, plus the answers recorded so far (to resume or review it)."""
    session = await sessions.owned_session(db, auth.user_id, session_id, now=clock())
    return await sessions.session_detail(db, auth.user_id, session)


@router.post("/practice/sessions/{session_id}/answers")
async def upload_answers(
    session_id: uuid.UUID, body: AnswersIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> AnswersOut:
    """Up to 50 answers at a time; retries and re-uploads are recognised as duplicates."""
    return await answers.ingest_answers(db, auth.user_id, session_id, body.answers, now=clock())


@router.post("/practice/sessions/{session_id}/finish")
async def finish_session(
    session_id: uuid.UUID,
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    clock: ClockDep,
) -> FinishOut:
    """End the session (idempotent) and get its result. Upload pending answers first."""
    now = clock()
    session, summary = await sessions.finish_session(db, auth.user_id, session_id, now=now)
    return FinishOut(
        session_id=session.id,
        answered=summary.answered,
        correct=summary.correct,
        skipped=summary.skipped,
        time_ms=summary.time_ms,
        score=summary.score,
        max_score=summary.max_score,
        topics=summary.topics,
        xp=await session_xp(db, auth.user_id, session.id, now=now),
        tip=await session_tip(db, redis, auth.user_id, session, now=now),
    )


@router.get("/me/practice/sessions")
async def practice_history(
    auth: CurrentAuth,
    db: SessionDep,
    clock: ClockDep,
    cursor: CursorQuery = None,
    limit: LimitQuery = 20,
) -> HistoryOut:
    """The player's practice sessions of the last 90 days, newest first."""
    return await progress.practice_history(
        db, auth.user_id, cursor=cursor, limit=limit, now=clock()
    )


@router.get("/me/progress")
async def read_progress(
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    clock: ClockDep,
    goal: Annotated[str | None, Query(max_length=32)] = None,
) -> ProgressOut:
    """Answers per subject and chapter with Strong / Needs work labels, reviews due, the
    session to continue and the top coach tip. Never cached."""
    goal = await resolve_goal(db, auth.user_id, goal)
    return await progress.build_progress(db, redis, auth.user_id, goal=goal, now=clock())


def _question_id(ref: str) -> uuid.UUID:
    question_id = parse_ref(ref)
    if question_id is None:
        raise NotFound("This question doesn't exist.", code="QUESTION_NOT_FOUND")
    return question_id


@router.put("/me/bookmarks/{ref}", status_code=204)
async def add_bookmark(ref: str, auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> None:
    """Idempotent. 409 ``BOOKMARK_LIMIT`` at 5,000 bookmarks."""
    await reviews.add_bookmark(db, auth.user_id, _question_id(ref), now=clock())


@router.delete("/me/bookmarks/{ref}", status_code=204)
async def remove_bookmark(ref: str, auth: CurrentAuth, db: SessionDep) -> None:
    """Idempotent."""
    await reviews.remove_bookmark(db, auth.user_id, _question_id(ref))


@router.get("/me/bookmarks")
async def list_bookmarks(
    auth: CurrentAuth,
    db: SessionDep,
    subject: Annotated[str | None, Query(max_length=64)] = None,
    cursor: CursorQuery = None,
    limit: LimitQuery = 20,
) -> BookmarksOut:
    """Newest first."""
    return await reviews.list_bookmarks(
        db,
        auth.user_id,
        subject_id=await subject_id_for(db, subject),
        cursor=cursor,
        limit=limit,
    )


@router.get("/me/reviews/summary")
async def review_summary(auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> ReviewSummaryOut:
    """Questions due for review now, and all questions in review."""
    goal = await resolve_goal(db, auth.user_id, None)
    due, total = await reviews.review_counts(db, auth.user_id, goal=goal, now=clock())
    return ReviewSummaryOut(due=due, total=total)
