"""Worker job: the inbox keeps 90 days."""

import structlog

from app.core.clock import IST, Clock, utc_now
from app.core.jobs import once_per_day
from app.core.resources import Resources
from app.modules.notifications.service import purge_notifications

log = structlog.stdlib.get_logger("app.worker")


async def notifications_retention_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()

    async def run() -> None:
        async with resources.sessionmaker() as db:
            deleted = await purge_notifications(db, now=now)
        log.info("notifications.purged", deleted=deleted)

    await once_per_day(
        resources.redis,
        "notifications_retention",
        now.astimezone(IST).date(),
        run,
        lease_ttl_s=1800,
    )
