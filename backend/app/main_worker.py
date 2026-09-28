"""Background worker process: ``python -m app.main_worker``.

Runs periodic jobs until SIGTERM or SIGINT, then lets in-flight runs finish (up to a grace
period) before closing connections. Coordination between replicas (leases, ``SKIP LOCKED``) is
each job's own business.
"""

import asyncio
import contextlib
import signal
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass

import structlog

from app.core.config import Settings, get_settings
from app.core.logging import configure_logging
from app.core.resources import Resources, open_resources
from app.modules.analytics.jobs import analytics_retention_job
from app.modules.content.jobs import question_stats_job
from app.modules.economy.jobs import hold_reaper_job
from app.modules.matches.jobs import reconcile_matches_job, settle_pending_job
from app.modules.moderation.jobs import moderation_expiry_job
from app.modules.notifications.jobs import notifications_retention_job
from app.modules.outbox.jobs import outbox_cleanup_job, outbox_dispatch_job
from app.modules.practice.jobs import attempt_partitions_job, practice_housekeeping_job
from app.modules.progression.jobs import streaks_job
from app.modules.social.jobs import activity_retention_job
from app.modules.users.jobs import account_erasure_job

SHUTDOWN_GRACE_S = 10.0

log = structlog.stdlib.get_logger("app.worker")


@dataclass(frozen=True, slots=True)
class PeriodicJob:
    name: str
    interval_s: float
    run: Callable[[Resources], Awaitable[None]]


async def heartbeat(_resources: Resources) -> None:
    log.info("worker.heartbeat")


JOBS: tuple[PeriodicJob, ...] = (
    PeriodicJob("heartbeat", 30.0, heartbeat),
    # Close expired practice sessions, delete ones past 90 days, forget old answer ids.
    PeriodicJob("practice_housekeeping", 600.0, practice_housekeeping_job),
    # Once a day: this month's and the next 3 months' partitions of question_attempts.
    PeriodicJob("attempt_partitions", 3600.0, attempt_partitions_job),
    # Once a night (after 02:00 IST): per-question attempts, share correct and typical time.
    PeriodicJob("question_stats", 600.0, question_stats_job),
    # Deliver outbox messages (live inbox events, push, ...); replicas share via SKIP LOCKED.
    PeriodicJob("outbox_dispatch", 1.0, outbox_dispatch_job),
    # Once a day: drop delivered outbox rows after 7 days, dead ones after 30.
    PeriodicJob("outbox_cleanup", 3600.0, outbox_cleanup_job),
    # Refund coin holds stuck for 30 minutes whose match or tournament is gone.
    PeriodicJob("hold_reaper", 60.0, hold_reaper_job),
    # Once a day: the inbox keeps 90 days, analytics 180.
    PeriodicJob("notifications_retention", 3600.0, notifications_retention_job),
    PeriodicJob("analytics_retention", 3600.0, analytics_retention_job),
    # Streaks: settle yesterday after midnight IST, remind players at risk from 19:00 IST.
    PeriodicJob("streaks", 300.0, streaks_job),
    # Lift social restrictions and temporary bans whose time is up.
    PeriodicJob("moderation_expiry", 60.0, moderation_expiry_job),
    # Erase accounts 30 days after deletion (tombstone the user, drop personal data).
    PeriodicJob("account_erasure", 3600.0, account_erasure_job),
    # Once a day: the friends' activity feed keeps 30 days.
    PeriodicJob("activity_retention", 3600.0, activity_retention_job),
    # Matches the rt nodes didn't settle (a crash, Postgres down): retried every 5 s.
    PeriodicJob("settle_pending", 5.0, settle_pending_job),
    # Live matches Redis no longer knows, past their longest duration: voided and refunded.
    PeriodicJob("reconcile_matches", 60.0, reconcile_matches_job),
)


async def run_periodic(job: PeriodicJob, resources: Resources, stop: asyncio.Event) -> None:
    """Run ``job`` every ``interval_s`` (start to start) until ``stop`` is set.

    A failing run is logged and does not stop the schedule.
    """
    loop = asyncio.get_running_loop()
    while not stop.is_set():
        started = loop.time()
        try:
            await job.run(resources)
        except Exception:
            log.exception("worker.job_failed", job=job.name)
        delay = max(0.0, job.interval_s - (loop.time() - started))
        with contextlib.suppress(TimeoutError):
            async with asyncio.timeout(delay):
                await stop.wait()


async def run_worker(settings: Settings, jobs: Sequence[PeriodicJob], stop: asyncio.Event) -> None:
    async with open_resources(settings, component="worker") as resources:
        tasks = [
            asyncio.create_task(run_periodic(job, resources, stop), name=f"job:{job.name}")
            for job in jobs
        ]
        log.info("worker.started", jobs=[job.name for job in jobs])
        await stop.wait()
        log.info("worker.stopping")
        if tasks:
            _, pending = await asyncio.wait(tasks, timeout=SHUTDOWN_GRACE_S)
            for task in pending:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    log.info("worker.stopped")


async def main() -> None:
    settings = get_settings()
    configure_logging(settings)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stop.set)
    await run_worker(settings, JOBS, stop)


if __name__ == "__main__":
    asyncio.run(main())
