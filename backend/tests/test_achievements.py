"""Achievements through the outbox, and the progression part of match settlement."""

import uuid
from datetime import date

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import Settings
from app.modules.outbox.models import OutboxMessage
from app.modules.progression.achievements import list_achievements
from app.modules.progression.models import Achievement, UserProgress
from app.modules.progression.service import record_event, settlement_progress
from app.modules.progression.xp import award_game_xp
from tests.helpers import FakeClock
from tests.learn_helpers import answer, player, start, upload
from tests.platform_helpers import bare_user, deliver, user_id
from tests.progression_helpers import balance, inbox, ist, ledger

DAY = date(2026, 9, 28)


async def test_the_catalogue_has_about_15_achievements_worth_10_to_200_coins(
    db_session: AsyncSession,
) -> None:
    rows = (await db_session.scalars(select(Achievement))).all()

    assert 15 <= len(rows) <= 20
    assert all(10 <= row.coins <= 200 for row in rows)
    assert {"first_battle", "first_win", "streak_7", "streak_30", "level_10"} <= {
        row.id for row in rows
    }


async def test_settlement_reports_missions_streak_and_new_achievements(
    db_session: AsyncSession,
) -> None:
    user = await bare_user(db_session)
    match_id = uuid.uuid4()
    now = ist(DAY, 18)

    settled = await settlement_progress(
        db_session,
        user,
        mode="quick_rated",
        result="win",
        match_id=match_id,
        now=now,
        answered=7,
        perfect=True,
    )

    fragment = settled.fragment()
    assert fragment["streak"] == {"days": 1, "extended": True}
    assert fragment["achievements"] == [
        {"id": "first_battle", "title": "First battle"},
        {"id": "first_win", "title": "First win"},
        {"id": "perfect_battle", "title": "Perfect battle"},
    ]
    play = next(m for m in fragment["missions"] if m["title"].startswith("Play 1 rated"))
    assert (play["progress"], play["target"], play["done"]) == (1, 1, True)
    assert set(fragment["missions"][0]) == {"id", "title", "progress", "target", "done"}
    assert await balance(db_session, user) == 10 + 20 + 50
    notices = await inbox(db_session, user, "achievement")
    assert len(notices) == 3
    assert notices[0].title == "Achievement unlocked: First battle"
    assert notices[0].body == "Finish your first battle · +10 coins"

    replay = await settlement_progress(
        db_session,
        user,
        mode="quick_rated",
        result="win",
        match_id=match_id,
        now=now,
        answered=7,
        perfect=True,
    )

    assert replay.fragment()["achievements"] == []
    assert replay.fragment()["streak"] == {"days": 1, "extended": False}
    assert replay.fragment()["missions"] == fragment["missions"]
    assert await balance(db_session, user) == 80


async def test_bot_games_count_as_battles_but_not_wins(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)

    settled = await settlement_progress(
        db_session,
        user,
        mode="bot",
        result="win",
        match_id=uuid.uuid4(),
        now=ist(DAY),
        answered=7,
        perfect=True,
    )

    assert [a["id"] for a in settled.achievements] == ["first_battle"]
    # A bot game isn't rated: the play mission waits, but the streak day counts.
    assert settled.streak == {"days": 1, "extended": True}
    play = next(m for m in settled.missions if m["title"].startswith("Play 1 rated"))
    assert play["done"] is False


async def test_a_tournament_game_completes_the_play_mission(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)

    settled = await settlement_progress(
        db_session, user, mode="tournament", result="loss", match_id=uuid.uuid4(), now=ist(DAY)
    )

    play = next(m for m in settled.missions if m["title"].startswith("Play 1 rated"))
    assert play["done"] is True


async def test_settlement_lists_a_level_achievement_reached_by_the_match(
    db_session: AsyncSession,
) -> None:
    user = await bare_user(db_session)
    db_session.add(UserProgress(user_id=user, xp=2690))
    await db_session.flush()
    match_id = uuid.uuid4()

    xp = await award_game_xp(
        db_session, user, mode="quick_casual", result="win", match_id=match_id, now=ist(DAY)
    )
    settled = await settlement_progress(
        db_session, user, mode="quick_casual", result="win", match_id=match_id, now=ist(DAY)
    )

    assert (xp.level, xp.level_up) == (10, True)
    assert {"id": "level_10", "title": "Level 10"} in settled.achievements


async def test_the_outbox_consumer_awards_achievements_once(
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    settings: Settings,
) -> None:
    user = await bare_user(db_session)
    now = ist(DAY)
    for _ in range(2):
        await record_event(db_session, user, kind="friend_made", event_id="friend:x", now=now)
    await record_event(db_session, user, kind="friend_made", event_id="friend:y", now=now)
    await db_session.commit()

    await deliver(session_factory, redis, settings)
    await deliver(session_factory, redis, settings)

    queued = await db_session.scalar(
        select(func.count()).where(OutboxMessage.topic == "progression.achievement")
    )
    assert queued == 2  # the repeated event was queued once
    views = {v.id: v for v in await list_achievements(db_session, user)}
    assert views["friend_made"].earned_at is not None
    assert views["friend_made"].progress == 1  # shown capped at the target
    assert await ledger(db_session, user) == [(10, "achievement", "Achievement: Study buddy")]


@pytest.mark.parametrize("count", [99, 100])
async def test_answer_achievements_count_practice_and_battle_answers(
    db_session: AsyncSession, count: int
) -> None:
    user = await bare_user(db_session)
    await record_event(
        db_session,
        user,
        kind="practice_answer",
        count=count - 7,
        event_id="p",
        now=ist(DAY),
        apply_achievements=True,
    )

    settled = await settlement_progress(
        db_session,
        user,
        mode="friend",
        result="loss",
        match_id=uuid.uuid4(),
        now=ist(DAY),
        answered=7,
    )

    earned = {a["id"] for a in settled.achievements}
    assert ("questions_100" in earned) is (count == 100)


async def test_the_achievements_endpoint(
    client: AsyncClient,
    clock: FakeClock,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    settings: Settings,
) -> None:
    clock.now = ist(DAY, 10)
    asha = await player(client, "asha")
    uid = await user_id(client, asha)
    session = await start(client, asha)
    await upload(
        client,
        asha,
        session["session_id"],
        [answer(q, at=clock()) for q in session["questions"][:4]],
    )
    async with session_factory() as db:
        await settlement_progress(
            db, uid, mode="quick_rated", result="loss", match_id=uuid.uuid4(), now=clock()
        )
        await db.commit()
    await deliver(session_factory, redis, settings)

    response = await client.get("/v1/me/achievements", headers=asha)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["earned"] == 1
    assert body["total"] >= 15
    first, *rest = body["items"]
    assert (first["id"], first["earned"], first["progress"], first["target"]) == (
        "first_battle",
        True,
        1,
        1,
    )
    assert first["earned_at"] is not None
    others = {item["id"]: item for item in rest}
    assert all(not item["earned"] for item in rest)
    assert (others["questions_100"]["progress"], others["questions_100"]["target"]) == (4, 100)
    assert others["first_win"]["progress"] == 0
