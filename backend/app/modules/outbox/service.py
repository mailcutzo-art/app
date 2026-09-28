"""Enqueueing outbox messages, the handler registry and the dispatcher.

Writers call ``enqueue`` inside their own transaction, so the effect is recorded exactly when
the change commits. The worker's ``outbox_dispatch_job`` claims due rows with ``FOR UPDATE SKIP
LOCKED`` (replicas share the work without a lease), runs the topic's handler and marks the row
delivered in the same transaction as whatever the handler wrote. A failing handler is retried
with exponential backoff and dead-lettered after ``MAX_ATTEMPTS``.

Delivery is at least once: a crash after a handler's external call (a Redis publish, a push)
but before the commit runs it again, so every handler must be idempotent.

Modules register handlers at import time::

    register("notify.push", send_push)

and list that module in ``HANDLER_MODULES`` so the worker imports it before dispatching.
"""

import importlib
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

import httpx
import structlog
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.ids import new_id
from app.modules.outbox.models import OutboxMessage

log = structlog.stdlib.get_logger("app.outbox")

MAX_ATTEMPTS = 8
BASE_BACKOFF_S = 5
MAX_BACKOFF_S = 3600
ERROR_MAX_CHARS = 500

# Modules whose import registers outbox handlers; the dispatcher imports them first.
HANDLER_MODULES: tuple[str, ...] = (
    "app.modules.notifications.delivery",
    "app.modules.progression.achievements",
    "app.modules.matches.withdraw",
    "app.modules.tournaments.events",
    "app.modules.rooms.invites",
)


@dataclass(frozen=True, slots=True)
class OutboxContext:
    """What a handler gets besides the payload. ``db`` is the dispatcher's transaction: rows a
    handler writes commit together with the message being marked delivered."""

    db: AsyncSession
    redis: Redis
    http: httpx.AsyncClient
    settings: Settings
    now: datetime
    message_id: uuid.UUID
    key: str
    attempt: int  # 1 on the first try


Handler = Callable[[OutboxContext, dict[str, Any]], Awaitable[None]]

_HANDLERS: dict[str, Handler] = {}


def register(topic: str, handler: Handler) -> None:
    """Route messages of ``topic`` to ``handler`` (one handler per topic)."""
    existing = _HANDLERS.get(topic)
    if existing is not None and existing is not handler:
        raise ValueError(f"outbox topic {topic!r} already has a handler")
    _HANDLERS[topic] = handler


def handler_for(topic: str) -> Handler | None:
    return _HANDLERS.get(topic)


def load_handlers() -> None:
    """Import every module in ``HANDLER_MODULES`` (registration happens on import)."""
    for module in HANDLER_MODULES:
        importlib.import_module(module)


async def enqueue(
    db: AsyncSession,
    topic: str,
    payload: dict[str, Any],
    *,
    key: str,
    available_at: datetime | None = None,
) -> bool:
    """Record a message in the caller's transaction; ``False`` if ``key`` was enqueued before.

    ``payload`` must be JSON-serialisable (ids as strings). ``available_at`` delays delivery.
    """
    values: dict[str, Any] = {"id": new_id(), "topic": topic, "payload": payload, "key": key}
    if available_at is not None:
        values["available_at"] = available_at
    inserted = await db.scalar(
        insert(OutboxMessage)
        .values(**values)
        .on_conflict_do_nothing(index_elements=[OutboxMessage.key])
        .returning(OutboxMessage.id)
    )
    return inserted is not None


def backoff(attempts: int) -> timedelta:
    """Delay before the next try after ``attempts`` failures: 5 s, 10 s, 20 s ... up to 1 h."""
    return timedelta(seconds=min(MAX_BACKOFF_S, BASE_BACKOFF_S * 2 ** max(0, attempts - 1)))


@dataclass(frozen=True, slots=True)
class DispatchResult:
    claimed: int
    delivered: int
    retried: int
    dead: int


async def dispatch_due(
    db: AsyncSession,
    *,
    redis: Redis,
    http: httpx.AsyncClient,
    settings: Settings,
    now: datetime,
    limit: int = 100,
) -> DispatchResult:
    """Claim up to ``limit`` due messages, run their handlers and commit the outcome.

    Each handler runs in a SAVEPOINT: a failure undoes only that handler's writes, and the
    row is rescheduled (or dead-lettered) in the same commit as its neighbours' deliveries.
    """
    load_handlers()
    messages = (
        await db.scalars(
            select(OutboxMessage)
            .where(
                OutboxMessage.delivered_at.is_(None),
                OutboxMessage.dead_at.is_(None),
                OutboxMessage.available_at <= now,
            )
            .order_by(OutboxMessage.available_at, OutboxMessage.id)
            .limit(limit)
            .with_for_update(skip_locked=True)
        )
    ).all()
    delivered = retried = dead = 0
    for message in messages:
        message.attempts += 1
        error = await _run(db, message, redis=redis, http=http, settings=settings, now=now)
        if error is None:
            message.delivered_at = now
            message.last_error = None
            delivered += 1
            continue
        message.last_error = error[:ERROR_MAX_CHARS]
        if message.attempts >= MAX_ATTEMPTS:
            message.dead_at = now
            dead += 1
            log.error(
                "outbox.dead_letter",
                topic=message.topic,
                key=message.key,
                attempts=message.attempts,
                error=message.last_error,
            )
        else:
            message.available_at = now + backoff(message.attempts)
            retried += 1
            log.warning(
                "outbox.retry",
                topic=message.topic,
                key=message.key,
                attempts=message.attempts,
                error=message.last_error,
            )
    await db.commit()
    return DispatchResult(claimed=len(messages), delivered=delivered, retried=retried, dead=dead)


async def _run(
    db: AsyncSession,
    message: OutboxMessage,
    *,
    redis: Redis,
    http: httpx.AsyncClient,
    settings: Settings,
    now: datetime,
) -> str | None:
    """Run the message's handler; the error text if it failed."""
    handler = handler_for(message.topic)
    if handler is None:
        # Possibly a message from a newer release, whose handler this worker doesn't know yet.
        return f"no handler for topic {message.topic!r}"
    context = OutboxContext(
        db=db,
        redis=redis,
        http=http,
        settings=settings,
        now=now,
        message_id=message.id,
        key=message.key,
        attempt=message.attempts,
    )
    try:
        async with db.begin_nested():
            await handler(context, dict(message.payload))
    except Exception as exc:
        log.debug("outbox.handler_failed", topic=message.topic, exc_info=exc)
        return f"{type(exc).__name__}: {exc}"
    return None
