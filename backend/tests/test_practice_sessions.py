"""Practice sessions: creating, choosing questions, resuming, finishing and history."""

import secrets
from datetime import datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import Question
from app.modules.content.refs import parse_ref
from tests.helpers import FakeClock
from tests.learn_helpers import answer, player, signin, start, upload


@pytest.fixture
async def asha(client: AsyncClient) -> dict[str, str]:
    return await player(client, "asha")


async def questions_by_ref(db: AsyncSession, refs: list[str]) -> dict[str, Question]:
    ids = {parse_ref(ref): ref for ref in refs}
    rows = await db.scalars(select(Question).where(Question.id.in_(list(ids))))
    return {ids[question.id]: question for question in rows}


def iso(value: str) -> datetime:
    return datetime.fromisoformat(value)


async def test_a_chapter_session(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    session = await start(client, asha, count=10)

    assert session["mode"] == "chapter"
    assert session["title"] == "Physics · Motion in a Straight Line"
    assert session["feedback"] == "instant"
    assert iso(session["expires_at"]) - iso(session["created_at"]) == timedelta(hours=24)
    assert (session["per_question_ms"], session["time_limit_ms"]) == (None, None)
    assert session["marking"] == "none"
    assert session["short"] is True  # 8 questions in the chapter, 10 asked for
    assert session["passage"] is None
    questions = session["questions"]
    assert [q["position"] for q in questions] == list(range(1, 9))
    stored = await questions_by_ref(db_session, [q["ref"] for q in questions])
    for question in questions:
        authored = stored[question["ref"]]
        # Shuffled for display; each option keeps its authored index as its id.
        assert sorted(option["id"] for option in question["options"]) == [0, 1, 2, 3]
        assert all(o["text"] == authored.options[o["id"]] for o in question["options"])
        assert question["answer"] == authored.answer
        assert question["explanation"] == authored.explanation
        assert question["chapter"] == {"slug": "kinematics", "name": "Motion in a Straight Line"}
        assert question["topic"]["slug"] in {"speed-velocity", "equations-of-motion"}
        assert question["bookmarked"] is False
    assert len(stored) == 8


async def test_creating_a_session_is_idempotent(client: AsyncClient, asha: dict[str, str]) -> None:
    body = {"mode": "chapter", "subject": "physics", "chapters": ["kinematics"]}
    headers = {**asha, "Idempotency-Key": secrets.token_hex(8)}

    first = await client.post("/v1/practice/sessions", json=body, headers=headers)
    retry = await client.post("/v1/practice/sessions", json=body, headers=headers)
    other = await client.post(
        "/v1/practice/sessions", json=body, headers={**asha, "Idempotency-Key": "another-key"}
    )
    missing = await client.post("/v1/practice/sessions", json=body, headers=asha)

    assert first.status_code == retry.status_code == other.status_code == 201
    assert retry.json() == first.json()
    assert retry.headers["Idempotent-Replayed"] == "true"
    assert other.json()["session_id"] != first.json()["session_id"]
    assert missing.status_code == 400
    assert missing.json()["error"]["code"] == "IDEMPOTENCY_KEY_MISSING"


async def test_another_players_session_is_not_found(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    ravi = await player(client, "ravi")
    path = f"/v1/practice/sessions/{session['session_id']}"

    responses = [
        await client.get(path, headers=ravi),
        await client.post(
            f"{path}/answers",
            headers=ravi,
            json={"answers": [answer(session["questions"][0], at=clock())]},
        ),
        await client.post(f"{path}/finish", headers=ravi),
    ]

    for response in responses:
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "SESSION_NOT_FOUND"
    assert (await client.get(path, headers=asha)).status_code == 200


@pytest.mark.parametrize(
    ("body", "fields"),
    [
        ({"mode": "chapter"}, {"subject": "Choose a subject."}),
        ({"mode": "topic", "subject": "physics"}, {"topic": "Choose a topic."}),
        (
            {"mode": "chapter", "subject": "physics", "chapters": ["optics"]},
            {"chapters": "Choose chapters of Physics."},
        ),
        (
            {"mode": "topic", "subject": "physics", "topic": "genes"},
            {"topic": "Choose a topic of Physics."},
        ),
        ({"mode": "chapter", "subject": "history"}, {"subject": "Choose a subject from the list."}),
        ({"mode": "category", "subject": "physics"}, {"category": "Choose a question type."}),
        ({"mode": "challenge", "subject": "physics"}, {"time_limit_s": "Choose a time limit."}),
        (
            {"mode": "chapter", "subject": "physics", "timed": True},
            {"per_question_s": "Choose the time per question."},
        ),
        (
            {"mode": "review", "chapters": ["kinematics"]},
            {"chapters": "Chapters are only used for chapter practice and Self Challenge."},
        ),
        ({"mode": "passage"}, {"passage_id": "Choose a passage."}),
        (
            {"mode": "chapter", "subject": "physics", "count": 4},
            {"count": "This number is too small."},
        ),
        (
            {"mode": "chapter", "subject": "physics", "per_question_s": 25, "timed": True},
            {"per_question_s": "Choose one of the options."},
        ),
        (
            {"mode": "chapter", "subject": "physics", "level": 3},
            {"level": "This field isn't allowed here."},
        ),
    ],
)
async def test_settings_are_checked_against_the_mode(
    client: AsyncClient, asha: dict[str, str], body: dict[str, Any], fields: dict[str, str]
) -> None:
    response = await client.post(
        "/v1/practice/sessions",
        json=body,
        headers={**asha, "Idempotency-Key": secrets.token_hex(8)},
    )

    assert response.status_code == 422
    assert response.json()["error"]["details"]["fields"] == fields


async def test_no_matching_questions_is_a_conflict(
    client: AsyncClient, asha: dict[str, str]
) -> None:
    maths = await start(client, asha, subject="maths", chapters=[], expect=409)  # not in NEET
    hard = await start(client, asha, difficulty="hard", expect=409)  # Kinematics has none

    assert maths["error"]["code"] == hard["error"]["code"] == "NO_QUESTIONS"


async def test_unseen_questions_come_first_then_the_longest_ago(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    first = await start(client, asha, count=5)
    order = []
    for question in reversed(first["questions"][:3]):
        clock.advance(minutes=1)
        await upload(client, asha, first["session_id"], [answer(question, at=clock())])
        order.append(question["ref"])

    second = await start(client, asha, count=8)
    unseen = await start(client, asha, unseen_only=True)

    refs = [q["ref"] for q in second["questions"]]
    assert refs[-3:] == order  # answered longest ago first
    assert set(refs[:5]).isdisjoint(order)
    assert len(unseen["questions"]) == 5
    assert unseen["short"] is True
    assert {q["ref"] for q in unseen["questions"]}.isdisjoint(order)


async def test_difficulty_topic_and_category_filters(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    easy = await start(client, asha, difficulty="easy")
    topic = await start(client, asha, mode="topic", chapters=[], topic="speed-velocity")
    numericals = await start(client, asha, mode="category", chapters=[], category="numerical")

    assert {q["difficulty"] for q in easy["questions"]} <= {1, 2}
    assert len(easy["questions"]) == 6
    assert topic["title"] == "Physics · Speed and velocity"
    assert {q["topic"]["slug"] for q in topic["questions"]} == {"speed-velocity"}
    assert numericals["title"] == "Physics · Numericals"
    assert {q["category"] for q in numericals["questions"]} == {"numerical"}
    assert len(numericals["questions"]) == 6  # across both Physics chapters


async def test_a_self_challenge(client: AsyncClient, asha: dict[str, str]) -> None:
    session = await start(
        client,
        asha,
        mode="challenge",
        chapters=[],
        count=20,
        time_limit_s=600,
        marking="neet",
    )

    assert session["title"] == "Physics · Self Challenge"
    assert session["feedback"] == "end"
    assert session["time_limit_ms"] == 600_000
    assert session["marking"] == "neet"
    assert len(session["questions"]) == 16
    assert session["short"] is True


async def test_timed_practice_has_a_limit_per_question(
    client: AsyncClient, asha: dict[str, str]
) -> None:
    session = await start(client, asha, timed=True, per_question_s=30)

    assert session["per_question_ms"] == 30_000


async def test_fun_and_learn_passages(client: AsyncClient, asha: dict[str, str]) -> None:
    passages = (await client.get("/v1/passages?subject=physics", headers=asha)).json()["items"]
    [passage] = passages

    session = await start(
        client, asha, mode="passage", subject=None, chapters=[], passage_id=passage["id"]
    )

    assert passage["title"] == "Seat belts and inertia"
    assert passage["chapter"] == {"slug": "laws-of-motion", "name": "Laws of Motion"}
    assert (passage["question_count"], passage["done"]) == (3, False)
    assert session["title"] == "Fun & Learn · Seat belts and inertia"
    assert session["passage"]["id"] == passage["id"]
    assert session["passage"]["body"].startswith("When a car brakes hard")
    assert len(session["questions"]) == 3
    assert all(q["topic"] is None for q in session["questions"])
    assert session["short"] is False


async def test_passages_are_done_once_every_question_is_answered(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    passage = (await client.get("/v1/passages?subject=biology", headers=asha)).json()["items"][0]
    session = await start(
        client, asha, mode="passage", subject=None, chapters=[], passage_id=passage["id"]
    )
    await upload(
        client, asha, session["session_id"], [answer(q, at=clock()) for q in session["questions"]]
    )

    after = (await client.get("/v1/passages?subject=biology", headers=asha)).json()["items"][0]
    everything = (await client.get("/v1/passages", headers=asha)).json()["items"]
    unknown = await client.get("/v1/passages?subject=history", headers=asha)

    assert after["done"] is True
    assert {item["subject"] for item in everything} == {"physics", "chemistry", "biology"}
    assert unknown.status_code == 422


async def test_review_sessions_serve_questions_that_are_due(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    missed = session["questions"][0]
    await upload(client, asha, session["session_id"], [answer(missed, correct=False, at=clock())])
    not_yet = await start(client, asha, mode="review", subject=None, chapters=[], expect=409)

    clock.advance(days=1, minutes=1)
    asha = await signin(client, "asha")
    review = await start(client, asha, mode="review", subject=None, chapters=[])

    assert not_yet["error"]["code"] == "NO_QUESTIONS"
    assert review["title"] == "Review"
    assert [q["ref"] for q in review["questions"]] == [missed["ref"]]


async def test_bookmark_sessions_serve_bookmarked_questions(
    client: AsyncClient, asha: dict[str, str]
) -> None:
    refs = [q["ref"] for q in (await start(client, asha))["questions"][:2]]
    for ref in refs:
        assert (await client.put(f"/v1/me/bookmarks/{ref}", headers=asha)).status_code == 204

    session = await start(client, asha, mode="bookmarks", subject="physics", chapters=[])

    assert session["title"] == "Physics · Bookmarks"
    assert sorted(q["ref"] for q in session["questions"]) == sorted(refs)
    assert all(q["bookmarked"] for q in session["questions"])


async def test_players_can_start_30_sessions_an_hour(
    client: AsyncClient, asha: dict[str, str]
) -> None:
    for _ in range(30):
        await start(client, asha)

    limited = await start(client, asha, expect=429)

    assert limited["error"]["code"] == "RATE_LIMITED"
    assert limited["error"]["details"]["retry_after"] > 0


async def test_resuming_shows_the_same_session_and_its_answers(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)
    first = session["questions"][0]
    await upload(client, asha, session["session_id"], [answer(first, at=clock(), time_ms=7000)])

    resumed = (
        await client.get(f"/v1/practice/sessions/{session['session_id']}", headers=asha)
    ).json()

    assert resumed["questions"] == session["questions"]  # same order, same option order
    assert resumed["answers"] == [
        {"position": 1, "selected_option": first["answer"], "outcome": "correct", "time_ms": 7000}
    ]
    assert resumed["finished"] is False


async def test_continue_offers_the_latest_open_session(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    older = await start(client, asha)
    clock.advance(seconds=1)
    latest = await start(client, asha, mode="topic", chapters=[], topic="speed-velocity")
    await upload(client, asha, latest["session_id"], [answer(latest["questions"][0], at=clock())])

    progress = (await client.get("/v1/me/progress", headers=asha)).json()
    assert progress["continue"] == {
        "session_id": latest["session_id"],
        "title": "Physics · Speed and velocity",
        "answered": 1,
        "count": 4,
    }

    await client.post(f"/v1/practice/sessions/{latest['session_id']}/finish", headers=asha)
    progress = (await client.get("/v1/me/progress", headers=asha)).json()
    assert progress["continue"]["session_id"] == older["session_id"]

    clock.advance(hours=24, seconds=1)  # both have expired
    asha = await signin(client, "asha")
    assert (await client.get("/v1/me/progress", headers=asha)).json()["continue"] is None


async def test_a_challenge_whose_time_is_up_cannot_be_continued(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    await start(client, asha, mode="challenge", chapters=[], time_limit_s=300)

    clock.advance(minutes=6, seconds=1)  # 5 minutes and the minute of grace
    asha = await signin(client, "asha")

    assert (await client.get("/v1/me/progress", headers=asha)).json()["continue"] is None


async def test_finishing_totals_the_session(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(
        client, asha, mode="challenge", chapters=["kinematics"], time_limit_s=600, marking="neet"
    )
    q = session["questions"]
    await upload(
        client,
        asha,
        session["session_id"],
        [
            answer(q[0], at=clock(), time_ms=4000),
            answer(q[1], at=clock(), time_ms=6000),
            answer(q[2], correct=False, at=clock(), time_ms=3000),
            answer(q[3], at=clock(), time_ms=2000, selected_option=None, skipped=True),
        ],
    )
    path = f"/v1/practice/sessions/{session['session_id']}/finish"

    result = (await client.post(path, headers=asha)).json()
    again = (await client.post(path, headers=asha)).json()

    assert result["answered"] == 4
    assert (result["correct"], result["skipped"]) == (2, 1)
    assert result["time_ms"] == 15_000
    assert (result["score"], result["max_score"]) == (2 * 4 - 1, 8 * 4)
    assert sum(topic["answered"] for topic in result["topics"]) == 4
    assert {topic["slug"] for topic in result["topics"]} <= {
        "speed-velocity",
        "equations-of-motion",
    }
    assert (result["xp"], result["tip"]) == (None, None)  # until XP and tips are wired in
    assert again == result
    detail = (
        await client.get(f"/v1/practice/sessions/{session['session_id']}", headers=asha)
    ).json()
    assert detail["finished"] is True


async def test_practice_history(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    sessions = []
    for _ in range(3):
        sessions.append(await start(client, asha, marking="neet"))
        clock.advance(seconds=1)
    ids = [session["session_id"] for session in sessions]
    first = sessions[0]["questions"]
    await upload(
        client,
        asha,
        ids[0],
        [answer(first[0], at=clock()), answer(first[1], correct=False, at=clock())],
    )

    page = (await client.get("/v1/me/practice/sessions?limit=2", headers=asha)).json()
    rest = (
        await client.get(
            f"/v1/me/practice/sessions?limit=2&cursor={page['next_cursor']}", headers=asha
        )
    ).json()

    assert [item["session_id"] for item in page["items"]] == [ids[2], ids[1]]
    assert [item["session_id"] for item in rest["items"]] == [ids[0]]
    assert rest["next_cursor"] is None
    item = rest["items"][0]
    assert item["mode"] == "chapter"
    assert item["finished_at"] is None
    assert (item["answered"], item["correct"]) == (2, 1)
    assert (item["score"], item["max_score"]) == (3, 32)


async def test_history_keeps_sessions_for_90_days(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    session = await start(client, asha)

    clock.advance(days=90, seconds=1)
    asha = await signin(client, "asha")

    history = (await client.get("/v1/me/practice/sessions", headers=asha)).json()
    old = await client.get(f"/v1/practice/sessions/{session['session_id']}", headers=asha)
    assert history["items"] == []
    assert old.status_code == 404
