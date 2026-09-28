"""The outbox: enqueueing in the caller's transaction, dispatching, retries and dead letters."""

import logging
from collections.abc import AsyncIterator, Iterator
from datetime import timedelta
from typing import Any

import httpx
import pytest
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.core.clock import utc_now
from app.core.config import Settings
from app.core.logging import configure_logging
from app.core.resources import Resources
from app.modules.analytics.jobs import analytics_retention_job
from app.modules.economy.jobs import hold_reaper_job
from app.modules.notifications.jobs import notifications_retention_job
from app.modules.outbox import service as outbox
from app.modules.outbox.jobs import outbox_cleanup_job, outbox_dispatch_job, purge_outbox
from app.modules.outbox.models import OutboxMessage
from app.modules.outbox.service import MAX_ATTEMPTS, OutboxContext, backoff, enqueue, register
from app.modules.system.models import AppConfig
from tests.helpers import FakeClock, log_events
from tests.platform_helpers import deliver


@pytest.fixture
def logs(settings: Settings, caplog: pytest.LogCaptureFixture) -> pytest.LogCaptureFixture:
    """Structured logs routed through the standard library, as in the app."""
    configure_logging(settings)
    caplog.set_level(logging.INFO)
    return caplog


@pytest.fixture
def handled() -> Iterator[list[tuple[str, dict[str, Any]]]]:
    """Registers ``test.*`` handlers for one test and removes them afterwards."""
    calls: list[tuple[str, dict[str, Any]]] = []

    async def ok(ctx: OutboxContext, payload: dict[str, Any]) -> None:
        calls.append(("ok", payload))
        # Writes join the dispatcher's transaction.
        ctx.db.add(AppConfig(key=f"outbox-test:{payload['n']}", value={"attempt": ctx.attempt}))

    async def flaky(ctx: OutboxContext, payload: dict[str, Any]) -> None:
        calls.append(("flaky", payload))
        ctx.db.add(AppConfig(key=f"outbox-flaky:{ctx.attempt}", value={}))
        await ctx.db.flush()
        if ctx.attempt < 3:
            raise RuntimeError(f"attempt {ctx.attempt} fails")

    async def broken(_ctx: OutboxContext, payload: dict[str, Any]) -> None:
        calls.append(("broken", payload))
        raise ValueError("always fails")

    register("test.ok", ok)
    register("test.flaky", flaky)
    register("test.broken", broken)
    yield calls
    for topic in ("test.ok", "test.flaky", "test.broken"):
        outbox._HANDLERS.pop(topic, None)


async def pending(db: AsyncSession) -> int:
    count = await db.scalar(
        select(func.count()).where(
            OutboxMessage.delivered_at.is_(None), OutboxMessage.dead_at.is_(None)
        )
    )
    return int(count or 0)


async def config_keys(db: AsyncSession, prefix: str) -> list[str]:
    rows = await db.scalars(select(AppConfig.key).where(AppConfig.key.startswith(prefix)))
    return sorted(rows)


def test_backoff_doubles_up_to_an_hour() -> None:
    assert [backoff(n).total_seconds() for n in (1, 2, 3, 4)] == [5, 10, 20, 40]
    assert backoff(30) == timedelta(hours=1)


def test_a_topic_has_one_handler(handled: list[Any]) -> None:
    async def other(_ctx: OutboxContext, _payload: dict[str, Any]) -> None:
        return None

    with pytest.raises(ValueError, match="already has a handler"):
        register("test.ok", other)


async def test_enqueue_stores_a_key_once(db_session: AsyncSession) -> None:
    assert await enqueue(db_session, "test.ok", {"n": 1}, key="k1") is True
    assert await enqueue(db_session, "test.ok", {"n": 2}, key="k1") is False

    [message] = await db_session.scalars(select(OutboxMessage).where(OutboxMessage.key == "k1"))
    assert (message.topic, message.payload, message.attempts) == ("test.ok", {"n": 1}, 0)


async def test_dispatch_runs_handlers_and_marks_messages_delivered(
    handled: list[Any],
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    redis: Redis,
    settings: Settings,
) -> None:
    for n in range(3):
        await enqueue(db_session, "test.ok", {"n": n}, key=f"ok:{n}")
    await enqueue(
        db_session, "test.ok", {"n": 9}, key="later", available_at=utc_now() + timedelta(minutes=5)
    )
    await db_session.commit()

    result = await deliver(session_factory, redis, settings)

    assert (result.claimed, result.delivered) == (3, 3)
    assert [payload["n"] for _, payload in handled] == [0, 1, 2]
    assert await config_keys(db_session, "outbox-test:") == [
        "outbox-test:0",
        "outbox-test:1",
        "outbox-test:2",
    ]
    assert await pending(db_session) == 1  # the delayed one
    again = await deliver(session_factory, redis, settings)
    assert again.claimed == 0

    later = await deliver(session_factory, redis, settings, now=utc_now() + timedelta(minutes=6))
    assert later.delivered == 1


async def test_a_failing_handler_is_retried_with_backoff_and_its_writes_undone(
    handled: list[Any],
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    redis: Redis,
    settings: Settings,
    logs: pytest.LogCaptureFixture,
) -> None:
    await enqueue(db_session, "test.flaky", {"n": 1}, key="flaky")
    await enqueue(db_session, "test.ok", {"n": 2}, key="neighbour")
    await db_session.commit()
    now = utc_now()

    first = await deliver(session_factory, redis, settings, now=now)

    assert (first.delivered, first.retried) == (1, 1)
    message = await db_session.scalar(
        select(OutboxMessage)
        .where(OutboxMessage.key == "flaky")
        .execution_options(populate_existing=True)
    )
    assert message is not None
    assert message.attempts == 1
    assert message.available_at == now + backoff(1)
    assert message.last_error == "RuntimeError: attempt 1 fails"
    # The failed attempt's write was rolled back; the neighbour's delivery was not.
    assert await config_keys(db_session, "outbox-flaky:") == []
    assert await config_keys(db_session, "outbox-test:") == ["outbox-test:2"]
    [retry] = log_events(logs, "outbox.retry")
    assert retry["key"] == "flaky"

    # Not due before the backoff has passed.
    assert (
        await deliver(session_factory, redis, settings, now=now + timedelta(seconds=4))
    ).claimed == 0
    await deliver(session_factory, redis, settings, now=now + timedelta(seconds=5))
    third = await deliver(session_factory, redis, settings, now=now + timedelta(minutes=1))

    assert third.delivered == 1
    assert await config_keys(db_session, "outbox-flaky:") == ["outbox-flaky:3"]
    await db_session.refresh(message)
    assert message.delivered_at is not None
    assert message.last_error is None


async def test_messages_are_dead_lettered_after_the_last_attempt(
    handled: list[Any],
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    redis: Redis,
    settings: Settings,
    logs: pytest.LogCaptureFixture,
) -> None:
    await enqueue(db_session, "test.broken", {"n": 1}, key="broken")
    await enqueue(db_session, "test.unknown", {"n": 2}, key="unknown")
    await db_session.commit()
    now = utc_now()

    for attempt in range(MAX_ATTEMPTS):
        result = await deliver(session_factory, redis, settings, now=now + timedelta(days=attempt))
        assert result.claimed == 2

    assert result.dead == 2
    assert await pending(db_session) == 0
    dead = {event["key"]: event for event in log_events(logs, "outbox.dead_letter")}
    assert dead["broken"]["error"] == "ValueError: always fails"
    assert dead["unknown"]["error"] == "no handler for topic 'test.unknown'"
    assert (
        await deliver(session_factory, redis, settings, now=now + timedelta(days=30))
    ).claimed == 0


async def test_purge_keeps_recent_and_pending_messages(
    handled: list[Any],
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    redis: Redis,
    settings: Settings,
) -> None:
    await enqueue(db_session, "test.ok", {"n": 1}, key="done")
    await db_session.commit()
    now = utc_now()
    await deliver(session_factory, redis, settings, now=now)
    await enqueue(
        db_session, "test.ok", {"n": 2}, key="waiting", available_at=now + timedelta(days=30)
    )
    await db_session.commit()

    assert await purge_outbox(db_session, now=now + timedelta(days=6)) == 0
    assert await purge_outbox(db_session, now=now + timedelta(days=8)) == 1
    keys = await db_session.scalars(select(OutboxMessage.key))
    assert list(keys) == ["waiting"]


@pytest.fixture
async def resources(
    engine: AsyncEngine, session_factory: async_sessionmaker[AsyncSession], redis: Redis
) -> AsyncIterator[Resources]:
    """Worker resources whose sessions stay inside the test transaction."""
    async with httpx.AsyncClient() as http:
        yield Resources(engine=engine, sessionmaker=session_factory, redis=redis, http=http)


async def test_the_worker_jobs_dispatch_and_trim(
    handled: list[Any],
    resources: Resources,
    db_session: AsyncSession,
    settings: Settings,
    logs: pytest.LogCaptureFixture,
) -> None:
    for n in range(3):
        await enqueue(db_session, "test.ok", {"n": n}, key=f"job:{n}")
    await db_session.commit()

    await outbox_dispatch_job(resources, settings=settings)

    assert await pending(db_session) == 0
    later = FakeClock(utc_now() + timedelta(days=8))
    await outbox_cleanup_job(resources, clock=later)
    await notifications_retention_job(resources, clock=later)
    await analytics_retention_job(resources, clock=later)
    await hold_reaper_job(resources, clock=later)
    assert await db_session.scalar(select(func.count()).select_from(OutboxMessage)) == 0
    assert log_events(logs, "outbox.purged")[0]["messages"] == 3
    assert log_events(logs, "notifications.purged")
    assert log_events(logs, "analytics.purged")
