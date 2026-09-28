"""Streaks: qualifying IST days, freezes, rewards, the calendar and the worker jobs."""

import secrets
import uuid
from datetime import date, timedelta

from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.progression import streaks
from app.modules.progression.jobs import remind_streaks_at_risk, roll_over_streaks
from app.modules.progression.models import StreakDay, UserStreak
from app.modules.progression.service import EventKind, record_event
from tests.helpers import FakeClock
from tests.learn_helpers import player, signin
from tests.platform_helpers import bare_user, user_id
from tests.progression_helpers import answered_on, balance, count_inbox, inbox, ist, ledger

DAY = date(2026, 9, 1)


def day(n: int) -> date:
    """The n-th day of the test month (``day(1)`` is ``DAY``)."""
    return DAY + timedelta(days=n - 1)


async def evaluate(
    db: AsyncSession, user: uuid.UUID, n: int, hour: int = 12
) -> streaks.StreakStatus:
    return await streaks.evaluate(db, user, now=ist(day(n), hour))


async def test_ten_answers_or_one_battle_make_a_streak_day(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    await answered_on(db_session, user, day(1), 9)

    assert (await evaluate(db_session, user, 1)).today_done is False  # 9 answers aren't enough
    await answered_on(db_session, user, day(1), 1)
    first = await evaluate(db_session, user, 1)
    assert (first.days, first.today_done, first.extended) == (1, True, True)
    assert (await evaluate(db_session, user, 1)).extended is False  # already counted

    await record_event(
        db_session, user, kind=EventKind.BATTLE_FINISHED, event_id="match:1", now=ist(day(2))
    )
    second = await evaluate(db_session, user, 2)
    assert (second.days, second.best, second.today_done) == (2, 2, True)
    # Day 3 hasn't qualified yet, but it isn't over either.
    third = await evaluate(db_session, user, 3)
    assert (third.days, third.today_done) == (2, False)


async def test_a_battle_counts_once_on_its_ist_day(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    late = ist(day(1), 23, 50)
    for _ in range(2):  # the same match reported twice
        await record_event(db_session, user, kind="battle_finished", event_id="m:1", now=late)
    row = await db_session.get_one(StreakDay, (user, day(1)))
    assert row.battles_finished == 1

    # Five minutes after midnight (IST) it is the next day: yesterday counted, today is open.
    status = await streaks.evaluate(db_session, user, now=ist(day(2), 0, 5))
    assert (status.days, status.today_done) == (1, False)
    assert (await streaks.calendar(db_session, user, days=2, now=ist(day(2), 0, 5)))[0].state


async def test_a_missed_day_ends_the_streak_without_a_freeze(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    for n in (1, 2):
        await answered_on(db_session, user, day(n), 10)
        await evaluate(db_session, user, n)

    # Day 3 is missed; on day 4 the streak is gone.
    status = await evaluate(db_session, user, 4)

    assert (status.days, status.best, status.today_done) == (0, 2, False)
    [lost] = await inbox(db_session, user, "streak_lost")
    assert lost.title == "Streak lost"
    assert lost.body.startswith("Your 2-day streak ended.")
    # It is reported once, however often the streak is looked at.
    await evaluate(db_session, user, 4)
    assert await count_inbox(db_session, user, "streak_lost") == 1
    # Activity starts a new one.
    await answered_on(db_session, user, day(4), 12)
    assert (await evaluate(db_session, user, 4)).days == 1


async def test_a_freeze_covers_a_missed_day(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    await answered_on(db_session, user, day(1), 10)
    await evaluate(db_session, user, 1)
    streak = await db_session.get_one(UserStreak, user)
    streak.freezes = 2
    await db_session.flush()

    # Days 2 and 3 missed: both freezes are used; day 4 counts again.
    await answered_on(db_session, user, day(4), 10)
    status = await evaluate(db_session, user, 4)

    assert (status.days, status.freezes, status.today_done) == (2, 0, True)
    calendar = await streaks.calendar(db_session, user, days=5, now=ist(day(4)))
    assert [(c.day, c.state and c.state.value) for c in calendar] == [
        (DAY - timedelta(days=1), None),
        (day(1), "active"),
        (day(2), "frozen"),
        (day(3), "frozen"),
        (day(4), "active"),
    ]
    notices = await inbox(db_session, user, "streak_freeze_used")
    assert [n.title for n in notices] == ["Streak freeze used"] * 2
    assert notices[0].body == "You missed 2 Sep, so a freeze kept your 1-day streak. 1 left."

    # Day 5 and 6 missed with no freezes left: lost.
    assert (await evaluate(db_session, user, 7)).days == 0


async def test_long_streaks_pay_on_day_7_and_day_30(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)
    for n in range(1, 31):
        await answered_on(db_session, user, day(n), 10)
        if n in (1, 5, 7, 20, 30):  # looked at now and then; the days in between still count
            await evaluate(db_session, user, n)

    status = await evaluate(db_session, user, 30)

    assert (status.days, status.best) == (30, 30)
    assert await ledger(db_session, user) == [
        (30, "streak_bonus", "7-day streak"),
        (100, "streak_bonus", "30-day streak"),
    ]


async def test_buying_freezes(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    clock.now = ist(day(1), 10)
    asha = await player(client, "asha")  # 100 welcome coins
    uid = await user_id(client, asha)
    key = secrets.token_hex(8)

    first = await client.post("/v1/me/streak/freezes", headers={**asha, "Idempotency-Key": key})
    replay = await client.post("/v1/me/streak/freezes", headers={**asha, "Idempotency-Key": key})
    second = await client.post(
        "/v1/me/streak/freezes", headers={**asha, "Idempotency-Key": secrets.token_hex(8)}
    )
    third = await client.post(
        "/v1/me/streak/freezes", headers={**asha, "Idempotency-Key": secrets.token_hex(8)}
    )

    assert first.status_code == 200, first.text
    assert first.json()["freezes"] == 1
    assert replay.headers.get("Idempotent-Replayed") == "true"
    assert second.json()["freezes"] == 2
    assert third.status_code == 409
    assert third.json()["error"]["code"] == "FREEZE_LIMIT"
    assert await balance(db_session, uid) == 0
    assert [entry[1:] for entry in await ledger(db_session, uid)] == [
        ("welcome", "Welcome bonus"),
        ("streak_freeze", "Streak freeze"),
        ("streak_freeze", "Streak freeze"),
    ]
    # The ledger key stops a double purchase even if the cached response is gone.
    status = await streaks.buy_freeze(db_session, uid, key=key, now=clock())
    assert status.freezes == 2


async def test_a_freeze_needs_coins(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    clock.now = ist(day(1), 10)
    asha = await player(client, "asha")
    uid = await user_id(client, asha)
    for _ in range(2):
        await streaks.buy_freeze(db_session, uid, key=secrets.token_hex(8), now=clock())
    streak = await db_session.get_one(UserStreak, uid)
    streak.freezes = 0
    await db_session.flush()

    response = await client.post(
        "/v1/me/streak/freezes", headers={**asha, "Idempotency-Key": secrets.token_hex(8)}
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "INSUFFICIENT_COINS"


async def test_the_streak_calendar(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    clock.now = ist(day(1), 10)
    asha = await player(client, "asha")
    uid = await user_id(client, asha)
    await client.get("/v1/me/streak", headers=asha)  # starts tracking on day 1
    await answered_on(db_session, uid, day(1), 10)
    await answered_on(db_session, uid, day(3), 10)
    streak = await db_session.get_one(UserStreak, uid)
    streak.freezes = 1
    await db_session.flush()

    clock.now = ist(day(3), 23, 59)
    asha = await signin(client, "asha")
    response = await client.get("/v1/me/streak?days=4", headers=asha)

    assert response.status_code == 200, response.text
    assert response.json() == {
        "days": 2,
        "best": 2,
        "today_done": True,
        "freezes": 0,
        "max_freezes": 2,
        "freeze_price": 50,
        "calendar": [
            {"day": "2026-08-31", "state": None},
            {"day": "2026-09-01", "state": "active"},
            {"day": "2026-09-02", "state": "frozen"},
            {"day": "2026-09-03", "state": "active"},
        ],
        "freezes_used": ["2026-09-02"],
    }
    missions = (await client.get("/v1/me/missions", headers=asha)).json()
    assert missions["streak"] == {"days": 2, "today_done": True, "freezes": 0}
    bad = await client.get("/v1/me/streak?days=0", headers=asha)
    assert bad.status_code == 422


async def test_practice_answers_extend_the_streak(client: AsyncClient, clock: FakeClock) -> None:
    from tests.learn_helpers import answer, start, upload

    clock.now = ist(day(1), 10)
    asha = await player(client, "asha")
    session = await start(client, asha, chapters=["kinematics", "laws-of-motion"], count=12)
    assert len(session["questions"]) >= streaks.MIN_ANSWERS
    await upload(
        client, asha, session["session_id"], [answer(q, at=clock()) for q in session["questions"]]
    )

    body = (await client.get("/v1/me/streak", headers=asha)).json()

    assert (body["days"], body["today_done"]) == (1, True)


async def test_rollover_settles_yesterday_for_everyone(
    db_session: AsyncSession, session_factory: async_sessionmaker[AsyncSession]
) -> None:
    kept = await bare_user(db_session, "kept")
    lost = await bare_user(db_session, "lost")
    idle = await bare_user(db_session, "idle")
    for user in (kept, lost):
        await answered_on(db_session, user, day(1), 10)
        await evaluate(db_session, user, 1)
    await answered_on(db_session, kept, day(2), 10)
    await db_session.commit()

    evaluated = await roll_over_streaks(session_factory, now=ist(day(3), 0, 10))

    assert evaluated == 2  # users without a streak are left alone
    rows = {
        row.user_id: row
        for row in await db_session.scalars(
            select(UserStreak).execution_options(populate_existing=True)
        )
    }
    assert (rows[kept].current, rows[kept].checked_through) == (2, day(2))
    assert rows[lost].current == 0
    assert idle not in rows
    assert await count_inbox(db_session, lost, "streak_lost") == 1


async def test_evening_reminder_only_for_live_streaks_with_nothing_today(
    db_session: AsyncSession, session_factory: async_sessionmaker[AsyncSession]
) -> None:
    quiet = await bare_user(db_session, "quiet")
    busy = await bare_user(db_session, "busy")
    done = await bare_user(db_session, "done")
    none = await bare_user(db_session, "none")
    for user in (quiet, busy, done):
        await answered_on(db_session, user, day(1), 10)
        await evaluate(db_session, user, 1)
    await answered_on(db_session, busy, day(2), 3)  # started today, not done yet
    await answered_on(db_session, done, day(2), 10)
    await answered_on(db_session, none, day(2), 1)
    await db_session.commit()

    evening = ist(day(2), 19, 5)
    sent = await remind_streaks_at_risk(session_factory, now=evening)
    again = await remind_streaks_at_risk(session_factory, now=evening)

    assert (sent, again) == (1, 0)
    [notice] = await inbox(db_session, quiet, "streak_risk")
    assert notice.title == "Keep your 1-day streak"
    for user in (busy, done, none):
        assert await count_inbox(db_session, user, "streak_risk") == 0


async def test_streaks_job_runs_each_part_once_a_day(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, db_session: AsyncSession
) -> None:
    from dataclasses import dataclass

    from app.modules.progression.jobs import streaks_job

    user = await bare_user(db_session)
    await answered_on(db_session, user, day(1), 10)
    await evaluate(db_session, user, 1)
    await db_session.commit()

    @dataclass
    class FakeResources:
        sessionmaker: async_sessionmaker[AsyncSession]
        redis: Redis

    resources = FakeResources(session_factory, redis)
    await streaks_job(resources, clock=lambda: ist(day(2), 12))  # type: ignore[arg-type]
    assert await count_inbox(db_session, user, "streak_risk") == 0  # too early
    await streaks_job(resources, clock=lambda: ist(day(2), 19, 30))  # type: ignore[arg-type]
    assert await count_inbox(db_session, user, "streak_risk") == 1
    assert await redis.exists("job:streak_rollover:done:2026-09-02")
    assert await redis.exists("job:streak_risk:done:2026-09-02")
