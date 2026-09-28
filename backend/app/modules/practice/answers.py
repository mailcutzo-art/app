"""Answer uploads for practice sessions: one transaction per batch.

For each batch the server:

1. rejects answers the session can't take: given after the session expired (or, in a
   challenge, after its time limit), or for a question that isn't in the session or sits at
   another position. Answers are judged by when they were given, not when they arrive, so an
   offline phone can upload up to ``LATE_UPLOAD_WINDOW`` after the session expired;
2. claims each answer's ``client_answer_id`` in ``attempt_keys`` and records the first answer
   per position in ``practice_answers``; anything already there is a duplicate;
3. for the answers actually recorded: works out correctness itself, updates the user's state
   for the question (seen, review box), writes ``question_attempts`` rows with the question's
   subject, chapter, topic, category and difficulty, adds them to the running totals and awards
   practice XP.

Clients only report what was picked and when; the server decides whether it was right.
"""

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Protocol

from sqlalchemy import ColumnElement, and_, case, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.ids import new_id
from app.modules.content.models import Question, QuestionKind, QuestionStats
from app.modules.content.refs import parse_ref
from app.modules.practice.models import (
    AttemptKey,
    AttemptMode,
    Outcome,
    PracticeAnswer,
    PracticeMode,
    PracticeSession,
    QuestionAttempt,
    UserQuestion,
)
from app.modules.practice.schemas import AnswerIn, AnswerResultOut, AnswersOut
from app.modules.practice.sessions import challenge_deadline, owned_session, per_question_ms
from app.modules.practice.speed import typical_speed
from app.modules.practice.totals import AnswerFacts, add_to_totals
from app.modules.progression.xp import award_practice_xp

# Untimed practice times are the app's own measurement, capped at 10 minutes.
MAX_TIME_MS = 10 * 60 * 1000
MAX_ANSWER_CHANGES = 1000
# How long after a session expired answers given while it was open may still be uploaded.
LATE_UPLOAD_WINDOW = timedelta(days=7)
# Leitner review: days until a question in box N comes due.
REVIEW_DAYS = {1: 1, 2: 3, 3: 7, 4: 14, 5: 30}

ATTEMPT_MODES = {
    PracticeMode.CHAPTER: AttemptMode.CHAPTER,
    PracticeMode.TOPIC: AttemptMode.TOPIC,
    PracticeMode.CATEGORY: AttemptMode.CATEGORY,
    PracticeMode.REVIEW: AttemptMode.REVIEW,
    PracticeMode.BOOKMARKS: AttemptMode.BOOKMARKS,
    PracticeMode.CHALLENGE: AttemptMode.CHALLENGE,
    PracticeMode.PASSAGE: AttemptMode.FUN_LEARN,
}


class SeenAnswer(Protocol):
    """An answer as ``update_user_questions`` needs it (practice and live games alike)."""

    question: Question
    outcome: Outcome
    first_try: bool

    @property
    def answered_at(self) -> datetime: ...


@dataclass(slots=True)
class _Candidate:
    index: int  # in the request
    answer: AnswerIn
    question_id: uuid.UUID
    answered_at: datetime  # clamped


@dataclass(slots=True)
class _Recorded:
    candidate: _Candidate
    question: Question
    outcome: Outcome
    time_ms: int
    first_try: bool = False

    @property
    def answer(self) -> AnswerIn:
        return self.candidate.answer

    @property
    def answered_at(self) -> datetime:
        return self.candidate.answered_at


def _result(
    answer: AnswerIn, status: str, *, outcome: str | None = None, reason: str | None = None
) -> AnswerResultOut:
    return AnswerResultOut.model_validate(
        {
            "client_answer_id": answer.client_answer_id,
            "status": status,
            "outcome": outcome,
            "reason": reason,
        }
    )


def _outcome(answer: AnswerIn, question: Question) -> Outcome:
    if answer.skipped:
        return Outcome.SKIPPED
    if answer.timed_out:
        return Outcome.TIMEOUT
    return Outcome.CORRECT if answer.selected_option == question.answer else Outcome.WRONG


def _time_ms(answer: AnswerIn, limit_ms: int | None) -> int:
    """The app's measurement, capped at the per-question limit (a timeout is the full limit)."""
    if answer.timed_out and limit_ms is not None:
        return limit_ms
    return min(max(answer.time_ms, 0), limit_ms if limit_ms is not None else MAX_TIME_MS)


def _rejection(
    session: PracticeSession, answered_at: datetime, question_id: uuid.UUID | None, position: int
) -> str | None:
    """Why the session can't take this answer, if it can't."""
    if answered_at > session.expires_at:
        return "session_expired"
    deadline = challenge_deadline(session)
    if deadline is not None and answered_at > deadline:
        return "time_up"
    index = session.question_ids.index(question_id) if question_id in session.question_ids else -1
    if index < 0:
        return "unknown_question"
    if index + 1 != position:
        return "position_mismatch"
    return None


async def ingest_answers(
    db: AsyncSession,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    answers: list[AnswerIn],
    *,
    now: datetime,
) -> AnswersOut:
    # Batches of one session are applied one at a time.
    session = await owned_session(db, user_id, session_id, now=now, lock=True)
    results: dict[int, AnswerResultOut] = {}
    candidates: list[_Candidate] = []
    window_closed = now > session.expires_at + LATE_UPLOAD_WINDOW
    for index, answer in enumerate(answers):
        # Never before the session started, never in the future.
        answered_at = min(max(answer.answered_at, session.created_at), now)
        question_id = parse_ref(answer.ref)
        reason = (
            "session_expired"
            if window_closed
            else _rejection(session, answered_at, question_id, answer.position)
        )
        if reason is not None or question_id is None:
            results[index] = _result(answer, "rejected", reason=reason or "unknown_question")
        else:
            candidates.append(_Candidate(index, answer, question_id, answered_at))

    recorded = await _record_first_answers(db, user_id, session, candidates, results)
    await _fill_duplicate_outcomes(db, session, answers, results)
    xp = None
    if recorded:
        await update_user_questions(db, user_id, recorded)
        facts = await _write_attempts(db, user_id, session, recorded)
        await add_to_totals(db, user_id, facts)
        xp = await award_practice_xp(
            db,
            user_id,
            session_id=session.id,
            # Positions are recorded once, so the batch's first position names it for good.
            source_key=f"practice:{session.id}:{min(r.answer.position for r in recorded)}",
            # Only answers given earn XP; skips and timeouts would let anyone farm it.
            correct=[
                r.outcome == Outcome.CORRECT
                for r in recorded
                if r.outcome in {Outcome.CORRECT, Outcome.WRONG}
            ],
            now=now,
        )
    return AnswersOut(results=[results[index] for index in range(len(answers))], xp=xp)


async def _record_first_answers(
    db: AsyncSession,
    user_id: uuid.UUID,
    session: PracticeSession,
    candidates: list[_Candidate],
    results: dict[int, AnswerResultOut],
) -> list[_Recorded]:
    """Claim answer ids, then keep the first answer per position; the rest are duplicates."""
    unique: list[_Candidate] = []
    ids_in_batch: set[str] = set()
    for candidate in candidates:
        if candidate.answer.client_answer_id in ids_in_batch:
            results[candidate.index] = _result(candidate.answer, "duplicate")
        else:
            ids_in_batch.add(candidate.answer.client_answer_id)
            unique.append(candidate)
    if not unique:
        return []
    claimed = set(
        await db.scalars(
            insert(AttemptKey)
            .values(
                [
                    {"user_id": user_id, "client_answer_id": c.answer.client_answer_id}
                    for c in unique
                ]
            )
            .on_conflict_do_nothing()
            .returning(AttemptKey.client_answer_id)
        )
    )
    fresh: list[_Candidate] = []
    positions_in_batch: set[int] = set()
    for candidate in unique:
        position = candidate.answer.position
        if candidate.answer.client_answer_id not in claimed or position in positions_in_batch:
            results[candidate.index] = _result(candidate.answer, "duplicate")
        else:
            positions_in_batch.add(position)
            fresh.append(candidate)
    if not fresh:
        return []

    questions = {
        question.id: question
        for question in await db.scalars(
            select(Question).where(Question.id.in_([c.question_id for c in fresh]))
        )
    }
    limit_ms = per_question_ms(session)
    pending = [
        _Recorded(
            candidate=c,
            question=questions[c.question_id],
            outcome=_outcome(c.answer, questions[c.question_id]),
            time_ms=_time_ms(c.answer, limit_ms),
        )
        for c in fresh
    ]
    inserted = set(
        await db.scalars(
            insert(PracticeAnswer)
            .values(
                [
                    {
                        "session_id": session.id,
                        "position": r.answer.position,
                        "question_id": r.question.id,
                        "client_answer_id": r.answer.client_answer_id,
                        "selected_option": r.answer.selected_option,
                        "outcome": r.outcome.value,
                        "time_ms": r.time_ms,
                        "answer_changes": min(r.answer.answer_changes, MAX_ANSWER_CHANGES),
                        "answered_at": r.answered_at,
                    }
                    for r in pending
                ]
            )
            .on_conflict_do_nothing()
            .returning(PracticeAnswer.position)
        )
    )
    recorded = []
    for r in pending:
        if r.answer.position in inserted:
            results[r.candidate.index] = _result(r.answer, "accepted", outcome=r.outcome.value)
            recorded.append(r)
        else:  # an earlier upload already answered this position
            results[r.candidate.index] = _result(r.answer, "duplicate")
    return recorded


async def _fill_duplicate_outcomes(
    db: AsyncSession,
    session: PracticeSession,
    answers: list[AnswerIn],
    results: dict[int, AnswerResultOut],
) -> None:
    """A duplicate carries the outcome recorded for its position, so the app can show it."""
    duplicates = [index for index, result in results.items() if result.status == "duplicate"]
    if not duplicates:
        return
    rows = await db.execute(
        select(PracticeAnswer.position, PracticeAnswer.outcome).where(
            PracticeAnswer.session_id == session.id,
            PracticeAnswer.position.in_({answers[i].position for i in duplicates}),
        )
    )
    recorded: dict[int, str] = dict(rows.all())
    for index in duplicates:
        results[index].outcome = recorded.get(answers[index].position)


def _review_update(
    box: ColumnElement[int | None],
    due: ColumnElement[datetime | None],
    outcome: ColumnElement[str | None],
    at: ColumnElement[datetime | None],
) -> tuple[ColumnElement[int | None], ColumnElement[datetime | None]]:
    """Leitner boxes: a wrong answer goes to box 1; a correct answer to a question that is due
    moves it up a box, and from box 5 out of review."""
    promote = and_(outcome == Outcome.CORRECT.value, box.is_not(None), due <= at)
    last_box = max(REVIEW_DAYS)
    new_box = case(
        (outcome == Outcome.WRONG.value, 1),
        (promote, case((box >= last_box, None), else_=box + 1)),
        else_=box,
    )
    new_due = case(
        (outcome == Outcome.WRONG.value, at + timedelta(days=REVIEW_DAYS[1])),
        (
            promote,
            case(
                *(
                    (box == n - 1, at + timedelta(days=days))
                    for n, days in REVIEW_DAYS.items()
                    if n > 1
                ),
                else_=None,
            ),
        ),
        else_=due,
    )
    return new_box, new_due


async def update_user_questions(
    db: AsyncSession, user_id: uuid.UUID, recorded: Sequence[SeenAnswer]
) -> None:
    """Seen counts and review boxes; marks each answer that was the user's first try.

    Each question may appear once. Live games record their answers through this too.

    Only chapter questions enter review: a passage question means little without its passage.
    """
    by_question = {r.question.id: r for r in recorded}
    for reviewable in (True, False):
        group = sorted(
            (r for r in recorded if (r.question.kind == QuestionKind.MCQ_SINGLE) == reviewable),
            key=lambda r: r.question.id,  # a stable lock order across concurrent batches
        )
        if not group:
            continue
        statement = insert(UserQuestion).values(
            [
                {
                    "user_id": user_id,
                    "question_id": r.question.id,
                    "first_at": r.answered_at,
                    "last_at": r.answered_at,
                    "attempts": 1,
                    "correct": int(r.outcome == Outcome.CORRECT),
                    "last_outcome": r.outcome.value,
                    "review_box": 1 if reviewable and r.outcome == Outcome.WRONG else None,
                    "review_due_at": (
                        r.answered_at + timedelta(days=REVIEW_DAYS[1])
                        if reviewable and r.outcome == Outcome.WRONG
                        else None
                    ),
                }
                for r in group
            ]
        )
        new = statement.excluded
        current = UserQuestion.__table__.c
        update: dict[str, object] = {
            "attempts": current.attempts + 1,
            "correct": current.correct + new.correct,
            "first_at": func.least(current.first_at, new.first_at),  # LEAST skips NULLs
            "last_at": func.greatest(current.last_at, new.last_at),
            # An offline upload may be older than what is already recorded.
            "last_outcome": case(
                (current.last_at.is_(None) | (new.last_at >= current.last_at), new.last_outcome),
                else_=current.last_outcome,
            ),
        }
        if reviewable:
            box, due = _review_update(
                current.review_box, current.review_due_at, new.last_outcome, new.last_at
            )
            update |= {"review_box": box, "review_due_at": due}
        rows = await db.execute(
            statement.on_conflict_do_update(
                index_elements=["user_id", "question_id"], set_=update
            ).returning(UserQuestion.question_id, UserQuestion.attempts)
        )
        for question_id, attempts in rows:
            by_question[question_id].first_try = attempts == 1


async def _write_attempts(
    db: AsyncSession, user_id: uuid.UUID, session: PracticeSession, recorded: list[_Recorded]
) -> list[AnswerFacts]:
    """One ``question_attempts`` row per recorded answer, with the question's details copied."""
    mode = ATTEMPT_MODES[PracticeMode(session.mode)].value
    limit_ms = per_question_ms(session)
    stats = {
        row.question_id: row
        for row in await db.scalars(
            select(QuestionStats).where(
                QuestionStats.question_id.in_([r.question.id for r in recorded])
            )
        )
    }
    facts: list[AnswerFacts] = []
    rows = []
    for r in recorded:
        q = r.question
        speed = typical_speed(r.outcome, r.time_ms, stats.get(q.id))
        ist_day = r.answered_at.astimezone(IST).date()
        rows.append(
            {
                "id": new_id(),
                "answered_at": r.answered_at,
                "user_id": user_id,
                "question_id": q.id,
                "subject_id": q.subject_id,
                "chapter_id": q.chapter_id,
                "topic_id": q.topic_id,
                "category": q.category,
                "difficulty": q.difficulty,
                "mode": mode,
                "session_id": session.id,
                "position": r.answer.position,
                "selected_option": r.answer.selected_option,
                "outcome": r.outcome.value,
                "time_ms": r.time_ms,
                "time_limit_ms": limit_ms,
                "speed": speed.speed,
                "speed_basis": speed.basis,
                "peer_time_ms": speed.peer_time_ms,
                "answer_changes": min(r.answer.answer_changes, MAX_ANSWER_CHANGES),
                "first_try": r.first_try,
                "points": None,
                "ist_day": ist_day,
            }
        )
        facts.append(
            AnswerFacts(
                subject_id=q.subject_id,
                chapter_id=q.chapter_id,
                topic_id=q.topic_id,
                category=q.category,
                difficulty=q.difficulty,
                outcome=r.outcome.value,
                time_ms=r.time_ms,
                speed=speed.speed,
                speed_basis=speed.basis,
                peer_time_ms=speed.peer_time_ms,
                first_try=r.first_try,
                answered_at=r.answered_at,
                ist_day=ist_day,
            )
        )
    await db.execute(insert(QuestionAttempt).values(rows))
    return facts
