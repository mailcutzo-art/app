"""Worker job: erasing accounts 30 days after their deletion."""

import structlog

from app.core.clock import Clock, utc_now
from app.core.jobs import lease
from app.core.resources import Resources
from app.modules.users.deletion import erase_due

log = structlog.stdlib.get_logger("app.worker")


async def account_erasure_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    async with lease(resources.redis, "account_erasure", ttl_s=1800) as acquired:
        if not acquired:
            return
        async with resources.sessionmaker() as db:
            erased = await erase_due(db, now=clock())
        if erased:
            log.info("accounts.erased", count=erased)
