"""Worker job: ending social restrictions and temporary bans whose time is up."""

import structlog

from app.core.clock import Clock, utc_now
from app.core.jobs import lease
from app.core.resources import Resources
from app.modules.moderation.service import lift_expired

log = structlog.stdlib.get_logger("app.worker")


async def moderation_expiry_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    async with lease(resources.redis, "moderation_expiry", ttl_s=300) as acquired:
        if not acquired:
            return
        async with resources.sessionmaker() as db:
            lifted = await lift_expired(db, resources.redis, now=clock())
        if lifted:
            log.info("moderation.lifted", count=lifted)
