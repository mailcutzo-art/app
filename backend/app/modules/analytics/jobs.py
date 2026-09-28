"""Worker job: analytics events are kept for 180 days, session salts for two."""

import structlog

from app.core.clock import IST, Clock, utc_now
from app.core.jobs import once_per_day
from app.core.resources import Resources
from app.modules.analytics.service import purge_analytics

log = structlog.stdlib.get_logger("app.worker")


async def analytics_retention_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()

    async def run() -> None:
        async with resources.sessionmaker() as db:
            deleted = await purge_analytics(db, now=now)
        log.info("analytics.purged", deleted=deleted)

    await once_per_day(
        resources.redis, "analytics_retention", now.astimezone(IST).date(), run, lease_ttl_s=1800
    )
