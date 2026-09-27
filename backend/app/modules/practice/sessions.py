"""Practice sessions: create, resume and finish."""

import secrets
import uuid
from collections import defaultdict
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Conflict, NotFound
from app.modules.content.catalog import DEFAULT_GOAL
from app.modules.content.models import Passage, Question, Topic
from app.modules.content.views import bookmarked_ids, load_views
from app.modules.practice.models import (
    Outcome,
    PracticeAnswer,
    PracticeMode,
    PracticeSession,
)
from app.modules.practice.schemas import (
    AnswerStateOut,
    PassageOut,
    SessionDetailOut,
    SessionIn,
    SessionOut,
    SessionQuestionOut,
    TopicResultOut,
)
from app.modules.practice.selection import resolve_scope, select_questions
from app.modules.users.models import User

SESSION_TTL = timedelta(hours=24)
# Sessions (with their answers) stay readable for review this long, then the worker deletes them.
HISTORY_DAYS = 90
# A challenge also ends at created_at + time limit, plus this much for slow networks.
CHALLENGE_GRACE = timedelta(seconds=60)
# NEET marking: +4 for a correct answer, -1 for a wrong one, 0 for skipped or timed out.
NEET_CORRECT, NEET_WRONG = 4, -1

_random = secrets.SystemRandom()


async def user_goal(db: AsyncSession, user_id: uuid.UUID) -> str:
    return await db.scalar(select(User.goal).where(User.id == user_id)) or DEFAULT_GOAL


def challenge_deadline(session: PracticeSession) -> datetime | None:
    """When a challenge stops accepting answers; ``None`` for other modes."""
    limit = session.settings.get("time_limit_s")
    if session.mode != PracticeMode.CHALLENGE or not isinstance(limit, int):
        return None
    return session.created_at + timedelta(seconds=limit) + CHALLENGE_GRACE


def per_question_ms(session: PracticeSession) -> int | None:
    seconds = session.settings.get("per_question_s")
    return seconds * 1000 if session.settings.get("timed") and isinstance(seconds, int) else None


async def create_session(
    db: AsyncSession, user_id: uuid.UUID, body: SessionIn, *, now: datetime
) -> PracticeSession:
    """Pick the questions and store the session; 409 ``NO_QUESTIONS`` if nothing matches."""
    goal = await user_goal(db, user_id)
    scope = await resolve_scope(db, body, goal=goal)
    ids = await select_questions(db, user_id=user_id, scope=scope, body=body, now=now)
    if not ids:
        raise Conflict("No questions match these settings yet.", code="NO_QUESTIONS")
    settings: dict[str, Any] = {**body.model_dump(mode="json"), "goal": goal}
    session = PracticeSession(
        user_id=user_id,
        mode=scope.mode.value,
        subject_id=scope.subject.id if scope.subject else None,
        passage_id=scope.passage.id if scope.passage else None,
        title=scope.title,
        settings=settings,
        question_ids=ids,
        # The display order of each question's options, kept so a resumed session matches.
        option_orders=[_random.sample(range(4), 4) for _ in ids],
        created_at=now,
        expires_at=now + SESSION_TTL,
    )
    db.add(session)
    await db.flush()
    return session


async def owned_session(
    db: AsyncSession,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    *,
    now: datetime,
    lock: bool = False,
) -> PracticeSession:
    """The user's session; 404 for sessions that don't exist, belong to someone else or are
    older than the history keeps."""
    statement = select(PracticeSession).where(
        PracticeSession.id == session_id,
        PracticeSession.user_id == user_id,
        PracticeSession.created_at > now - timedelta(days=HISTORY_DAYS),
    )
    if lock:
        statement = statement.with_for_update()
    session = await db.scalar(statement)
    if session is None:
        raise NotFound("This practice session doesn't exist.", code="SESSION_NOT_FOUND")
    return session


async def _session_fields(
    db: AsyncSession, user_id: uuid.UUID, session: PracticeSession
) -> dict[str, Any]:
    views = await load_views(db, session.question_ids)
    bookmarked = await bookmarked_ids(db, user_id, session.question_ids)
    passage = await db.get(Passage, session.passage_id) if session.passage_id else None
    settings = session.settings
    limit_s = settings.get("time_limit_s")
    requested = settings.get("count")
    return {
        "session_id": session.id,
        "mode": session.mode,
        "title": session.title,
        "feedback": "end" if session.mode == PracticeMode.CHALLENGE else "instant",
        "created_at": session.created_at,
        "expires_at": session.expires_at,
        "per_question_ms": per_question_ms(session),
        "time_limit_ms": limit_s * 1000 if isinstance(limit_s, int) else None,
        "marking": settings.get("marking", "none"),
        "short": session.mode != PracticeMode.PASSAGE
        and isinstance(requested, int)
        and len(session.question_ids) < requested,
        "passage": (
            PassageOut(id=passage.id, title=passage.title, body=passage.body) if passage else None
        ),
        "questions": [
            SessionQuestionOut(
                position=index + 1,
                **views[question_id].fields(
                    bookmarked=question_id in bookmarked, order=session.option_orders[index]
                ),
            )
            for index, question_id in enumerate(session.question_ids)
        ],
    }


async def session_out(db: AsyncSession, user_id: uuid.UUID, session: PracticeSession) -> SessionOut:
    return SessionOut(**await _session_fields(db, user_id, session))


async def session_detail(
    db: AsyncSession, user_id: uuid.UUID, session: PracticeSession
) -> SessionDetailOut:
    answers = await db.scalars(
        select(PracticeAnswer)
        .where(PracticeAnswer.session_id == session.id)
        .order_by(PracticeAnswer.position)
    )
    return SessionDetailOut(
        **await _session_fields(db, user_id, session),
        answers=[
            AnswerStateOut(
                position=answer.position,
                selected_option=answer.selected_option,
                outcome=answer.outcome,
                time_ms=answer.time_ms,
            )
            for answer in answers
        ],
        finished=session.finished_at is not None,
    )


async def answered_counts(db: AsyncSession, session_ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    rows = await db.execute(
        select(PracticeAnswer.session_id, func.count())
        .where(PracticeAnswer.session_id.in_(session_ids))
        .group_by(PracticeAnswer.session_id)
    )
    return dict(rows.all())


class SessionSummary:
    """Totals of a session's recorded answers, for the result screen."""

    def __init__(self, session: PracticeSession, rows: list[tuple[str, int, Topic | None]]):
        self.answered = len(rows)
        self.correct = sum(outcome == Outcome.CORRECT for outcome, _, _ in rows)
        self.skipped = sum(outcome == Outcome.SKIPPED for outcome, _, _ in rows)
        wrong = sum(outcome == Outcome.WRONG for outcome, _, _ in rows)
        self.time_ms = sum(time_ms for _, time_ms, _ in rows)
        self.score: int | None = None
        self.max_score: int | None = None
        if session.settings.get("marking") == "neet":
            self.score = NEET_CORRECT * self.correct + NEET_WRONG * wrong
            self.max_score = NEET_CORRECT * len(session.question_ids)
        per_topic: dict[int, list[int]] = defaultdict(lambda: [0, 0])
        topics: dict[int, Topic] = {}
        for outcome, _, topic in rows:
            if topic is None:
                continue
            topics[topic.id] = topic
            per_topic[topic.id][0] += 1
            per_topic[topic.id][1] += outcome == Outcome.CORRECT
        self.topics = [
            TopicResultOut(
                slug=topics[topic_id].slug,
                name=topics[topic_id].name,
                answered=answered,
                correct=correct,
            )
            for topic_id, (answered, correct) in sorted(
                per_topic.items(), key=lambda item: (-item[1][0], topics[item[0]].sort)
            )
        ]


async def finish_session(
    db: AsyncSession, user_id: uuid.UUID, session_id: uuid.UUID, *, now: datetime
) -> tuple[PracticeSession, SessionSummary]:
    """End the session (idempotent) and total its answers."""
    session = await owned_session(db, user_id, session_id, now=now, lock=True)
    if session.finished_at is None:
        session.finished_at = now
    rows = await db.execute(
        select(PracticeAnswer.outcome, PracticeAnswer.time_ms, Topic)
        .join(Question, Question.id == PracticeAnswer.question_id)
        .outerjoin(Topic, Topic.id == Question.topic_id)
        .where(PracticeAnswer.session_id == session.id)
    )
    return session, SessionSummary(
        session, [(outcome, time_ms, topic) for outcome, time_ms, topic in rows]
    )
