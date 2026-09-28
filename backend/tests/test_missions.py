"""Daily missions: generation, fallbacks, progress from events, rewards, swaps, IST days."""

import uuid
from datetime import date, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import Chapter, Question, QuestionKind
from app.modules.practice.models import UserChapterStats, UserQuestion
from app.modules.progression import missions
from app.modules.progression.models import DailyMission, XpEvent
from app.modules.progression.service import EventKind, missions_summary, record_event
from tests.helpers import FakeClock
from tests.learn_helpers import answer, player, signin, start, upload
from tests.platform_helpers import bare_user, user_id
from tests.progression_helpers import balance, count_inbox, inbox, ist, ledger

DAY = date(2026, 9, 28)


def by_slot(summary: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["slot"]: item for item in summary["items"]}


async def todays(db: AsyncSession, user: uuid.UUID, day: date = DAY) -> dict[str, DailyMission]:
    rows = await missions.todays_missions(db, user, now=ist(day))
    return {m.slot: m for m in rows}


async def test_a_new_player_gets_three_missions_that_can_always_be_done(
    client: AsyncClient, clock: FakeClock
) -> None:
    clock.now = ist(DAY, 9)
    asha = await player(client, "asha")

    first = (await client.get("/v1/me/missions", headers=asha)).json()
    again = (await client.get("/v1/me/missions", headers=asha)).json()

    assert first == again  # created once, then read
    assert first["day"] == "2026-09-28"
    items = by_slot(first)
    assert [item["slot"] for item in first["items"]] == ["practice", "play", "review"]
    assert items["practice"]["target"] in (10, 20, 30)
    assert items["practice"]["title"] == f"Answer {items['practice']['target']} practice questions"
    assert items["practice"]["xp"] == 20
    assert items["practice"]["action"] == {"route": "/learn", "params": {}}
    assert items["play"] | {"id": None} == {
        "id": None,
        "slot": "play",
        "title": "Play 1 rated battle or tournament game",
        "progress": 0,
        "target": 1,
        "xp": 25,
        "done": False,
        "swapped": False,
        "action": {"route": "/battle", "params": {"mode": "rated"}},
    }
    # No answers yet: the review mission becomes "any chapter".
    assert items["review"]["title"] == "Answer 10 questions in any chapter"
    assert items["review"]["xp"] == 30
    assert first["bonus"] == {"xp": 100, "coins": 25, "done": False}
    assert first["swap_available"] is True
    assert first["streak"] == {"days": 0, "today_done": False, "freezes": 0}


async def test_generation_is_deterministic_per_user_and_day(db_session: AsyncSession) -> None:
    targets = set()
    for name in ("a", "b", "c", "d", "e", "f", "g", "h"):
        user = await bare_user(db_session, name)
        today = await todays(db_session, user)
        targets.add(today["practice"].target)
        # Another request (or a concurrent one) gets the same rows.
        assert (await todays(db_session, user))["practice"].id == today["practice"].id
        assert missions._pick(user, DAY, "practice", 3) == missions._pick(user, DAY, "practice", 3)
    assert targets <= {10, 20, 30}
    assert len(targets) > 1  # the hash spreads players across the three


async def _mcq_ids(db: AsyncSession, count: int) -> list[uuid.UUID]:
    return list(
        await db.scalars(
            select(Question.id)
            .where(Question.kind == QuestionKind.MCQ_SINGLE.value, Question.status == "published")
            .order_by(Question.id)
            .limit(count)
        )
    )


async def _chapter(db: AsyncSession, slug: str) -> Chapter:
    return (await db.scalars(select(Chapter).where(Chapter.slug == slug))).one()


async def test_the_review_mission_falls_back_by_what_the_player_has(
    db_session: AsyncSession,
) -> None:
    # Answers in two chapters: the weaker one (smoothed accuracy) is picked.
    weak_user = await bare_user(db_session, "weak")
    kinematics = await _chapter(db_session, "kinematics")
    laws = await _chapter(db_session, "laws-of-motion")
    for chapter, correct in ((kinematics, 8), (laws, 2)):
        db_session.add(
            UserChapterStats(
                user_id=weak_user,
                chapter_id=chapter.id,
                attempts=10,
                correct=correct,
                last_at=ist(DAY),
            )
        )
    # Five questions in review: the real review mission.
    review_user = await bare_user(db_session, "review")
    for question_id in await _mcq_ids(db_session, 5):
        db_session.add(
            UserQuestion(
                user_id=review_user,
                question_id=question_id,
                attempts=1,
                review_box=1,
                review_due_at=ist(DAY),
            )
        )
    await db_session.flush()

    weak = (await todays(db_session, weak_user))["review"]
    review = (await todays(db_session, review_user))["review"]

    assert (weak.def_id, weak.title, weak.target) == (
        "weak_chapter_10",
        f"Answer 10 questions in {laws.name}",
        10,
    )
    assert weak.params == {"chapter_id": laws.id, "chapter": "laws-of-motion", "subject": "physics"}
    assert missions.action_of(weak) == {
        "route": "/learn/physics",
        "params": {"chapter": "laws-of-motion"},
    }
    assert (review.def_id, review.title, review.target) == (
        "review_5",
        "Review 5 weak questions",
        5,
    )
    assert missions.action_of(review) == {"route": "/learn", "params": {"mode": "review"}}


async def test_practice_answers_move_missions_once(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    clock.now = ist(DAY, 10)
    asha = await player(client, "asha")
    uid = await user_id(client, asha)
    session = await start(client, asha)
    q = session["questions"]
    batch = [
        answer(q[0], at=clock()),
        answer(q[1], correct=False, at=clock()),
        answer(q[2], at=clock(), selected_option=None, skipped=True),
    ]

    await upload(client, asha, session["session_id"], batch)
    await upload(client, asha, session["session_id"], batch)  # a retry counts nothing

    items = by_slot((await client.get("/v1/me/missions", headers=asha)).json())
    assert items["practice"]["progress"] == 2  # the skip doesn't count
    assert items["review"]["progress"] == 2  # "10 questions in any chapter"
    assert items["play"]["progress"] == 0
    assert await count_inbox(db_session, uid, "mission_done") == 0  # nothing finished yet


async def test_completing_missions_pays_each_and_the_bonus_once(
    db_session: AsyncSession,
) -> None:
    user = await bare_user(db_session)
    now = ist(DAY, 11)
    today = await todays(db_session, user)
    practice_target = today["practice"].target

    done = await record_event(
        db_session, user, kind="practice_answer", count=practice_target, event_id="p1", now=now
    )
    assert [m.slot for m in done.missions_done] == ["practice"]
    await record_event(db_session, user, kind="rated_game", event_id="match:1", now=now)
    # A replayed event changes nothing.
    await record_event(db_session, user, kind="rated_game", event_id="match:1", now=now)
    await record_event(
        db_session,
        user,
        kind="chapter_answer",
        count=4,
        event_id="c1",
        now=now,
        meta={"chapter_id": 1},
    )
    summary = await missions_summary(db_session, user, now)
    assert summary["bonus"]["done"] is False
    assert by_slot(summary)["review"]["progress"] == 4

    await record_event(
        db_session,
        user,
        kind="chapter_answer",
        count=20,
        event_id="c2",
        now=now,
        meta={"chapter_id": 2},
    )
    await record_event(db_session, user, kind="practice_answer", count=5, event_id="p2", now=now)

    summary = await missions_summary(db_session, user, now)
    assert [item["done"] for item in summary["items"]] == [True, True, True]
    assert by_slot(summary)["review"]["progress"] == 10  # capped at the target
    assert summary["bonus"]["done"] is True
    assert summary["swap_available"] is False
    xp = dict(
        (
            await db_session.execute(
                select(XpEvent.source_key, XpEvent.amount).where(XpEvent.user_id == user)
            )
        ).all()
    )
    assert sorted(xp.values()) == [20, 25, 30, 100]
    assert "missions_bonus:2026-09-28" in xp
    assert await ledger(db_session, user) == [
        (20, "level_up", "Level 2 reached"),  # 175 XP
        (25, "mission_bonus", "Daily missions bonus"),
    ]
    notices = await inbox(db_session, user, "mission_done")
    assert [n.title for n in notices] == ["Mission complete"] * 3 + ["All missions done!"]
    assert notices[-1].body == "Today's bonus: +100 XP and 25 coins"


async def test_a_weak_chapter_mission_counts_only_that_chapter(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    laws = await _chapter(db_session, "laws-of-motion")
    kinematics = await _chapter(db_session, "kinematics")
    db_session.add(
        UserChapterStats(user_id=user, chapter_id=laws.id, attempts=10, correct=1, last_at=ist(DAY))
    )
    await db_session.flush()
    now = ist(DAY)

    for chapter, event in ((kinematics.id, "a"), (laws.id, "b")):
        await record_event(
            db_session,
            user,
            kind=EventKind.CHAPTER_ANSWER,
            count=3,
            event_id=event,
            now=now,
            meta={"chapter_id": chapter},
        )

    assert (await todays(db_session, user))["review"].progress == 3


async def test_one_free_swap_a_day(client: AsyncClient, clock: FakeClock) -> None:
    clock.now = ist(DAY, 9)
    asha = await player(client, "asha")
    before = by_slot((await client.get("/v1/me/missions", headers=asha)).json())

    swapped = await client.post(f"/v1/me/missions/{before['play']['id']}/swap", headers=asha)

    assert swapped.status_code == 200, swapped.text
    body = swapped.json()
    after = by_slot(body)
    assert after["play"]["id"] == before["play"]["id"]
    assert after["play"]["title"] == "Finish 1 battle of any kind"
    assert after["play"]["swapped"] is True
    assert after["play"]["action"] == {"route": "/battle", "params": {}}
    assert body["swap_available"] is False
    again = await client.post(f"/v1/me/missions/{before['practice']['id']}/swap", headers=asha)
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "SWAP_USED"
    unknown = await client.post(f"/v1/me/missions/{uuid.uuid4()}/swap", headers=asha)
    assert unknown.status_code == 404
    assert unknown.json()["error"]["code"] == "MISSION_NOT_FOUND"


async def test_a_swap_changes_the_practice_target_and_restarts_progress(
    db_session: AsyncSession,
) -> None:
    user = await bare_user(db_session)
    now = ist(DAY)
    practice = (await todays(db_session, user))["practice"]
    target = practice.target
    await record_event(db_session, user, kind="practice_answer", count=3, event_id="p", now=now)

    await missions.swap(db_session, user, practice.id, now=now)

    swapped = (await todays(db_session, user))["practice"]
    assert swapped.id == practice.id
    assert swapped.target != target
    assert swapped.def_id.startswith("practice_")
    assert swapped.progress == 0


async def test_a_done_mission_cant_be_swapped(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    clock.now = ist(DAY, 9)
    asha = await player(client, "asha")
    items = by_slot((await client.get("/v1/me/missions", headers=asha)).json())
    uid = await user_id(client, asha)
    await record_event(
        db_session, uid, kind="practice_answer", count=30, event_id="all", now=clock()
    )

    response = await client.post(f"/v1/me/missions/{items['practice']['id']}/swap", headers=asha)

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "MISSION_DONE"


async def test_missions_belong_to_the_ist_day(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    clock.now = ist(DAY, 23, 55)
    asha = await player(client, "asha")
    uid = await user_id(client, asha)
    tonight = (await client.get("/v1/me/missions", headers=asha)).json()
    await record_event(db_session, uid, kind="rated_game", event_id="late", now=ist(DAY, 23, 58))

    clock.now = ist(DAY + timedelta(days=1), 0, 2)
    asha = await signin(client, "asha")
    tomorrow = (await client.get("/v1/me/missions", headers=asha)).json()

    assert tomorrow["day"] == "2026-09-29"
    assert {i["id"] for i in tomorrow["items"]}.isdisjoint({i["id"] for i in tonight["items"]})
    assert by_slot(tomorrow)["play"]["done"] is False
    yesterday = await todays(db_session, uid, DAY)
    assert yesterday["play"].done_at is not None
    # Yesterday's missions can no longer be swapped.
    stale = await client.post(f"/v1/me/missions/{tonight['items'][0]['id']}/swap", headers=asha)
    assert stale.status_code == 404
    assert await balance(db_session, uid) == 100  # the welcome bonus only
