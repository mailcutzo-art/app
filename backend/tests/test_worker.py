"""The worker's periodic job loop and graceful stop."""

import asyncio
import logging

import pytest

from app.core.config import Settings
from app.core.resources import Resources
from app.main_worker import JOBS, PeriodicJob, heartbeat, run_worker
from tests.helpers import log_events


async def test_jobs_repeat_survive_failures_and_stop_gracefully(
    settings: Settings, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO)
    stop = asyncio.Event()
    runs: list[str] = []

    async def flaky(resources: Resources) -> None:
        runs.append("flaky")
        assert await resources.redis.ping()
        if len(runs) == 1:
            raise RuntimeError("first run fails")
        if len(runs) == 3:
            stop.set()

    await asyncio.wait_for(run_worker(settings, [PeriodicJob("flaky", 0.01, flaky)], stop), 5)

    assert runs == ["flaky", "flaky", "flaky"]
    [failure] = log_events(caplog, "worker.job_failed")
    assert failure["job"] == "flaky"
    assert log_events(caplog, "worker.stopped")


async def test_stop_waits_for_the_running_job(settings: Settings) -> None:
    stop = asyncio.Event()
    finished: list[bool] = []

    async def slow(_resources: Resources) -> None:
        stop.set()
        await asyncio.sleep(0.05)
        finished.append(True)

    await asyncio.wait_for(run_worker(settings, [PeriodicJob("slow", 60, slow)], stop), 5)

    assert finished == [True]


async def test_jobs_are_scheduled(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO)

    assert [(job.name, job.interval_s) for job in JOBS] == [
        ("heartbeat", 30.0),
        ("practice_housekeeping", 600.0),
        ("attempt_partitions", 3600.0),
        ("question_stats", 600.0),
        ("outbox_dispatch", 1.0),
        ("outbox_cleanup", 3600.0),
        ("hold_reaper", 60.0),
        ("notifications_retention", 3600.0),
        ("analytics_retention", 3600.0),
        ("moderation_expiry", 60.0),
        ("account_erasure", 3600.0),
        ("activity_retention", 3600.0),
    ]
    await heartbeat(None)
    assert log_events(caplog, "worker.heartbeat")
