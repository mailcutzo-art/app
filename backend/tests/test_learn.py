"""Bookmarks, reviews, search, single questions, reports, progress labels and coach tips."""

import uuid
from datetime import timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.coach import service as coach
from app.modules.coach.inputs import load_coach_data
from app.modules.coach.models import UserTip
from app.modules.coach.schemas import TipItemOut, TipOut
from app.modules.coach.service import TipsResult, session_carries_out
from app.modules.content.models import Chapter, Question, QuestionReport
from app.modules.content.refs import parse_ref
from app.modules.practice import reviews
from app.modules.practice.models import UserChapterStats
from app.modules.practice.progress import chapter_label
from tests.helpers import FakeClock
from tests.learn_helpers import answer, player, signin, start, upload


@pytest.fixture
async def asha(client: AsyncClient) -> dict[str, str]:
    return await player(client, "asha")


async def my_id(client: AsyncClient, headers: dict[str, str]) -> uuid.UUID:
    return uuid.UUID((await client.get("/v1/me", headers=headers)).json()["id"])


# Bookmarks


async def test_bookmarks(client: AsyncClient, asha: dict[str, str], clock: FakeClock) -> None:
    physics = (await start(client, asha))["questions"]
    chemistry = (await start(client, asha, subject="chemistry", chapters=[]))["questions"]
    refs = [physics[0]["ref"], chemistry[0]["ref"], physics[1]["ref"]]
    for ref in refs:
        clock.advance(seconds=1)
        assert (await client.put(f"/v1/me/bookmarks/{ref}", headers=asha)).status_code == 204
    first_time = (await client.get("/v1/me/bookmarks", headers=asha)).json()["items"][-1]

    clock.advance(seconds=1)
    again = await client.put(f"/v1/me/bookmarks/{refs[0]}", headers=asha)  # idempotent
    page = (await client.get("/v1/me/bookmarks?limit=2", headers=asha)).json()
    rest = (
        await client.get(f"/v1/me/bookmarks?limit=2&cursor={page['next_cursor']}", headers=asha)
    ).json()
    physics_only = (await client.get("/v1/me/bookmarks?subject=physics", headers=asha)).json()

    assert again.status_code == 204
    assert [item["ref"] for item in page["items"] + rest["items"]] == refs[::-1]
    assert rest["items"][-1]["bookmarked_at"] == first_time["bookmarked_at"]  # kept
    assert rest["next_cursor"] is None
    assert page["items"][0] == {
        "ref": refs[2],
        "stem": physics[1]["stem"],
        "subject": "physics",
        "chapter": {"slug": "kinematics", "name": "Motion in a Straight Line"},
        "topic": physics[1]["topic"],
        "bookmarked_at": page["items"][0]["bookmarked_at"],
    }
    assert [item["ref"] for item in physics_only["items"]] == [refs[2], refs[0]]
    question = (await client.get(f"/v1/questions/{refs[0]}", headers=asha)).json()
    assert question["bookmarked"] is True

    for _ in range(2):  # idempotent
        assert (await client.delete(f"/v1/me/bookmarks/{refs[0]}", headers=asha)).status_code == 204
    remaining = (await client.get("/v1/me/bookmarks", headers=asha)).json()["items"]
    assert [item["ref"] for item in remaining] == [refs[2], refs[1]]


async def test_bookmarks_have_a_limit(
    client: AsyncClient, asha: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(reviews, "MAX_BOOKMARKS", 2)
    refs = [q["ref"] for q in (await start(client, asha))["questions"][:3]]
    for ref in refs[:2]:
        await client.put(f"/v1/me/bookmarks/{ref}", headers=asha)

    full = await client.put(f"/v1/me/bookmarks/{refs[2]}", headers=asha)
    existing = await client.put(f"/v1/me/bookmarks/{refs[0]}", headers=asha)

    assert full.status_code == 409
    assert full.json()["error"]["code"] == "BOOKMARK_LIMIT"
    assert existing.status_code == 204  # already bookmarked: still fine at the limit


async def test_unknown_questions_cannot_be_bookmarked(
    client: AsyncClient, asha: dict[str, str]
) -> None:
    unknown = await client.put(f"/v1/me/bookmarks/q_{uuid.uuid4().hex}", headers=asha)
    garbage = await client.put("/v1/me/bookmarks/nope", headers=asha)

    assert unknown.status_code == garbage.status_code == 404
    assert unknown.json()["error"]["code"] == "QUESTION_NOT_FOUND"


# Reviews and progress


async def test_review_summary(client: AsyncClient, asha: dict[str, str], clock: FakeClock) -> None:
    session = await start(client, asha)
    q = session["questions"]
    await upload(
        client,
        asha,
        session["session_id"],
        [answer(q[0], correct=False, at=clock()), answer(q[1], correct=False, at=clock())],
    )
    assert (await client.get("/v1/me/reviews/summary", headers=asha)).json() == {
        "due": 0,
        "total": 2,
    }

    clock.advance(days=1, seconds=1)
    asha = await signin(client, "asha")

    assert (await client.get("/v1/me/reviews/summary", headers=asha)).json() == {
        "due": 2,
        "total": 2,
    }
    assert (await client.get("/v1/me/progress", headers=asha)).json()["reviews_due"] == 2


@pytest.mark.parametrize(
    ("answered", "correct", "label"),
    [
        (0, 0, None),
        (10, 9, "strong"),  # (9+2)/14 = 0.79
        (10, 8, None),  # 10/14 = 0.71
        (9, 9, None),  # too few answers to be strong
        (5, 1, "needs_work"),  # 3/9 = 0.33
        (6, 3, "needs_work"),  # 5/10 = 0.5
        (6, 4, None),  # 6/10 = 0.6
        (4, 0, None),  # too few answers
    ],
)
def test_chapter_labels(answered: int, correct: int, label: str | None) -> None:
    assert chapter_label(answered, correct) == label


async def test_progress_labels_each_chapter(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession, clock: FakeClock
) -> None:
    user_id = await my_id(client, asha)
    chapters = {
        chapter.slug: chapter.id
        for chapter in await db_session.scalars(
            select(Chapter).where(Chapter.slug.in_(["kinematics", "laws-of-motion", "cell"]))
        )
    }
    for slug, (attempts, correct) in {
        "kinematics": (10, 9),
        "laws-of-motion": (5, 1),
        "cell": (3, 3),
    }.items():
        db_session.add(
            UserChapterStats(
                user_id=user_id,
                chapter_id=chapters[slug],
                attempts=attempts,
                correct=correct,
                seen=attempts,
                last_at=clock(),
            )
        )
    await db_session.flush()

    progress = (await client.get("/v1/me/progress", headers=asha)).json()

    labels = {
        chapter["slug"]: (
            chapter["answered"],
            chapter["correct"],
            chapter["seen"],
            chapter["label"],
        )
        for subject in progress["subjects"]
        for chapter in subject["chapters"]
    }
    assert labels["kinematics"] == (10, 9, 10, "strong")
    assert labels["laws-of-motion"] == (5, 1, 5, "needs_work")
    assert labels["cell"] == (3, 3, 3, None)
    assert labels["atomic-structure"] == (0, 0, 0, None)
    assert [subject["slug"] for subject in progress["subjects"]] == [
        "physics",
        "chemistry",
        "biology",
    ]
    assert progress["tip"] is None  # until the tip rules are wired in


async def test_progress_counts_every_answer_in_a_subject(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    passage = (await client.get("/v1/passages?subject=physics", headers=asha)).json()["items"][0]
    fun = await start(
        client, asha, mode="passage", subject=None, chapters=[], passage_id=passage["id"]
    )
    chapter = await start(client, asha)
    await upload(client, asha, fun["session_id"], [answer(q, at=clock()) for q in fun["questions"]])
    await upload(
        client,
        asha,
        chapter["session_id"],
        [answer(chapter["questions"][0], correct=False, at=clock())],
    )

    progress = (await client.get("/v1/me/progress?goal=neet", headers=asha)).json()

    physics = progress["subjects"][0]
    assert (physics["answered"], physics["correct"]) == (4, 3)
    by_slug = {c["slug"]: c for c in physics["chapters"]}
    assert (by_slug["kinematics"]["answered"], by_slug["kinematics"]["seen"]) == (1, 1)
    # Passage questions count for their passage's chapter too.
    assert by_slug["laws-of-motion"]["answered"] == 3


# Search and single questions


async def test_search_finds_questions_by_their_words(
    client: AsyncClient, asha: dict[str, str]
) -> None:
    kine = (await client.get("/v1/search?q=kine&subject=physics", headers=asha)).json()
    velocity = (await client.get("/v1/search?q=Velocity&limit=3", headers=asha)).json()
    phrase = (await client.get("/v1/search?q=position–time", headers=asha)).json()

    # Every Kinematics question (by its chapter), and others that mention kinetic energy etc.
    chapters = [item["chapter"]["slug"] for item in kine["items"]]
    assert chapters.count("kinematics") == 8
    assert {item["subject"] for item in kine["items"]} == {"physics"}
    assert len(velocity["items"]) == 3
    assert all("velocity" in item["stem"].lower() or item["topic"] for item in velocity["items"])
    assert any("position–time" in item["stem"] for item in phrase["items"])
    assert set(kine["items"][0]) == {"ref", "stem", "subject", "chapter", "topic"}


@pytest.mark.parametrize("query", ["a", "  ", " b "])
async def test_search_needs_two_characters(
    client: AsyncClient, asha: dict[str, str], query: str
) -> None:
    response = await client.get("/v1/search", params={"q": query}, headers=asha)

    assert response.status_code == 422
    assert response.json()["error"]["details"]["fields"] == {"q": "Type at least 2 characters."}


async def test_search_is_limited_to_30_a_minute(client: AsyncClient, asha: dict[str, str]) -> None:
    for _ in range(30):
        assert (await client.get("/v1/search?q=atom", headers=asha)).status_code == 200

    limited = await client.get("/v1/search?q=atom", headers=asha)

    assert limited.status_code == 429
    assert int(limited.headers["Retry-After"]) >= 1


async def test_search_treats_wildcards_as_text(client: AsyncClient, asha: dict[str, str]) -> None:
    response = await client.get("/v1/search", params={"q": "%_%"}, headers=asha)

    assert response.status_code == 200
    assert response.json()["items"] == []


async def test_a_single_question(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession, clock: FakeClock
) -> None:
    session = await start(client, asha)
    listed = session["questions"][0]

    question = (await client.get(f"/v1/questions/{listed['ref']}", headers=asha)).json()

    assert [o["id"] for o in question["options"]] == [0, 1, 2, 3]  # authored order
    assert question["answer"] == listed["answer"]
    assert {k: v for k, v in question.items() if k != "options"} == {
        k: v for k, v in listed.items() if k not in {"options", "position"}
    }

    # A version retired after the player met it stays readable for them.
    await upload(client, asha, session["session_id"], [answer(listed, at=clock())])
    await db_session.execute(
        update(Question).where(Question.id == parse_ref(listed["ref"])).values(status="retired")
    )
    ravi = await player(client, "ravi")
    assert (await client.get(f"/v1/questions/{listed['ref']}", headers=asha)).status_code == 200
    assert (await client.get(f"/v1/questions/{listed['ref']}", headers=ravi)).status_code == 404


# Reports


async def test_reporting_a_question(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    ref = (await start(client, asha))["questions"][0]["ref"]
    body = {"reason": "wrong_answer", "note": "  Option B is also right.  "}

    first = await client.post(f"/v1/questions/{ref}/reports", json=body, headers=asha)
    again = await client.post(f"/v1/questions/{ref}/reports", json=body, headers=asha)
    bad = await client.post(f"/v1/questions/{ref}/reports", json={"reason": "boring"}, headers=asha)
    unknown = await client.post(
        f"/v1/questions/q_{uuid.uuid4().hex}/reports", json={"reason": "typo"}, headers=asha
    )

    assert first.status_code == again.status_code == 202
    reports = (await db_session.scalars(select(QuestionReport))).all()
    assert [(r.reason, r.note, r.status) for r in reports] == [
        ("wrong_answer", "Option B is also right.", "open")
    ]
    assert bad.status_code == 422
    assert bad.json()["error"]["details"]["fields"] == {"reason": "Choose one of the options."}
    assert unknown.status_code == 404


async def test_players_can_send_20_reports_a_day(client: AsyncClient, asha: dict[str, str]) -> None:
    refs = [q["ref"] for q in (await start(client, asha, count=50, chapters=[]))["questions"]]
    refs += [
        q["ref"] for q in (await start(client, asha, subject="chemistry", chapters=[]))["questions"]
    ]
    for ref in refs[:20]:
        response = await client.post(
            f"/v1/questions/{ref}/reports", json={"reason": "typo"}, headers=asha
        )
        assert response.status_code == 202

    limited = await client.post(
        f"/v1/questions/{refs[20]}/reports", json={"reason": "typo"}, headers=asha
    )
    repeat = await client.post(
        f"/v1/questions/{refs[0]}/reports", json={"reason": "typo"}, headers=asha
    )

    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "RATE_LIMITED"
    assert repeat.status_code == 202  # an open report is already there


# Coach tips


async def test_tips_wait_for_twenty_answers_and_can_be_dismissed(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession, clock: FakeClock
) -> None:
    tips = await client.get("/v1/me/tips", headers=asha)
    dismissed = await client.post("/v1/me/tips/weak_topic:physics/kinematics/dismiss", headers=asha)

    assert tips.json() == {"unlocked": False, "answers_needed": 20, "tips": []}
    assert dismissed.status_code == 204
    [tip] = (await db_session.scalars(select(UserTip))).all()
    assert tip.tip_key == "weak_topic:physics/kinematics"
    assert tip.reason == "dismissed"
    assert tip.hidden_until == clock() + timedelta(days=7)


async def test_the_real_rules_turn_a_weak_topic_into_a_tip_the_app_can_start(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock
) -> None:
    # Kinematics twice, every answer wrong, then Laws of Motion right: over 20 answers.
    for chapter, correct in (
        ("kinematics", False),
        ("kinematics", False),
        ("laws-of-motion", True),
    ):
        session = await start(client, asha, chapters=[chapter])
        await upload(
            client,
            asha,
            session["session_id"],
            [answer(q, correct=correct, at=clock()) for q in session["questions"]],
        )

    tips = (await client.get("/v1/me/tips", headers=asha)).json()

    assert (tips["unlocked"], tips["answers_needed"]) == (True, 0)
    first = tips["tips"][0]
    assert first["rule"] == "weak_topic"
    topic = first["params"]["topic"]
    assert first["key"] == f"weak_topic:physics:{topic}"
    assert first["params"] == {"subject": "physics", "topic": topic, "count": "10"}
    assert first["message"].startswith("Focus on ")
    assert "You got 0 of" in first["message"]
    # Its button starts a topic session the API accepts.
    started = await start(client, asha, mode="topic", chapters=[], topic=topic)
    assert started["questions"]


async def test_finishing_a_session_refreshes_cached_tips(
    client: AsyncClient, asha: dict[str, str], clock: FakeClock, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[int] = []

    def engine(data: Any) -> TipsResult:  # a stand-in that records what it was given
        calls.append(data.total_answers)
        return TipsResult(unlocked=True, answers_needed=0, tips=[])

    monkeypatch.setattr(coach, "tips_engine", lambda: engine)
    session = await start(client, asha)  # computes tips once, to hide those it acts on
    await upload(client, asha, session["session_id"], [answer(session["questions"][0], at=clock())])
    await client.get("/v1/me/tips", headers=asha)  # still the cached list
    await client.post(f"/v1/practice/sessions/{session['session_id']}/finish", headers=asha)

    assert calls == [0, 1]  # the finish recomputed them with the new answer


def tip(key: str, action: str, **params: str) -> TipItemOut:
    return TipItemOut(
        key=key, rule=key.split(":")[0], message="Do this.", action=action, params=params
    )


async def test_tips_are_cached_and_hidden_once_dismissed_or_acted_on(
    client: AsyncClient,
    asha: dict[str, str],
    redis: Redis,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[int] = []
    tips = [
        tip("weak_topic:speed-velocity", "practice", subject="physics", topic="speed-velocity"),
        tip("review_due", "review"),
        tip("new_chapter:cell", "start_chapter", subject="biology", chapter="cell"),
    ]

    def engine(data: Any) -> TipsResult:  # a stand-in for the tip rules
        calls.append(data.total_answers)
        return TipsResult(unlocked=True, answers_needed=0, tips=tips)

    monkeypatch.setattr(coach, "tips_engine", lambda: engine)

    listed = (await client.get("/v1/me/tips", headers=asha)).json()
    await client.post("/v1/me/tips/review_due/dismiss", headers=asha)
    await start(client, asha, mode="topic", chapters=[], topic="speed-velocity")  # acts on it
    after = (await client.get("/v1/me/tips", headers=asha)).json()
    progress = (await client.get("/v1/me/progress", headers=asha)).json()

    assert [t["key"] for t in listed["tips"]] == [t.key for t in tips]
    assert [t["key"] for t in after["tips"]] == ["new_chapter:cell"]
    assert progress["tip"] == {
        "key": "new_chapter:cell",
        "message": "Do this.",
        "action": "start_chapter",
        "params": {"subject": "biology", "chapter": "cell"},
    }
    assert len(calls) == 1  # computed once, then served from the 10-minute cache
    assert await redis.ttl(f"tips:{await my_id(client, asha)}:neet") > 590

    clock.advance(hours=24, seconds=1)  # "acted" hides for a day, "dismissed" for a week
    asha = await signin(client, "asha")
    later = (await client.get("/v1/me/tips", headers=asha)).json()
    assert [t["key"] for t in later["tips"]] == ["weak_topic:speed-velocity", "new_chapter:cell"]


@pytest.mark.parametrize(
    ("action", "params", "settings", "matches"),
    [
        ("practice", {"topic": "t"}, {"mode": "topic", "topic": "t"}, True),
        ("practice", {"topic": "t"}, {"mode": "topic", "topic": "u"}, False),
        (
            "practice",
            {"subject": "physics", "chapter": "c"},
            {"mode": "chapter", "subject": "physics", "chapters": ["c"]},
            True,
        ),
        ("timed_practice", {"topic": "t"}, {"mode": "topic", "topic": "t", "timed": False}, False),
        ("timed_practice", {"topic": "t"}, {"mode": "topic", "topic": "t", "timed": True}, True),
        (
            "practice_category",
            {"subject": "physics", "category": "numerical"},
            {"mode": "category", "subject": "physics", "category": "numerical"},
            True,
        ),
        ("review", {}, {"mode": "review"}, True),
        (
            "start_chapter",
            {"subject": "biology", "chapter": "cell"},
            {"mode": "chapter", "subject": "biology", "chapters": ["cell"], "difficulty": "easy"},
            True,
        ),
        (
            "practice_medium",
            {"subject": "biology", "chapter": "cell"},
            {"mode": "chapter", "subject": "biology", "chapters": ["cell"], "difficulty": "easy"},
            False,
        ),
        ("battle", {"subject": "physics"}, {"mode": "chapter", "subject": "physics"}, False),
    ],
)
def test_which_sessions_carry_out_a_tip(
    action: str, params: dict[str, str], settings: dict[str, Any], matches: bool
) -> None:
    assert (
        session_carries_out(TipOut(key="k", message="m", action=action, params=params), settings)
        is matches
    )


async def test_coach_inputs_come_from_recent_answers_and_running_totals(
    client: AsyncClient,
    asha: dict[str, str],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    user_id = await my_id(client, asha)
    session = await start(client, asha)
    q = session["questions"]
    await upload(
        client,
        asha,
        session["session_id"],
        [answer(question, correct=i < 3, at=clock()) for i, question in enumerate(q[:6])],
    )

    data = await load_coach_data(db_session, user_id, goal="neet", now=clock())

    assert data.total_answers == 6
    kinematics = next(a for a in data.areas if a.kind == "chapter" and a.key == "kinematics")
    assert (kinematics.attempts, kinematics.correct, kinematics.recent) == (6, 3, True)
    assert kinematics.subject == "physics"
    assert sum(a.attempts for a in data.areas if a.kind == "topic") == 6
    assert {a.chapter for a in data.areas if a.kind == "topic"} == {"kinematics"}
    assert data.reviews_due == 0
    assert "kinematics" not in {chapter.slug for chapter in data.untried_chapters}
    assert {"laws-of-motion", "cell"} <= {chapter.slug for chapter in data.untried_chapters}

    # A month later the answers are old: the all-time totals speak for the area.
    later = await load_coach_data(
        db_session, user_id, goal="neet", now=clock() + timedelta(days=31)
    )
    kinematics = next(a for a in later.areas if a.kind == "chapter" and a.key == "kinematics")
    assert (kinematics.attempts, kinematics.recent) == (6, False)
    assert later.reviews_due == 3
