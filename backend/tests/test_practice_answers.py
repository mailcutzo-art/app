"""Uploading answers: de-duplication, rejections, clamping, reviews, running totals and XP."""

import math
import uuid
from datetime import datetime, time, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.modules.content.models import Question, QuestionStats
from app.modules.content.refs import parse_ref, question_ref
from app.modules.practice import speed as speed_module
from app.modules.practice.models import (
    QuestionAttempt,
    UserCategoryStats,
    UserChapterStats,
    UserDailyStats,
    UserQuestion,
    UserTopicStats,
)
from app.modules.progression import xp as xp_module
from app.modules.progression.models import UserProgress, XpEvent
from app.modules.progression.xp import LevelProgress, XpRules
from tests.helpers import FakeClock
from tests.learn_helpers import answer, player, signin, start, statuses, upload


@pytest.fixture
async def asha(client: AsyncClient) -> dict[str, str]:
    return await player(client, "asha")


async def user_id_of(client: AsyncClient, headers: dict[str, str]) -> uuid.UUID:
    return uuid.UUID((await client.get("/v1/me", headers=headers)).json()["id"])


async def test_answers_are_judged_by_the_server(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    q = session["questions"]

    result = await upload(
        client,
        asha,
        session["session_id"],
        [
            answer(q[0], at=clock()),
            answer(q[1], correct=False, at=clock()),
            answer(q[2], at=clock(), selected_option=None, skipped=True),
            answer(q[3], at=clock(), selected_option=None, timed_out=True),
        ],
    )

    assert [(r["status"], r["outcome"], r["reason"]) for r in result["results"]] == [
        ("accepted", "correct", None),
        ("accepted", "wrong", None),
        ("accepted", "skipped", None),
        ("accepted", "timeout", None),
    ]
    assert result["xp"] is None  # until the XP rules are wired in


async def test_an_answer_counts_once(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, db_session: AsyncSession
) -> None:
    session = await start(client, asha)
    q = session["questions"]
    first = answer(q[0], at=clock())
    other_pick = answer(q[1], correct=False, at=clock())

    batch = await upload(client, asha, session["session_id"], [first, first, other_pick])
    retry = await upload(client, asha, session["session_id"], [first])
    second_try = await upload(
        client,
        asha,
        session["session_id"],
        [answer(q[1], at=clock())],  # same position
    )

    assert statuses(batch) == ["accepted", "duplicate", "accepted"]
    assert retry["results"] == [
        {
            "client_answer_id": first["client_answer_id"],
            "status": "duplicate",
            "outcome": "correct",
            "reason": None,
        }
    ]
    # Only the first answer per position counts; the duplicate reports what was recorded.
    assert (second_try["results"][0]["status"], second_try["results"][0]["outcome"]) == (
        "duplicate",
        "wrong",
    )
    detail = (
        await client.get(f"/v1/practice/sessions/{session['session_id']}", headers=asha)
    ).json()
    assert [(a["position"], a["outcome"]) for a in detail["answers"]] == [
        (1, "correct"),
        (2, "wrong"),
    ]
    user_id = await user_id_of(client, asha)
    attempts = await db_session.scalar(
        select(func.count()).where(QuestionAttempt.user_id == user_id)
    )
    assert attempts == 2


async def test_answers_the_session_cannot_take_are_rejected(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    chemistry = await start(client, asha, subject="chemistry", chapters=[])
    q = session["questions"]

    result = await upload(
        client,
        asha,
        session["session_id"],
        [
            answer(chemistry["questions"][0], at=clock(), position=1),
            {**answer(q[0], at=clock()), "ref": "q_" + "0" * 32},
            {**answer(q[0], at=clock()), "ref": "not-a-ref"},
            answer(q[0], at=clock(), position=2),
        ],
    )

    assert [(r["status"], r["reason"], r["outcome"]) for r in result["results"]] == [
        ("rejected", "unknown_question", None),
        ("rejected", "unknown_question", None),
        ("rejected", "unknown_question", None),
        ("rejected", "position_mismatch", None),
    ]


async def test_offline_answers_are_judged_by_when_they_were_given(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    q = session["questions"]
    created = clock()
    answered_in_time = answer(q[0], at=created + timedelta(hours=23))

    clock.advance(hours=25)  # the session expired an hour ago
    asha = await signin(client, "asha")
    late_upload = await upload(
        client,
        asha,
        session["session_id"],
        [answered_in_time, answer(q[1], at=created + timedelta(hours=24, minutes=30))],
    )
    clock.advance(days=7)  # past the week the phone gets to upload
    asha = await signin(client, "asha")
    too_late = await upload(
        client, asha, session["session_id"], [answer(q[2], at=created + timedelta(hours=1))]
    )

    assert [(r["status"], r["reason"]) for r in late_upload["results"]] == [
        ("accepted", None),
        ("rejected", "session_expired"),
    ]
    assert [(r["status"], r["reason"]) for r in too_late["results"]] == [
        ("rejected", "session_expired")
    ]


async def test_a_challenge_takes_answers_until_its_time_limit(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha, mode="challenge", chapters=[], time_limit_s=300)
    q = session["questions"]
    created = clock()

    clock.advance(minutes=10)
    asha = await signin(client, "asha")
    result = await upload(
        client,
        asha,
        session["session_id"],
        [
            answer(q[0], at=created + timedelta(minutes=4)),
            answer(q[1], at=created + timedelta(minutes=5, seconds=59)),  # within the grace
            answer(q[2], at=created + timedelta(minutes=6, seconds=1)),
        ],
    )

    assert [(r["status"], r["reason"]) for r in result["results"]] == [
        ("accepted", None),
        ("accepted", None),
        ("rejected", "time_up"),
    ]


async def test_times_are_clamped(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, db_session: AsyncSession
) -> None:
    untimed = await start(client, asha)
    timed = await start(
        client,
        asha,
        mode="topic",
        chapters=[],
        topic="speed-velocity",
        timed=True,
        per_question_s=20,
    )
    created = clock()
    clock.advance(minutes=5)
    u, t = untimed["questions"], timed["questions"]

    await upload(
        client,
        asha,
        untimed["session_id"],
        [
            answer(u[0], at=created - timedelta(hours=1), time_ms=900_000),
            answer(u[1], at=clock() + timedelta(hours=1), time_ms=-40),
        ],
    )
    await upload(
        client,
        asha,
        timed["session_id"],
        [
            answer(t[0], at=clock(), time_ms=25_000),
            answer(t[1], at=clock(), time_ms=3_000, selected_option=None, timed_out=True),
        ],
    )

    rows = (
        await db_session.execute(
            select(
                QuestionAttempt.session_id,
                QuestionAttempt.position,
                QuestionAttempt.time_ms,
                QuestionAttempt.time_limit_ms,
                QuestionAttempt.answered_at,
                QuestionAttempt.outcome,
            ).order_by(QuestionAttempt.session_id, QuestionAttempt.position)
        )
    ).all()
    by_key = {(str(row.session_id), row.position): row for row in rows}
    first, second = by_key[untimed["session_id"], 1], by_key[untimed["session_id"], 2]
    assert (first.time_ms, first.time_limit_ms) == (600_000, None)  # capped at 10 minutes
    assert first.answered_at == datetime.fromisoformat(untimed["created_at"])
    assert (second.time_ms, second.answered_at) == (0, clock())
    slow, timeout = by_key[timed["session_id"], 1], by_key[timed["session_id"], 2]
    assert (slow.time_ms, slow.time_limit_ms) == (20_000, 20_000)
    assert (timeout.time_ms, timeout.outcome) == (20_000, "timeout")


@pytest.mark.parametrize(
    ("change", "field", "message"),
    [
        ({"selected_option": 4}, "answers", "This number is too large."),
        ({"selected_option": -1}, "answers", "This number is too small."),
        (
            {"skipped": True},
            "answers",
            "Send a selected option, or mark the answer skipped or timed out.",
        ),
        (
            {"selected_option": None},
            "answers",
            "Send a selected option, or mark the answer skipped or timed out.",
        ),
        ({"client_answer_id": "has spaces"}, "answers", "This isn't in the right format."),
        ({"answered_at": "yesterday"}, "answers", "Enter a date and time."),
        ({"answered_at": "2026-09-27T10:00:00"}, "answers", "Enter a date and time."),
    ],
)
async def test_malformed_answers_are_refused(
    client: AsyncClient,
    asha: dict[str, str],
    clock: FakeClock,
    change: dict[str, Any],
    field: str,
    message: str,
) -> None:
    session = await start(client, asha)

    response = await client.post(
        f"/v1/practice/sessions/{session['session_id']}/answers",
        headers=asha,
        json={"answers": [{**answer(session["questions"][0], at=clock()), **change}]},
    )

    assert response.status_code == 422
    assert response.json()["error"]["details"]["fields"] == {field: message}


async def test_batches_hold_1_to_50_answers(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    one = answer(session["questions"][0], at=clock())
    path = f"/v1/practice/sessions/{session['session_id']}/answers"

    empty = await client.post(path, headers=asha, json={"answers": []})
    too_many = await client.post(
        path,
        headers=asha,
        json={"answers": [{**one, "client_answer_id": f"a{i}"} for i in range(51)]},
    )

    assert empty.status_code == too_many.status_code == 422
    assert empty.json()["error"]["details"]["fields"] == {
        "answers": "This needs at least one item."
    }
    assert too_many.json()["error"]["details"]["fields"] == {"answers": "This has too many items."}


async def review_state(db: AsyncSession, user_id: uuid.UUID, ref: str) -> tuple[Any, ...]:
    row = (
        await db.execute(
            select(UserQuestion.review_box, UserQuestion.review_due_at).where(
                UserQuestion.user_id == user_id, UserQuestion.question_id == parse_ref(ref)
            )
        )
    ).one()
    return tuple(row)


async def test_review_boxes(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, db_session: AsyncSession
) -> None:
    user_id = await user_id_of(client, asha)
    ref = (await start(client, asha))["questions"][0]["ref"]
    headers = {"value": asha}

    async def answer_it(correct: bool) -> datetime:
        headers["value"] = await signin(client, "asha")
        session = await start(client, headers["value"])
        question = next(q for q in session["questions"] if q["ref"] == ref)
        at = clock()
        result = await upload(
            client,
            headers["value"],
            session["session_id"],
            [answer(question, correct=correct, at=at)],
        )
        assert statuses(result) == ["accepted"]
        return at

    wrong_at = await answer_it(False)
    assert await review_state(db_session, user_id, ref) == (1, wrong_at + timedelta(days=1))

    clock.advance(hours=1)
    await answer_it(True)  # not due yet: stays in box 1
    assert await review_state(db_session, user_id, ref) == (1, wrong_at + timedelta(days=1))

    for box, days in [(2, 1), (3, 3), (4, 7), (5, 14)]:
        clock.advance(days=days)
        at = await answer_it(True)
        wait = {2: 3, 3: 7, 4: 14, 5: 30}[box]
        assert await review_state(db_session, user_id, ref) == (box, at + timedelta(days=wait))

    clock.advance(days=30)
    await answer_it(True)  # a correct review from box 5 graduates the question
    assert await review_state(db_session, user_id, ref) == (None, None)

    at = await answer_it(False)
    assert await review_state(db_session, user_id, ref) == (1, at + timedelta(days=1))
    clock.advance(days=1)
    at = await answer_it(True)
    clock.advance(days=3)
    at = await answer_it(False)  # wrong from box 2 goes back to box 1
    assert await review_state(db_session, user_id, ref) == (1, at + timedelta(days=1))


async def test_passage_questions_stay_out_of_review(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, db_session: AsyncSession
) -> None:
    passage = (await client.get("/v1/passages?subject=physics", headers=asha)).json()["items"][0]
    session = await start(
        client, asha, mode="passage", subject=None, chapters=[], passage_id=passage["id"]
    )
    await upload(
        client,
        asha,
        session["session_id"],
        [answer(q, correct=False, at=clock()) for q in session["questions"]],
    )

    summary = (await client.get("/v1/me/reviews/summary", headers=asha)).json()

    assert summary == {"due": 0, "total": 0}
    user_id = await user_id_of(client, asha)
    boxes = await db_session.scalars(
        select(UserQuestion.review_box).where(UserQuestion.user_id == user_id)
    )
    assert set(boxes) == {None}


async def test_first_tries_and_seen_counts(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, db_session: AsyncSession
) -> None:
    user_id = await user_id_of(client, asha)
    one = await start(client, asha)
    two = await start(client, asha)
    ref = one["questions"][0]["ref"]
    await upload(client, asha, one["session_id"], [answer(one["questions"][0], at=clock())])
    again = next(q for q in two["questions"] if q["ref"] == ref)
    await upload(client, asha, two["session_id"], [answer(again, correct=False, at=clock())])

    first_tries = list(
        await db_session.scalars(
            select(QuestionAttempt.first_try)
            .where(QuestionAttempt.user_id == user_id)
            .order_by(QuestionAttempt.answered_at, QuestionAttempt.id)
        )
    )
    chapter = await db_session.scalar(
        select(UserChapterStats).where(UserChapterStats.user_id == user_id)
    )
    state = (
        await db_session.execute(
            select(UserQuestion.attempts, UserQuestion.correct, UserQuestion.last_outcome).where(
                UserQuestion.user_id == user_id, UserQuestion.question_id == parse_ref(ref)
            )
        )
    ).one()

    assert first_tries == [True, False]
    assert (chapter.attempts, chapter.correct, chapter.seen) == (2, 1, 1)
    assert tuple(state) == (2, 1, "wrong")


def standin_speed_rule(time_ms: int, typical_ms: int, samples: int) -> str | None:
    """A stand-in for the real rule (speed.speed_vs_typical is not wired in yet)."""
    if samples < 20:
        return None
    ratio = time_ms / typical_ms
    return "fast" if ratio < 0.75 else "slow" if ratio > 1.25 else "even"


_TOTALS_SQL = """
SELECT {key},
       count(*) AS attempts,
       count(*) FILTER (WHERE outcome = 'correct') AS correct,
       sum(time_ms) AS time_ms,
       coalesce(sum(time_ms) FILTER (WHERE outcome = 'correct'), 0) AS correct_time_ms,
       max(answered_at) AS last_at,
       count(*) FILTER (WHERE speed_basis = 'opponents' AND speed = 'fast') AS fast,
       count(*) FILTER (WHERE speed_basis = 'opponents' AND speed = 'slow') AS slow,
       count(*) FILTER (WHERE speed_basis = 'opponents' AND speed = 'even') AS even,
       count(*) FILTER (WHERE speed_basis = 'typical') AS typical_compared,
       coalesce(sum(ln(greatest(time_ms, 1)::float / peer_time_ms))
                FILTER (WHERE speed_basis = 'typical'), 0) AS typical_log_ratio_sum,
       count(*) FILTER (WHERE speed = 'fast' AND outcome = 'wrong') AS fast_wrong,
       count(*) FILTER (WHERE difficulty <= 2) AS easy_attempts,
       count(*) FILTER (WHERE difficulty <= 2 AND outcome = 'correct') AS easy_correct
       {extra}
FROM question_attempts
WHERE user_id = :user_id AND {key_present}
GROUP BY {key}
"""

_COLUMNS = [
    "attempts",
    "correct",
    "time_ms",
    "correct_time_ms",
    "last_at",
    "fast",
    "slow",
    "even",
    "typical_compared",
    "typical_log_ratio_sum",
    "fast_wrong",
    "easy_attempts",
    "easy_correct",
]


async def recomputed(
    db: AsyncSession, user_id: uuid.UUID, key: str, *, extra: str = ""
) -> dict[Any, dict[str, Any]]:
    """Running totals worked out from scratch from question_attempts."""
    key_present = " AND ".join(f"{column} IS NOT NULL" for column in key.split(", "))
    rows = await db.execute(
        text(_TOTALS_SQL.format(key=key, extra=extra, key_present=key_present)),
        {"user_id": user_id},
    )
    width = len(key.split(", "))
    return {tuple(row[:width]): dict(row._mapping) for row in rows}


def stored(rows: Any, key: tuple[str, ...], columns: list[str]) -> dict[Any, dict[str, Any]]:
    return {
        tuple(getattr(row, name) for name in key): {name: getattr(row, name) for name in columns}
        for row in rows
    }


def same_totals(expected: dict[Any, dict[str, Any]], actual: dict[Any, dict[str, Any]]) -> None:
    assert expected.keys() == actual.keys()
    for key, row in actual.items():
        for name, value in row.items():
            want = expected[key][name]
            if isinstance(value, float):
                assert math.isclose(value, want, abs_tol=1e-9), (key, name)
            else:
                assert value == want, (key, name)


async def test_running_totals_match_the_answer_records(
    client: AsyncClient,
    asha: dict[str, str],
    clock: FakeClock,
    db_session: AsyncSession,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(speed_module, "speed_vs_typical", standin_speed_rule)
    user_id = await user_id_of(client, asha)
    kinematics = await start(client, asha)
    for position, typical in [(1, 4000), (2, 10_000), (3, 6000)]:
        question_id = parse_ref(kinematics["questions"][position - 1]["ref"])
        db_session.add(
            QuestionStats(
                question_id=question_id,
                attempts=40,
                correct=30,
                typical_ms=typical,
                timed_correct=25,
                p_correct=0.75,
            )
        )
    await db_session.flush()
    k = kinematics["questions"]
    passage = (await client.get("/v1/passages?subject=biology", headers=asha)).json()["items"][0]
    fun = await start(
        client, asha, mode="passage", subject=None, chapters=[], passage_id=passage["id"]
    )
    numericals = await start(client, asha, mode="category", chapters=[], category="numerical")
    chemistry = await start(client, asha, subject="chemistry", chapters=["chemical-bonding"])

    await upload(
        client,
        asha,
        kinematics["session_id"],
        [
            answer(k[0], at=clock(), time_ms=2000),  # fast against typical
            answer(k[1], correct=False, at=clock(), time_ms=5000),  # fast but wrong
            answer(k[2], at=clock(), time_ms=9000),  # slow
            answer(k[3], at=clock(), selected_option=None, skipped=True),
        ],
    )
    clock.advance(hours=20)  # tomorrow in India for some of these
    asha = await signin(client, "asha")
    await upload(
        client,
        asha,
        kinematics["session_id"],
        [answer(k[4], correct=False, at=clock()), answer(k[0], at=clock())],  # 2nd is a duplicate
    )
    await upload(
        client,
        asha,
        fun["session_id"],
        [answer(q, at=clock(), time_ms=8000) for q in fun["questions"]],
    )
    await upload(
        client,
        asha,
        numericals["session_id"],
        [answer(q, correct=i % 2 == 0, at=clock()) for i, q in enumerate(numericals["questions"])],
    )
    await upload(
        client,
        asha,
        chemistry["session_id"],
        [
            answer(q, correct=i % 3 != 0, at=clock(), time_ms=1000 * (i + 1))
            for i, q in enumerate(chemistry["questions"][:6])
        ],
    )

    topics = await db_session.scalars(
        select(UserTopicStats).where(UserTopicStats.user_id == user_id)
    )
    same_totals(
        await recomputed(db_session, user_id, "topic_id"),
        stored(topics, ("topic_id",), _COLUMNS),
    )
    chapters = await db_session.scalars(
        select(UserChapterStats).where(UserChapterStats.user_id == user_id)
    )
    same_totals(
        await recomputed(
            db_session,
            user_id,
            "chapter_id",
            extra=", count(DISTINCT question_id) FILTER (WHERE first_try) AS seen",
        ),
        stored(chapters, ("chapter_id",), [*_COLUMNS, "seen"]),
    )
    categories = await db_session.scalars(
        select(UserCategoryStats).where(UserCategoryStats.user_id == user_id)
    )
    same_totals(
        await recomputed(db_session, user_id, "subject_id, category"),
        stored(categories, ("subject_id", "category"), _COLUMNS),
    )
    daily = await db_session.scalars(
        select(UserDailyStats).where(UserDailyStats.user_id == user_id)
    )
    expected_daily = {
        (day, subject): values
        for (day, subject), values in (await recomputed_daily(db_session, user_id)).items()
    }
    same_totals(
        expected_daily,
        stored(daily, ("day", "subject_id"), ["attempts", "correct", "time_ms", "last_at"]),
    )
    labels = (
        await db_session.execute(
            select(QuestionAttempt.position, QuestionAttempt.speed, QuestionAttempt.peer_time_ms)
            .where(
                QuestionAttempt.session_id == uuid.UUID(kinematics["session_id"]),
                QuestionAttempt.position <= 4,
            )
            .order_by(QuestionAttempt.position)
        )
    ).all()
    assert [tuple(row) for row in labels] == [
        (1, "fast", 4000),
        (2, "fast", 10_000),
        (3, "slow", 6000),
        (4, None, None),  # skipped: nothing to compare
    ]
    assert len(expected_daily) >= 2  # the answers span two days in India


async def recomputed_daily(db: AsyncSession, user_id: uuid.UUID) -> dict[Any, dict[str, Any]]:
    rows = await db.execute(
        text(
            "SELECT ist_day, subject_id, count(*) AS attempts,"
            " count(*) FILTER (WHERE outcome = 'correct') AS correct,"
            " sum(time_ms) AS time_ms, max(answered_at) AS last_at"
            " FROM question_attempts WHERE user_id = :user_id GROUP BY ist_day, subject_id"
        ),
        {"user_id": user_id},
    )
    return {(row.ist_day, row.subject_id): dict(row._mapping) for row in rows}


def standin_xp_rules() -> XpRules:
    """Stand-ins for the XP formulas (app.modules.progression.levels isn't wired in yet)."""
    return XpRules(
        practice_xp=lambda correct: 2 if correct else 1,
        cap_daily=lambda already, award, cap: max(0, min(award, cap - already)),
        progress=lambda xp: LevelProgress(level=xp // 100 + 1, into_level=xp % 100, level_size=100),
    )


async def test_practice_xp_is_awarded_once_per_batch_within_the_daily_cap(
    client: AsyncClient,
    asha: dict[str, str],
    clock: FakeClock,
    db_session: AsyncSession,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(xp_module, "xp_rules", standin_xp_rules)
    user_id = await user_id_of(client, asha)
    session = await start(client, asha)
    q = session["questions"]
    batch = [answer(q[0], at=clock()), answer(q[1], correct=False, at=clock())]

    first = await upload(client, asha, session["session_id"], batch)
    replay = await upload(client, asha, session["session_id"], batch)

    assert first["xp"] == {
        "delta": 3,
        "total": 3,
        "level": 1,
        "into_level": 3,
        "for_next": 100,
        "capped": False,
        "resets_at": None,
    }
    assert replay["xp"] is None  # nothing new was recorded

    # Close to the daily cap: the award is cut, and the response says until when.
    today = clock().astimezone(IST).date()
    progress = await db_session.get_one(UserProgress, user_id, populate_existing=True)
    progress.practice_xp_today = 299
    progress.practice_xp_day = today
    await db_session.flush()
    capped = await upload(
        client, asha, session["session_id"], [answer(q[2], at=clock()), answer(q[3], at=clock())]
    )
    midnight = datetime.combine(today + timedelta(days=1), time(), tzinfo=IST)
    assert capped["xp"]["delta"] == 1
    assert capped["xp"]["capped"] is True
    assert datetime.fromisoformat(capped["xp"]["resets_at"]) == midnight

    finish = (
        await client.post(f"/v1/practice/sessions/{session['session_id']}/finish", headers=asha)
    ).json()
    assert finish["xp"]["delta"] == 4  # everything this session earned
    assert finish["xp"]["capped"] is True

    # A new day in India: the cap starts again.
    clock.now = midnight + timedelta(minutes=1)
    asha = await signin(client, "asha")
    tomorrow = await start(client, asha)
    fresh = await upload(
        client, asha, tomorrow["session_id"], [answer(tomorrow["questions"][0], at=clock())]
    )
    assert (fresh["xp"]["delta"], fresh["xp"]["capped"]) == (2, False)
    events = await db_session.scalar(select(func.count()).where(XpEvent.user_id == user_id))
    assert events == 3


async def test_answers_to_a_retired_question_version_still_count(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, db_session: AsyncSession
) -> None:
    session = await start(client, asha)
    question = session["questions"][0]
    retired = await db_session.get_one(Question, parse_ref(question["ref"]))
    retired.status = "retired"
    await db_session.flush()

    result = await upload(client, asha, session["session_id"], [answer(question, at=clock())])

    assert statuses(result) == ["accepted"]
    assert question_ref(retired.id) == question["ref"]
