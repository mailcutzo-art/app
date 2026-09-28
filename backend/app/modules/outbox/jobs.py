"""Worker jobs for the outbox: dispatching due messages and trimming delivered ones."""

from datetime import datetime, timedelta

import structlog
from sqlalchemy import Delete, delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST, Clock, utc_now
from app.core.config import Settings, get_settings
from app.core.jobs import once_per_day
from app.core.resources import Resources
from app.modules.outbox.models import OutboxMessage
from app.modules.outbox.service import dispatch_due

log = structlog.stdlib.get_logger("app.worker")

DISPATCH_BATCH = 100
# One tick drains at most this many batches, so a backlog can't starve the other jobs' logs.
MAX_BATCHES_PER_TICK = 20
DELIVERED_KEEP = timedelta(days=7)
DEAD_KEEP = timedelta(days=30)
CLEANUP_BATCH = 5000


async def outbox_dispatch_job(
    resources: Resources, *, clock: Clock = utc_now, settings: Settings | None = None
) -> None:
    """Deliver everything that is due. Safe on several replicas (``SKIP LOCKED``)."""
    settings = settings or get_settings()
    for _ in range(MAX_BATCHES_PER_TICK):
        async with resources.sessionmaker() as db:
            result = await dispatch_due(
                db,
                redis=resources.redis,
                http=resources.http,
                settings=settings,
                now=clock(),
                limit=DISPATCH_BATCH,
            )
        if result.retried or result.dead:
            log.info(
                "outbox.dispatched",
                delivered=result.delivered,
                retried=result.retried,
                dead=result.dead,
            )
        if result.claimed < DISPATCH_BATCH:
            return


async def purge_outbox(db: AsyncSession, *, now: datetime) -> int:
    """Delete delivered messages after 7 days and dead ones after 30 (in batches)."""

    def statement() -> Delete:
        old = (
            select(OutboxMessage.id)
            .where(
                or_(
                    OutboxMessage.delivered_at < now - DELIVERED_KEEP,
                    OutboxMessage.dead_at < now - DEAD_KEEP,
                )
            )
            .limit(CLEANUP_BATCH)
        )
        return delete(OutboxMessage).where(OutboxMessage.id.in_(old.scalar_subquery()))

    total = 0
    while True:
        result = await db.execute(statement())
        count = int(getattr(result, "rowcount", 0) or 0)
        await db.commit()
        total += count
        if count < CLEANUP_BATCH:
            return total


async def outbox_cleanup_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()

    async def run() -> None:
        async with resources.sessionmaker() as db:
            purged = await purge_outbox(db, now=now)
        log.info("outbox.purged", messages=purged)

    await once_per_day(
        resources.redis, "outbox_cleanup", now.astimezone(IST).date(), run, lease_ttl_s=1800
    )
