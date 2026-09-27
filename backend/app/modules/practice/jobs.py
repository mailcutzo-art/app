"""Worker jobs for practice: closing expired sessions, trimming old data, answer partitions."""

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta

import structlog
from sqlalchemy import Delete, Update, delete, func, select, tuple_, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import Clock, utc_now
from app.core.jobs import lease, once_per_day
from app.core.resources import Resources
from app.modules.practice.models import AttemptKey, PracticeSession
from app.modules.practice.sessions import HISTORY_DAYS

log = structlog.stdlib.get_logger("app.worker")

BATCH = 1000
# Answer ids are kept past the late-upload window (7 days after a session expires), so a
# re-upload is still recognised as a duplicate while the session could take it.
ATTEMPT_KEY_DAYS = 14
PARTITION_MONTHS_AHEAD = 3


@dataclass(frozen=True, slots=True)
class Housekeeping:
    closed: int
    deleted: int
    keys_pruned: int


async def _in_batches(db: AsyncSession, statement: Callable[[], Update | Delete]) -> int:
    """Run a bounded bulk change until it touches fewer than ``BATCH`` rows, committing each
    batch so locks stay short next to live traffic."""
    total = 0
    while True:
        result = await db.execute(statement())
        count = int(getattr(result, "rowcount", 0) or 0)
        await db.commit()
        total += count
        if count < BATCH:
            return total


async def practice_housekeeping(db: AsyncSession, *, now: datetime) -> Housekeeping:
    """Finish sessions that expired unfinished (their answers so far are the result), delete
    sessions past the history window and forget old answer ids."""

    def close() -> Update:
        stale = (
            select(PracticeSession.id)
            .where(PracticeSession.finished_at.is_(None), PracticeSession.expires_at < now)
            .limit(BATCH)
        )
        return (
            update(PracticeSession)
            .where(PracticeSession.id.in_(stale.scalar_subquery()))
            .values(finished_at=PracticeSession.expires_at)
        )

    def drop_old() -> Delete:
        old = (
            select(PracticeSession.id)
            .where(PracticeSession.created_at < now - timedelta(days=HISTORY_DAYS))
            .limit(BATCH)
        )
        return delete(PracticeSession).where(PracticeSession.id.in_(old.scalar_subquery()))

    def prune_keys() -> Delete:
        old = (
            select(AttemptKey.user_id, AttemptKey.client_answer_id)
            .where(AttemptKey.created_at < now - timedelta(days=ATTEMPT_KEY_DAYS))
            .limit(BATCH)
        )
        return delete(AttemptKey).where(
            tuple_(AttemptKey.user_id, AttemptKey.client_answer_id).in_(old)
        )

    return Housekeeping(
        closed=await _in_batches(db, close),
        deleted=await _in_batches(db, drop_old),
        keys_pruned=await _in_batches(db, prune_keys),
    )


async def ensure_attempt_partitions(db: AsyncSession) -> int:
    """Create this month's and the next months' partitions of question_attempts (if missing)."""
    created = await db.scalar(select(func.ensure_attempt_partitions(PARTITION_MONTHS_AHEAD)))
    return int(created or 0)


async def practice_housekeeping_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    async with lease(resources.redis, "practice_housekeeping", ttl_s=900) as acquired:
        if not acquired:
            return
        async with resources.sessionmaker() as db:
            done = await practice_housekeeping(db, now=clock())
        if done.closed or done.deleted or done.keys_pruned:
            log.info(
                "practice.housekeeping",
                closed=done.closed,
                deleted=done.deleted,
                keys_pruned=done.keys_pruned,
            )


async def attempt_partitions_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    async def run() -> None:
        async with resources.sessionmaker() as db:
            created = await ensure_attempt_partitions(db)
            await db.commit()
        log.info("question_attempts.partitions", created=created)

    await once_per_day(resources.redis, "attempt_partitions", clock().date(), run, lease_ttl_s=600)
