"""Worker jobs for tournaments.

- ``tournament_tick`` (every second): runs every due lifecycle step. Replicas share the work
  through ``FOR UPDATE SKIP LOCKED``, so no lease is needed.
- ``tournament_templates`` (every 10 minutes): creates the recurring templates' instances 7
  days ahead; ``UQ(template_id, starts_at)`` keeps it idempotent.
"""

from app.core.clock import utc_now
from app.core.config import get_settings
from app.core.jobs import lease
from app.core.resources import Resources
from app.modules.matches.ports import integrations
from app.modules.matches.settlement import SettleDeps
from app.modules.tournaments.lifecycle import expand_templates, run_due


async def tournament_tick_job(resources: Resources) -> None:
    deps = SettleDeps(
        redis=resources.redis,
        sessionmaker=resources.sessionmaker,
        settings=get_settings(),
        integrations=integrations,
    )
    await run_due(deps)


async def tournament_templates_job(resources: Resources) -> None:
    async with lease(resources.redis, "tournament_templates", ttl_s=300) as acquired:
        if not acquired:
            return
        async with resources.sessionmaker() as db:
            await expand_templates(db, now=utc_now(), days=get_settings().tournament_days_ahead)
            await db.commit()
