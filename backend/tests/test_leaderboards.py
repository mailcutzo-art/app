"""Leaderboards: eligibility, ties, exam views, casual limits, hiding, friends, snapshots,
the weekly rollover, the nightly rebuild, milestones, settlement and the API."""

import dataclasses
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.core.clock import IST
from app.core.config import Settings
from app.core.ids import new_id
from app.core.resources import Resources
from app.modules.content.models import Subject
from app.modules.leaderboards import boards, events, hooks, jobs, keys, service
from app.modules.leaderboards.models import LeaderboardBadge
from app.modules.matches.models import Match, MatchParticipant
from app.modules.matches.ports import SettledPlayer, SettlementContext
from app.modules.moderation.models import ModerationAction
from app.modules.outbox.models import OutboxMessage
from app.modules.progression.models import XpEvent, XpSource
from app.modules.progression.xp import award_xp
from app.modules.ratings.models import Rating
from app.modules.social.models import Friendship
from app.modules.users.models import User, UserSettings
from tests.platform_helpers import deliver
from tests.progression_helpers import count_inbox
from tests.social_helpers import befriend, player

# A Wednesday; its IST week started on Monday 2026-09-28.
NOW = datetime(2026, 9, 30, 12, 0, tzinfo=IST).astimezone(UTC)
WEEK = keys.week_of(NOW)


async def make_user(
    db: AsyncSession, name: str, *, goal: str | None = "neet", birth_year: int = 1996
) -> uuid.UUID:
    user = User(
        display_name=name.title(),
        handle=f"{name}_{uuid.uuid4().hex[:6]}",
        email=f"{name}-{uuid.uuid4().hex[:6]}@example.com",
        goal=goal,
        birth_year=birth_year,
    )
    db.add(user)
    await db.flush()
    return user.id


async def give_xp(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    *,
    at: datetime,
    game_kind: str | None = None,
    ref_id: uuid.UUID | None = None,
) -> None:
    db.add(
        XpEvent(
            user_id=user_id,
            source=XpSource.MATCH.value if game_kind else XpSource.PRACTICE.value,
            source_key=f"test:{new_id()}",
            amount=amount,
            ref_id=ref_id,
            ist_day=at.astimezone(IST).date(),
            game_kind=game_kind,
            created_at=at,
        )
    )
    await db.flush()


async def subject_id(db: AsyncSession, slug: str) -> int:
    found = await db.scalar(select(Subject.id).where(Subject.slug == slug))
    assert found is not None
    return found


async def play(
    db: AsyncSession,
    kind: str,
    seats: list[tuple[uuid.UUID | None, int, str]],
    *,
    at: datetime,
    subject: str = "physics",
) -> uuid.UUID:
    """A settled match: seats are (user or None for the bot, points, result)."""
    match = Match(
        id=new_id(),
        kind=kind,
        subject_id=await subject_id(db, subject),
        sources=[],
        chapter_ids=[],
        status="settled",
        end_reason="normal",
        config={},
        created_at=at,
        started_at=at,
        finished_at=at,
        settled_at=at,
    )
    db.add(match)
    await db.flush()
    for seat, (user_id, points, result) in enumerate(seats, start=1):
        db.add(
            MatchParticipant(
                match_id=match.id,
                seat=seat,
                user_id=user_id,
                is_bot=user_id is None,
                card={},
                result=result,
                score=points,
            )
        )
    await db.flush()
    return match.id


async def rate(
    db: AsyncSession,
    user_id: uuid.UUID,
    value: float,
    *,
    scope: str = "overall",
    games: int = 12,
    rd: float = 80.0,
    played_at: datetime = NOW - timedelta(hours=1),
) -> None:
    db.add(
        Rating(
            user_id=user_id,
            scope=scope,
            rating=value,
            rd=rd,
            volatility=0.06,
            games=games,
            last_played_at=played_at,
        )
    )
    await db.flush()


async def members(redis: Redis, key: str) -> list[str]:
    return [str(member) for member in await redis.zrevrange(key, 0, -1)]


async def sync(db: AsyncSession, redis: Redis, *users: uuid.UUID, now: datetime = NOW) -> None:
    for user_id in users:
        await events.sync_user(db, redis, user_id, now=now)


async def page(
    db: AsyncSession,
    redis: Redis,
    viewer: uuid.UUID,
    board: str,
    *,
    goal: str | None = None,
    now: datetime = NOW,
    cursor: str | None = None,
    limit: int = 50,
) -> Any:
    return await service.board_page(
        db, redis, viewer, board, goal=goal, cursor=cursor, limit=limit, now=now
    )


def ids(rows: list[Any]) -> list[uuid.UUID]:
    return [row.user.id for row in rows]


# --- Keys and scores --------------------------------------------------------------------------


def test_board_ids_and_weeks() -> None:
    assert keys.parse_board("weekly:physics:last") == keys.Board(
        keys.Family.WEEKLY_SUBJECT, "physics", last=True
    )
    assert keys.parse_board("rating:overall") == keys.Board(keys.Family.RATING, "overall")
    assert keys.parse_board("rating:physics:last") is None
    assert keys.parse_board("friends:rating").id == "friends:rating"  # type: ignore[union-attr]
    assert keys.parse_board("nope") is None
    # Sunday 23:59 IST is still the old week; Monday 00:00 IST starts a new one.
    sunday = datetime(2026, 10, 4, 23, 59, tzinfo=IST)
    assert keys.week_of(sunday) == WEEK
    assert keys.week_of(sunday + timedelta(minutes=1)).isoformat() == "2026-10-05"
    assert keys.week_end(WEEK) == datetime(2026, 10, 4, 18, 30, tzinfo=UTC)
    assert keys.week_label(WEEK) == "2026-W40"
    # A higher value always wins; the same value goes to whoever reached it first.
    early, late = NOW - timedelta(hours=2), NOW
    assert keys.encode(10, late) > keys.encode(9, early)
    assert keys.encode(10, early) > keys.encode(10, late)
    assert keys.decode(keys.encode(1523, late)) == 1523


# --- Weekly XP --------------------------------------------------------------------------------


async def test_weekly_xp_counts_people_not_bots_and_ties_go_first(
    db_session: AsyncSession, redis: Redis
) -> None:
    db = db_session
    asha, bea, cy = [await make_user(db, n) for n in ("asha2", "bea2", "cy2")]
    await give_xp(db, asha, 50, at=NOW - timedelta(hours=3))
    await give_xp(db, bea, 50, at=NOW - timedelta(hours=5))  # got there first
    await give_xp(db, bea, 0, at=NOW - timedelta(hours=1))  # a capped award moves nothing
    await give_xp(db, cy, 30, at=NOW - timedelta(hours=2), game_kind="bot")
    await give_xp(db, asha, 40, at=NOW - timedelta(days=4))  # last week
    await sync(db, redis, asha, bea, cy)

    result = await page(db, redis, asha, "weekly_xp")
    assert ids(result.items) == [bea, asha]
    assert [row.value for row in result.items] == [50, 50]
    assert result.players == 2
    assert result.me is not None
    assert result.me.position == 2
    assert result.ends_at == keys.week_end(WEEK)
    assert result.period == "2026-W40"
    # Practice Bot XP alone doesn't put a player on the board.
    alone = await page(db, redis, cy, "weekly_xp")
    assert alone.me is None
    assert alone.not_ranked is not None
    assert alone.not_ranked.games_to_rank == 1
    last = await page(db, redis, asha, "weekly_xp:last")
    assert ids(last.items) == [asha]
    assert last.items[0].value == 40
    assert last.ends_at is None
    assert last.not_ranked is None


async def test_casual_counts_three_games_per_pair_a_day(
    db_session: AsyncSession, redis: Redis
) -> None:
    db = db_session
    asha, bea = await make_user(db, "asha"), await make_user(db, "bea")
    start = NOW - timedelta(hours=10)
    for game in range(5):
        at = start + timedelta(hours=game)
        match_id = await play(db, "quick_casual", [(asha, 100, "win"), (bea, 60, "loss")], at=at)
        await give_xp(db, asha, 20, at=at, game_kind="quick_casual", ref_id=match_id)
        await give_xp(db, bea, 8, at=at, game_kind="quick_casual", ref_id=match_id)
    # A rated game between them always counts.
    rated = await play(db, "quick_rated", [(asha, 90, "win"), (bea, 10, "loss")], at=NOW)
    await give_xp(db, asha, 30, at=NOW, game_kind="quick_rated", ref_id=rated)
    await sync(db, redis, asha, bea)

    xp = await page(db, redis, asha, "weekly_xp")
    assert [(row.user.id, row.value) for row in xp.items] == [(asha, 90), (bea, 24)]
    points = await page(db, redis, asha, "weekly:physics")
    assert [(row.user.id, row.value) for row in points.items] == [(asha, 390), (bea, 190)]
    assert (await boards.weekly_xp(db, WEEK)) == {
        asha: boards.Entry(90, NOW),
        bea: boards.Entry(24, start + timedelta(hours=2)),  # the third game counted
    }


async def test_weekly_subject_points_only_against_people(
    db_session: AsyncSession, redis: Redis
) -> None:
    db = db_session
    asha, bea = await make_user(db, "asha"), await make_user(db, "bea")
    await play(db, "bot", [(asha, 500, "win"), (None, 10, "loss")], at=NOW)
    await play(db, "friend", [(asha, 300, "win"), (bea, 10, "loss")], at=NOW)
    await play(db, "tournament", [(bea, 0, "loss"), (asha, 70, "win")], at=NOW)
    await sync(db, redis, asha, bea)
    result = await page(db, redis, bea, "weekly:physics")
    # One game in the subject is enough to be on it, even with no points.
    assert [(row.user.id, row.value) for row in result.items] == [(asha, 70), (bea, 0)]
    chemistry = await page(db, redis, bea, "weekly:chemistry")
    assert chemistry.items == []
    assert chemistry.not_ranked is not None


# --- Ratings ----------------------------------------------------------------------------------


async def test_rating_boards_need_ten_games_and_a_settled_rd(
    db_session: AsyncSession, redis: Redis
) -> None:
    db = db_session
    first, second, few, uncertain, stale = [
        await make_user(db, n) for n in ("first", "second", "few", "unsure", "stale")
    ]
    await rate(db, first, 1600.2, played_at=NOW - timedelta(days=2))
    await rate(db, second, 1599.8, played_at=NOW - timedelta(hours=1))  # shows 1600 too
    await rate(db, few, 1700, games=7)
    await rate(db, uncertain, 1700, rd=120)
    # 200 idle days: the RD grows past 110 even though 100 is stored.
    await rate(db, stale, 1800, rd=100, played_at=NOW - timedelta(days=200))
    await sync(db, redis, first, second, few, uncertain, stale)

    result = await page(db, redis, few, "rating:overall")
    assert ids(result.items) == [first, second]
    assert [row.value_display for row in result.items] == ["1600", "1600"]
    assert result.not_ranked is not None
    assert result.not_ranked.games_to_rank == 3
    assert (await page(db, redis, uncertain, "rating:overall")).not_ranked.games_to_rank == 1  # type: ignore[union-attr]
    assert boards.aged_rd(await db.get_one(Rating, (stale, "overall")), NOW) > 110

    # The nightly rebuild agrees, and a player who went idle drops off.
    later = NOW + timedelta(days=400)
    await jobs.rebuild_boards(db, redis, now=later)
    assert await members(redis, keys.rating_key("all", "overall")) == []


async def test_nightly_rebuild_matches_live_updates(db_session: AsyncSession, redis: Redis) -> None:
    db = db_session
    neet, jee = await make_user(db, "neet"), await make_user(db, "jee", goal="jee")
    await give_xp(db, neet, 30, at=NOW - timedelta(hours=1))
    await give_xp(db, jee, 60, at=NOW - timedelta(hours=1))
    await rate(db, neet, 1550)
    await play(db, "quick_rated", [(jee, 50, "win"), (neet, 40, "loss")], at=NOW, subject="maths")
    await sync(db, redis, neet, jee)
    live = {
        key: await redis.zrange(key, 0, -1, withscores=True)
        for key in sorted(await redis.keys("lb:*"))
    }
    await redis.delete(*live)
    await redis.zadd(keys.xp_key("all", WEEK), {str(uuid.uuid4()): 1.0})  # stale junk
    sizes = await jobs.rebuild_boards(db, redis, now=NOW)
    rebuilt = {
        key: await redis.zrange(key, 0, -1, withscores=True)
        for key in sorted(await redis.keys("lb:*"))
    }
    assert rebuilt == live
    assert sizes[keys.xp_key("all", WEEK)] == 2
    # NEET never shows Maths; the JEE player's Maths points are on the JEE and All India views.
    assert await members(redis, keys.subject_key("all", "maths", WEEK)) == [str(jee), str(neet)]
    assert await members(redis, keys.subject_key("jee", "maths", WEEK)) == [str(jee)]
    assert not await redis.exists(keys.subject_key("neet", "maths", WEEK))
    assert await redis.ttl(keys.xp_key("all", WEEK)) > 0


# --- Exam views and hiding --------------------------------------------------------------------


async def test_exam_filter(db_session: AsyncSession, redis: Redis) -> None:
    db = db_session
    neet, jee, none = (
        await make_user(db, "neet"),
        await make_user(db, "jee", goal="jee"),
        await make_user(db, "none", goal=None),
    )
    for user_id in (neet, jee, none):
        await give_xp(db, user_id, 10, at=NOW)
    await sync(db, redis, neet, jee, none)
    assert set(ids((await page(db, redis, neet, "weekly_xp")).items)) == {neet, jee, none}
    assert ids((await page(db, redis, neet, "weekly_xp", goal="neet")).items) == [neet]
    assert ids((await page(db, redis, neet, "weekly_xp", goal="jee")).items) == [jee]
    with pytest.raises(service.BoardNotFound):
        await page(db, redis, neet, "rating:maths", goal="neet")
    with pytest.raises(service.BoardNotFound):
        await page(db, redis, neet, "weekly:biology", goal="jee")
    with pytest.raises(service.BoardNotFound):
        await page(db, redis, neet, "weekly:astronomy")
    await page(db, redis, neet, "weekly:maths")  # All India has every subject

    hub = await service.hub(db, redis, neet, goal="neet", now=NOW)
    names = [card.board for card in hub.boards]
    assert names[:2] == ["weekly_xp", "rating:overall"]
    assert "friends:weekly_xp" in names
    assert "friends:rating" in names
    # Empty subject boards are hidden, and NEET never offers Maths.
    assert not any(name.endswith("maths") for name in names)
    assert not any(name.startswith(("weekly:", "rating:physics")) for name in names)


async def test_hidden_players_never_appear(db_session: AsyncSession, redis: Redis) -> None:
    db = db_session
    ok, banned, shadow, opted, leaving = [
        await make_user(db, n) for n in ("ok", "banned", "shadow", "opted", "leaving")
    ]
    for user_id in (ok, banned, shadow, opted, leaving):
        await give_xp(db, user_id, 10, at=NOW)
    await sync(db, redis, ok, banned, shadow, opted, leaving)
    assert len(await members(redis, keys.xp_key("all", WEEK))) == 5

    (await db.get_one(User, banned)).status = "banned"
    (await db.get_one(User, leaving)).status = "pending_deletion"
    db.add(ModerationAction(user_id=shadow, kind="shadow_pool", reason="cheating", created_at=NOW))
    db.add(UserSettings(user_id=opted, public_boards=False))
    await db.flush()
    assert await boards.hidden_ids(db, now=NOW) >= {banned, shadow, opted, leaving}
    await sync(db, redis, banned, shadow, opted, leaving)
    assert await members(redis, keys.xp_key("all", WEEK)) == [str(ok)]
    assert await members(redis, keys.xp_key("neet", WEEK)) == [str(ok)]
    await redis.flushdb()
    await jobs.rebuild_boards(db, redis, now=NOW)
    assert await members(redis, keys.xp_key("all", WEEK)) == [str(ok)]


async def test_visibility_hooks_queue_a_sync(db_session: AsyncSession) -> None:
    db = db_session
    user_id = await make_user(db, "hooked")
    await hooks._sync_after(db, user_id, NOW)
    await hooks._sync_after_privacy(db, user_id)
    queued = await db.scalars(select(OutboxMessage).where(OutboxMessage.topic == "lb.sync_user"))
    assert [m.payload for m in queued] == [{"user_id": str(user_id)}] * 2


# --- Change since yesterday and milestones ----------------------------------------------------


async def test_change_1d_against_the_morning_snapshot(
    db_session: AsyncSession, redis: Redis
) -> None:
    db = db_session
    a, b, c = [await make_user(db, n) for n in ("a", "b", "c")]
    await give_xp(db, a, 30, at=NOW - timedelta(hours=5))
    await give_xp(db, b, 20, at=NOW - timedelta(hours=5))
    await sync(db, redis, a, b)
    catalog = await boards.load_catalog(db)
    assert await jobs.snapshot_boards(redis, catalog, now=NOW) >= 2
    await give_xp(db, b, 20, at=NOW)  # b overtakes a
    await give_xp(db, c, 5, at=NOW)  # c is new today
    await sync(db, redis, b, c)
    result = await page(db, redis, a, "weekly_xp")
    assert [(r.user.id, r.change_1d) for r in result.items] == [(b, 1), (a, -1), (c, None)]
    hub = await service.hub(db, redis, a, goal=None, now=NOW)
    weekly = next(card for card in hub.boards if card.board == "weekly_xp")
    assert weekly.me.position == 2
    assert weekly.me.change_1d == -1
    assert weekly.me.value == 30
    assert weekly.leader is not None
    assert weekly.leader.user.id == b


async def test_entering_the_top_three_is_an_inbox_item(
    db_session: AsyncSession, redis: Redis
) -> None:
    db = db_session
    users = [await make_user(db, f"p{i}") for i in range(5)]
    for index, user_id in enumerate(users):
        await give_xp(db, user_id, 100 - index * 10, at=NOW - timedelta(hours=1))
    await sync(db, redis, *users)
    climber = users[-1]
    assert await count_inbox(db, climber, "rank_milestone") == 1  # top 10 on arrival
    await give_xp(db, climber, 60, at=NOW)
    await sync(db, redis, climber)
    notices = await count_inbox(db, climber, "rank_milestone")
    assert notices == 2
    await sync(db, redis, climber)  # nothing new
    assert await count_inbox(db, climber, "rank_milestone") == 2


# --- Pages ------------------------------------------------------------------------------------


async def test_top_100_pages_and_around_me(db_session: AsyncSession, redis: Redis) -> None:
    db = db_session
    users = [await make_user(db, f"r{i}") for i in range(115)]
    key = keys.rating_key("all", "overall")
    await redis.zadd(
        key, {str(u): keys.encode(2000 - i, NOW - timedelta(days=1)) for i, u in enumerate(users)}
    )
    me = users[110]
    first = await page(db, redis, me, "rating:overall")
    assert len(first.items) == 50
    assert first.items[0].position == 1
    assert first.players == 115
    second = await page(db, redis, me, "rating:overall", cursor=first.next_cursor)
    # The top 100 in all: the second page is the last.
    assert second.items[0].position == 51
    assert second.items[-1].position == 100
    assert second.next_cursor is None
    assert first.me is not None
    assert first.me.position == 111
    assert first.me.value == 1890
    assert [row.position for row in first.around_me] == list(range(101, 116))
    assert first.not_ranked is None
    small = await page(db, redis, me, "rating:overall", limit=10)
    assert len(small.items) == 10


async def test_minors_show_no_handle_to_strangers(db_session: AsyncSession, redis: Redis) -> None:
    db = db_session
    minor = await make_user(db, "kid", birth_year=datetime.now(UTC).year - 15)
    viewer, friend = await make_user(db, "viewer"), await make_user(db, "friend")
    lo, hi = sorted((minor, friend))
    db.add(Friendship(lo=lo, hi=hi))
    await db.flush()
    await give_xp(db, minor, 10, at=NOW)
    await sync(db, redis, minor)
    assert (await page(db, redis, viewer, "weekly_xp")).items[0].user.handle is None
    assert (await page(db, redis, friend, "weekly_xp")).items[0].user.handle is not None


# --- Weekly rollover --------------------------------------------------------------------------


async def test_weekly_rollover_across_monday(
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
) -> None:
    db = db_session
    sunday = datetime(2026, 10, 4, 23, 0, tzinfo=IST).astimezone(UTC)
    monday = datetime(2026, 10, 5, 0, 30, tzinfo=IST).astimezone(UTC)
    neet_a, neet_b, jee = (
        await make_user(db, "na"),
        await make_user(db, "nb"),
        await make_user(db, "jj", goal="jee"),
    )
    await give_xp(db, neet_a, 70, at=sunday)
    await give_xp(db, neet_b, 40, at=sunday)
    await play(db, "quick_rated", [(neet_a, 80, "win"), (jee, 90, "loss")], at=sunday)
    await sync(db, redis, neet_a, neet_b, jee, now=sunday)
    await db.commit()

    fresh = await page(db, redis, neet_a, "weekly_xp", now=monday)
    assert fresh.items == []
    assert fresh.ends_at == keys.week_end(keys.week_of(monday))
    last = await page(db, redis, neet_a, "weekly_xp:last", now=monday)
    assert ids(last.items) == [neet_a, neet_b]
    assert last.period == "2026-W40"
    hub = await service.hub(db, redis, neet_b, goal=None, now=monday)
    assert ids(hub.last_week) == [neet_a, neet_b]

    ended = keys.week_of(monday) - timedelta(days=7)
    assert await jobs.crown_champions(session_factory, redis, ended, now=monday) == 2
    assert await jobs.crown_champions(session_factory, redis, ended, now=monday) == 0
    badges = list(await db.scalars(select(LeaderboardBadge).order_by(LeaderboardBadge.goal)))
    assert [(b.user_id, b.goal, b.title) for b in badges] == [
        (jee, "jee", "Physics Champion · Week 40"),
        (neet_a, "neet", "Physics Champion · Week 40"),
    ]
    assert await jobs.send_recaps(session_factory, redis, ended) == 2
    assert await jobs.send_recaps(session_factory, redis, ended) == 0
    assert await count_inbox(db, neet_b, "weekly_result") == 1
    assert await count_inbox(db, neet_a, "achievement") == 1


@pytest.fixture
async def resources(
    engine: AsyncEngine, session_factory: async_sessionmaker[AsyncSession], redis: Redis
) -> AsyncIterator[Resources]:
    async with httpx.AsyncClient() as http:
        yield Resources(engine=engine, sessionmaker=session_factory, redis=redis, http=http)


async def test_job_runs_each_step_once_a_day(
    db_session: AsyncSession, resources: Resources, redis: Redis
) -> None:
    user_id = await make_user(db_session, "jobber")
    await give_xp(db_session, user_id, 10, at=NOW)
    await db_session.commit()
    monday = datetime(2026, 10, 5, 4, 0, tzinfo=IST).astimezone(UTC)
    await give_xp(db_session, user_id, 10, at=monday)
    await db_session.commit()
    await jobs.leaderboards_job(resources, clock=lambda: monday)
    assert await redis.exists("job:lb_snapshot:done:2026-10-05")
    assert await redis.exists("job:lb_rollover:done:2026-10-05")
    assert await redis.exists("job:lb_rebuild:done:2026-10-05")
    assert await members(redis, keys.xp_key("all", keys.week_of(monday))) == [str(user_id)]
    assert await count_inbox(db_session, user_id, "weekly_result") == 0  # not on last week's


# --- The outbox and settlement ----------------------------------------------------------------


async def test_xp_awards_reach_the_board_through_the_outbox(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, settings: Settings
) -> None:
    now = datetime.now(UTC)
    async with session_factory() as db:
        user_id = await make_user(db, "outboxed")
        await award_xp(
            db, user_id, 25, source=XpSource.MISSION, source_key="m:1", ref_id=None, now=now
        )
        await db.commit()
    result = await deliver(session_factory, redis, settings)
    async with session_factory() as db:
        errors = list(await db.scalars(select(OutboxMessage.last_error)))
    assert result.retried == 0, (result, errors)
    assert result.delivered > 0
    key = keys.xp_key("all", keys.week_of(now))
    assert keys.decode(await redis.zscore(key, str(user_id)) or 0) == 25


async def test_settlement_hook_ranks_and_queues_the_match(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, settings: Settings
) -> None:
    now = datetime.now(UTC)
    async with session_factory() as db:
        a, b = await make_user(db, "sa"), await make_user(db, "sb")
        rival = await make_user(db, "rival")
        await rate(db, rival, 1700, scope="physics", played_at=now - timedelta(days=1))
        await rate(db, a, 1720, scope="physics", played_at=now)
        await rate(db, b, 1400, scope="physics", games=4, rd=200, played_at=now)
        await sync(db, redis, rival, now=now)
        match_id = await play(db, "quick_rated", [(a, 80, "win"), (b, 20, "loss")], at=now)
        ctx = SettlementContext(
            db=db,
            match_id=match_id,
            kind="quick_rated",
            status="settled",
            reason="normal",
            subject="physics",
            players=[
                SettledPlayer(a, "win", 80, 4, 5, 1, False, 12),
                SettledPlayer(b, "loss", 20, 1, 5, 2, False, -12),
            ],
            has_bot=False,
            opponents={a: [b], b: [a]},
            coins={},
            questions=5,
            finished_at=now,
            now=now,
            redis=redis,
        )
        pieces = await hooks.settlement_hook(ctx)
        await db.commit()
    assert pieces[a]["rank"] == {"board": "rating:physics", "before": None, "after": 1}
    assert pieces[b]["rank"] == {"board": "rating:physics", "games_to_rank": 6}
    await deliver(session_factory, redis, settings)
    week = keys.week_of(now)
    assert await members(redis, keys.subject_key("neet", "physics", week)) == [str(a), str(b)]
    assert await members(redis, keys.rating_key("neet", "physics")) == [str(a), str(rival)]
    async with session_factory() as db:
        leaders = await hooks.leaders(db, redis, b, ["physics", "chemistry"])
    assert leaders["physics"]["leader"]["user"]["id"] == str(a)
    assert leaders["physics"]["me"] == {"position": 2}
    assert leaders["chemistry"] == {"leader": None, "me": {"position": None}}
    # Games with the Practice Bot never reach the boards.
    async with session_factory() as db:
        bot_pieces = await hooks.settlement_hook(dataclasses.replace(ctx, db=db, has_bot=True))
    assert bot_pieces == {}


# --- API --------------------------------------------------------------------------------------


async def test_api_hub_board_and_friends(client: AsyncClient, redis: Redis) -> None:
    me = await player(client, "hubme")
    pal = await player(client, "hubpal")
    stranger = await player(client, "hubstranger")
    await befriend(client, me, pal)
    for who, amount in ((me, 30), (pal, 50), (stranger, 90)):
        key = keys.xp_key("all", keys.week_of(datetime.now(UTC)))
        await redis.zadd(key, {who.uid: keys.encode(amount, datetime.now(UTC))})

    hub = await client.get("/v1/leaderboards", headers=me.headers)
    assert hub.status_code == 200, hub.text
    body = hub.json()
    weekly = body["boards"][0]
    assert weekly["board"] == "weekly_xp"
    assert weekly["ends_at"].endswith("Z")
    assert weekly["leader"]["user"]["id"] == stranger.uid
    assert weekly["me"] == {"position": 3, "value": 30, "change_1d": None, "games_to_rank": None}
    overall = body["boards"][1]
    assert overall["board"] == "rating:overall"
    assert overall["me"]["games_to_rank"] == 10
    assert body["last_week"] == []

    friends = await client.get("/v1/leaderboards/friends:weekly_xp", headers=me.headers)
    assert friends.status_code == 200, friends.text
    data = friends.json()
    assert [row["user"]["id"] for row in data["items"]] == [pal.uid, me.uid]
    assert data["me"]["position"] == 2
    assert data["players"] == 2
    assert data["not_ranked"] is None
    assert set(data) == {
        "board", "title", "period", "items", "next_cursor", "me", "around_me",
        "not_ranked", "players", "ends_at",
    }  # fmt: skip

    rating = await client.get(
        "/v1/leaderboards/rating%3Aphysics", params={"goal": "neet"}, headers=me.headers
    )
    assert rating.status_code == 200, rating.text
    assert rating.json()["not_ranked"] == {"games_to_rank": 10}
    missing = await client.get(
        "/v1/leaderboards/rating:maths", params={"goal": "neet"}, headers=me.headers
    )
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "BOARD_NOT_FOUND"
    bad = await client.get("/v1/leaderboards", params={"goal": "upsc"}, headers=me.headers)
    assert bad.status_code == 422


async def test_api_profile_shows_positions(
    client: AsyncClient, db_session: AsyncSession, redis: Redis
) -> None:
    me = await player(client, "profme")
    them = await player(client, "profthem")
    await rate(db_session, them.id, 1650)
    await db_session.commit()
    await events.sync_user(db_session, redis, them.id, now=datetime.now(UTC))
    response = await client.get(f"/v1/users/{them.handle}", headers=me.headers)
    assert response.status_code == 200, response.text
    assert response.json()["ratings"][0]["scope"] == "overall"
    assert response.json()["ratings"][0]["position"] == 1
