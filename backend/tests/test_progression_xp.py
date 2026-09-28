"""Game XP per kind, the daily caps across IST midnight, and level-ups."""

import uuid
from datetime import UTC, date, datetime, timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.modules.progression.levels import GameKind, GameOutcome
from app.modules.progression.models import UserProgress, XpEvent, XpSource
from app.modules.progression.xp import award_game_xp, award_xp
from tests.platform_helpers import bare_user
from tests.progression_helpers import balance, count_inbox, inbox, ist, ledger

DAY = date(2026, 9, 28)


async def game(
    db: AsyncSession,
    user_id: uuid.UUID,
    mode: str,
    result: str = "win",
    *,
    now: datetime,
    match_id: uuid.UUID | None = None,
) -> int:
    award = await award_game_xp(
        db, user_id, mode=mode, result=result, match_id=match_id or uuid.uuid4(), now=now
    )
    return award.delta


@pytest.mark.parametrize(
    ("mode", "xp"),
    [
        ("quick_rated", (30, 20, 10)),
        ("quick_casual", (20, 15, 8)),
        ("friend", (10, 7, 4)),
        ("bot", (10, 7, 4)),
        ("group", (20, 10, 10)),
        ("tournament", (10, 10, 10)),
    ],
)
async def test_game_xp_per_kind(
    db_session: AsyncSession, mode: str, xp: tuple[int, int, int]
) -> None:
    user = await bare_user(db_session)
    now = ist(DAY)

    earned = tuple(
        [await game(db_session, user, mode, result, now=now) for result in ("win", "draw", "loss")]
    )

    assert earned == xp
    progress = await db_session.get_one(UserProgress, user)
    assert progress.xp == sum(xp)


async def test_an_award_is_made_once_per_match(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    match_id = uuid.uuid4()
    first = await award_game_xp(
        db_session,
        user,
        mode=GameKind.QUICK_RATED,
        result=GameOutcome.WIN,
        match_id=match_id,
        now=ist(DAY),
    )

    replay = await award_game_xp(
        db_session, user, mode="quick_rated", result="win", match_id=match_id, now=ist(DAY)
    )

    assert first == replay
    assert first.fragment() == {
        "delta": 30,
        "level": 1,
        "into_level": 30,
        "for_next": 100,
        "level_up": False,
        "capped": False,
    }
    rows = (await db_session.scalars(select(XpEvent).where(XpEvent.user_id == user))).all()
    assert [(r.source, r.amount, r.game_kind, r.total_after) for r in rows] == [
        ("match", 30, "quick_rated", 30)
    ]


async def test_group_xp_is_capped_at_200_a_day_until_ist_midnight(
    db_session: AsyncSession,
) -> None:
    user = await bare_user(db_session)
    late = ist(DAY, 23, 50)
    for _ in range(9):
        await game(db_session, user, "group", now=late)  # 180
    near = await award_game_xp(
        db_session, user, mode="group", result="loss", match_id=uuid.uuid4(), now=late
    )
    assert (near.delta, near.capped) == (10, False)  # 190
    cut = await award_game_xp(
        db_session, user, mode="group", result="win", match_id=uuid.uuid4(), now=late
    )
    assert (cut.delta, cut.capped) == (10, True)
    assert cut.resets_at == datetime(2026, 9, 29, tzinfo=IST)
    assert await game(db_session, user, "group", now=late) == 0
    # Other kinds are not affected by the group cap.
    assert await game(db_session, user, "quick_rated", now=late) == 30

    # 00:05 IST is a new day: the cap starts again.
    assert await game(db_session, user, "group", now=ist(DAY + timedelta(days=1), 0, 5)) == 20


async def test_bot_xp_is_capped_at_60_a_day(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    now = ist(DAY, 18)
    earned = [await game(db_session, user, "bot", now=now) for _ in range(7)]

    assert earned == [10, 10, 10, 10, 10, 10, 0]
    # Days are IST days: 18:31 UTC is already tomorrow in India.
    assert await game(db_session, user, "bot", now=datetime(2026, 9, 28, 18, 31, tzinfo=UTC)) == 10


async def test_a_level_up_pays_20_coins_and_tells_the_player_once(
    db_session: AsyncSession,
) -> None:
    user = await bare_user(db_session)
    db_session.add(UserProgress(user_id=user, xp=90))
    await db_session.flush()
    match_id = uuid.uuid4()

    award = await award_game_xp(
        db_session, user, mode="quick_rated", result="win", match_id=match_id, now=ist(DAY)
    )
    replay = await award_game_xp(
        db_session, user, mode="quick_rated", result="win", match_id=match_id, now=ist(DAY)
    )

    assert (award.level, award.into_level, award.for_next, award.level_up) == (2, 20, 150, True)
    assert replay == award
    assert await ledger(db_session, user) == [(20, "level_up", "Level 2 reached")]
    [notice] = await inbox(db_session, user, "level_up")
    assert notice.title == "Level 2!"
    assert notice.body == "You reached level 2 · +20 coins"


async def test_jumping_several_levels_pays_each_one(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)

    award = await award_xp(
        db_session,
        user,
        300,  # level 1 -> 3 (250)
        source=XpSource.ADJUSTMENT,
        source_key="adjustment:1",
        ref_id=None,
        now=ist(DAY),
    )

    assert (award.level, award.level_up) == (3, True)
    assert await balance(db_session, user) == 40
    assert await count_inbox(db_session, user, "level_up") == 1
