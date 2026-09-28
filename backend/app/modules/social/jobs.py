"""Worker job: the activity feed keeps 30 days of events."""

import structlog

from app.core.clock import IST, Clock, utc_now
from app.core.jobs import once_per_day
from app.core.resources import Resources
from app.modules.social.activity import purge_activity

log = structlog.stdlib.get_logger("app.worker")


async def activity_retention_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()

    async def run() -> None:
        async with resources.sessionmaker() as db:
            deleted = await purge_activity(db, now=now)
            await db.commit()
        log.info("activity.purged", deleted=deleted)

    await once_per_day(
        resources.redis, "activity_retention", now.astimezone(IST).date(), run, lease_ttl_s=1800
    )
