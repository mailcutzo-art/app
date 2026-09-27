"""Worker jobs: one replica at a time, closing sessions, answer partitions, question stats."""

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime, timedelta

import httpx
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, insert, select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.core.ids import new_id
from app.core.jobs import lease, once_per_day
from app.core.resources import Resources
from app.modules.content.jobs import question_stats_job, rebuild_question_stats
from app.modules.content.models import Question, QuestionStats
from app.modules.practice.jobs import (
    attempt_partitions_job,
    practice_housekeeping,
    practice_housekeeping_job,
)
from app.modules.practice.models import AttemptKey, PracticeSession, QuestionAttempt
from app.modules.users.models import User
from tests.helpers import FakeClock
from tests.learn_helpers import answer, player, signin, start, upload


@pytest.fixture
async def resources(
    engine: AsyncEngine, session_factory: async_sessionmaker[AsyncSession], redis: Redis
) -> AsyncIterator[Resources]:
    """Worker resources whose sessions stay inside the test transaction."""
    async with httpx.AsyncClient() as http:
        yield Resources(engine=engine, sessionmaker=session_factory, redis=redis, http=http)


async def test_once_per_day_runs_a_job_once_and_retries_failures(redis: Redis) -> None:
    runs: list[str] = []

    async def fails() -> None:
        runs.append("fail")
        raise RuntimeError("boom")

    async def works() -> None:
        runs.append("ok")

    day = date(2026, 9, 27)
    with pytest.raises(RuntimeError):
        await once_per_day(redis, "demo", day, fails, lease_ttl_s=60)
    assert await once_per_day(redis, "demo", day, works, lease_ttl_s=60) is True
    assert await once_per_day(redis, "demo", day, works, lease_ttl_s=60) is False
    assert await once_per_day(redis, "demo", day + timedelta(days=1), works, lease_ttl_s=60)
    assert runs == ["fail", "ok", "ok"]


async def test_a_lease_is_held_by_one_replica(redis: Redis) -> None:
    async with lease(redis, "demo", ttl_s=60) as first:
        async with lease(redis, "demo", ttl_s=60) as second:
            assert (first, second) == (True, False)
        assert await redis.exists("lease:demo")  # the loser didn't release it
    async with lease(redis, "demo", ttl_s=60) as again:
        assert again is True
    runs: list[str] = []

    async def work() -> None:
        runs.append("run")

    async with lease(redis, "demo", ttl_s=60):
        assert await once_per_day(redis, "demo", date(2026, 9, 27), work, lease_ttl_s=60) is False
    assert runs == []


async def test_housekeeping_closes_expired_sessions_and_forgets_old_data(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    asha = await player(client, "asha")
    old = await start(client, asha)
    clock.advance(days=20)
    asha = await signin(client, "asha")
    expired = await start(client, asha)
    fresh = await start(client, asha)
    await client.post(f"/v1/practice/sessions/{fresh['session_id']}/finish", headers=asha)
    user_id = await db_session.scalar(select(User.id).where(User.email == "asha@example.com"))
    db_session.add(AttemptKey(user_id=user_id, client_answer_id="recent", created_at=clock()))
    db_session.add(
        AttemptKey(
            user_id=user_id, client_answer_id="ancient", created_at=clock() - timedelta(days=15)
        )
    )
    await db_session.flush()

    done = await practice_housekeeping(db_session, now=clock() + timedelta(days=71))

    sessions = {
        str(row.id): row
        for row in await db_session.scalars(
            select(PracticeSession).execution_options(populate_existing=True)
        )
    }
    assert old["session_id"] not in sessions  # past the 90 days of history
    closed = sessions[expired["session_id"]]
    assert closed.finished_at == closed.expires_at  # expired unfinished: closed at expiry
    assert sessions[fresh["session_id"]].finished_at < closed.expires_at  # finished earlier
    assert (done.closed, done.deleted) == (2, 1)  # the old one was closed, then deleted
    keys = set(await db_session.scalars(select(AttemptKey.client_answer_id)))
    assert "ancient" not in keys
    assert done.keys_pruned >= 1


async def test_expired_sessions_show_their_partial_result_in_history(
    client: AsyncClient, clock: FakeClock, resources: Resources
) -> None:
    asha = await player(client, "asha")
    session = await start(client, asha)
    await upload(client, asha, session["session_id"], [answer(session["questions"][0], at=clock())])
    clock.advance(hours=25)

    await practice_housekeeping_job(resources, clock=clock)

    asha = await signin(client, "asha")
    [item] = (await client.get("/v1/me/practice/sessions", headers=asha)).json()["items"]
    assert item["session_id"] == session["session_id"]
    assert item["finished_at"] is not None
    assert (item["answered"], item["correct"]) == (1, 1)
    assert (await client.get("/v1/me/progress", headers=asha)).json()["continue"] is None


async def test_new_partitions_take_over_their_rows_from_the_default_partition(
    db_session: AsyncSession, resources: Resources, clock: FakeClock
) -> None:
    user = User(display_name="Partition Tester")
    db_session.add(user)
    question = await db_session.scalar(
        select(Question).where(Question.external_id == "phy-kin-001")
    )
    await db_session.flush()
    now = await db_session.scalar(select(func.now()))
    far = now + timedelta(days=200)  # beyond the months created so far: the default partition
    await db_session.execute(
        insert(QuestionAttempt).values(
            id=new_id(),
            answered_at=far,
            user_id=user.id,
            question_id=question.id,
            subject_id=question.subject_id,
            chapter_id=question.chapter_id,
            topic_id=question.topic_id,
            category=question.category,
            difficulty=question.difficulty,
            mode="chapter",
            session_id=uuid.uuid4(),
            position=1,
            outcome="correct",
            time_ms=1000,
            first_try=True,
            ist_day=far.date(),
        )
    )
    where = text("SELECT tableoid::regclass::text FROM question_attempts WHERE user_id = :user")
    assert await db_session.scalar(where, {"user": user.id}) == "question_attempts_default"

    created = await db_session.scalar(select(func.ensure_attempt_partitions(8)))

    assert created >= 4
    assert await db_session.scalar(where, {"user": user.id}) == (
        f"question_attempts_{far.astimezone(UTC):%Y_%m}"
    )
    assert await db_session.scalar(select(func.ensure_attempt_partitions(8))) == 0

    # The daily job runs it once per day.
    await attempt_partitions_job(resources, clock=clock)
    assert await resources.redis.exists(f"job:attempt_partitions:done:{clock().date()}")


async def add_attempts(
    db: AsyncSession, user_id: uuid.UUID, question: Question, times: list[int], *, at: datetime
) -> None:
    for index, time_ms in enumerate(times):
        await db.execute(
            insert(QuestionAttempt).values(
                id=new_id(),
                answered_at=at,
                user_id=user_id,
                question_id=question.id,
                subject_id=question.subject_id,
                chapter_id=question.chapter_id,
                topic_id=question.topic_id,
                category=question.category,
                difficulty=question.difficulty,
                mode="chapter",
                session_id=uuid.uuid4(),
                position=index + 1,
                outcome="correct" if time_ms else "skipped",
                time_ms=time_ms,
                first_try=True,
                ist_day=at.date(),
            )
        )


async def test_question_stats_are_rebuilt_from_the_answers(
    db_session: AsyncSession, resources: Resources
) -> None:
    user = User(display_name="Stats Tester")
    db_session.add(user)
    await db_session.flush()
    now = await db_session.scalar(select(func.now()))
    popular, rare = (
        await db_session.scalars(
            select(Question)
            .where(Question.external_id.in_(["phy-kin-001", "phy-kin-002"]))
            .order_by(Question.external_id)
        )
    ).all()
    # 20 recent correct answers (1..20 s), 5 skips, and 30 correct answers from long ago.
    await add_attempts(db_session, user.id, popular, [n * 1000 for n in range(1, 21)], at=now)
    await add_attempts(db_session, user.id, popular, [0] * 5, at=now)
    await add_attempts(db_session, user.id, popular, [99_000] * 30, at=now - timedelta(days=91))
    await add_attempts(db_session, user.id, rare, [5000] * 19, at=now)

    count = await rebuild_question_stats(db_session, now=now)

    stats = {
        row.question_id: row
        for row in await db_session.scalars(
            select(QuestionStats).execution_options(populate_existing=True)
        )
    }
    assert count == await db_session.scalar(select(func.count()).select_from(Question))
    first = stats[popular.id]
    assert (first.attempts, first.correct, first.timed_correct) == (55, 50, 20)
    assert first.typical_ms == 10_500  # the median of 1..20 s, old answers left out
    assert first.p_correct == pytest.approx(50 / 55)
    second = stats[rare.id]
    assert (second.typical_ms, second.timed_correct) == (None, 19)  # too few to be typical
    untouched = next(s for qid, s in stats.items() if qid not in {popular.id, rare.id})
    assert (untouched.attempts, untouched.p_correct, untouched.typical_ms) == (0, None, None)


async def test_the_nightly_job_runs_after_2am_in_india(resources: Resources) -> None:
    evening = FakeClock(datetime(2026, 9, 27, 20, 0, tzinfo=UTC))  # 01:30 IST on the 28th
    night = FakeClock(datetime(2026, 9, 27, 21, 0, tzinfo=UTC))  # 02:30 IST

    await question_stats_job(resources, clock=evening)
    assert not await resources.redis.exists("job:question_stats:done:2026-09-28")
    await question_stats_job(resources, clock=night)
    assert await resources.redis.exists("job:question_stats:done:2026-09-28")
