"""Nightly per-question statistics, rebuilt from the answers (no hot counters)."""

from datetime import datetime, timedelta

import structlog
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST, Clock, utc_now
from app.core.jobs import once_per_day
from app.core.resources import Resources

log = structlog.stdlib.get_logger("app.worker")

# The rebuild runs once per day in India, on the first worker tick after this hour.
NIGHTLY_HOUR_IST = 2
TYPICAL_WINDOW = timedelta(days=90)
# typical_ms stays NULL until this many correct answers with a time are in the window.
MIN_TYPICAL_SAMPLES = 20

_REBUILD = text(
    """
INSERT INTO question_stats AS s
    (question_id, attempts, correct, typical_ms, timed_correct, p_correct, updated_at)
SELECT q.id,
       coalesce(a.attempts, 0),
       coalesce(a.correct, 0),
       CASE WHEN t.samples >= :min_samples THEN round(t.median)::integer END,
       coalesce(t.samples, 0),
       CASE WHEN a.attempts > 0 THEN a.correct::double precision / a.attempts END,
       :now
FROM questions q
LEFT JOIN (
    SELECT question_id,
           count(*) AS attempts,
           count(*) FILTER (WHERE outcome = 'correct') AS correct
    FROM question_attempts
    GROUP BY question_id
) a ON a.question_id = q.id
LEFT JOIN (
    SELECT question_id,
           count(*) AS samples,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY time_ms) AS median
    FROM question_attempts
    WHERE outcome = 'correct' AND time_ms > 0 AND answered_at >= :since
    GROUP BY question_id
) t ON t.question_id = q.id
ON CONFLICT (question_id) DO UPDATE SET
    attempts = excluded.attempts,
    correct = excluded.correct,
    typical_ms = excluded.typical_ms,
    timed_correct = excluded.timed_correct,
    p_correct = excluded.p_correct,
    updated_at = excluded.updated_at
"""
)


async def rebuild_question_stats(db: AsyncSession, *, now: datetime) -> int:
    """Recompute every question's figures: all-time attempts and share correct, and the median
    time of correct answers over the last 90 days. Returns the number of questions."""
    result = await db.execute(
        _REBUILD,
        {"min_samples": MIN_TYPICAL_SAMPLES, "now": now, "since": now - TYPICAL_WINDOW},
    )
    return int(getattr(result, "rowcount", 0) or 0)


async def question_stats_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()
    local = now.astimezone(IST)
    if local.hour < NIGHTLY_HOUR_IST:
        return

    async def run() -> None:
        async with resources.sessionmaker() as db:
            count = await rebuild_question_stats(db, now=now)
            await db.commit()
        log.info("question_stats.rebuilt", questions=count)

    await once_per_day(resources.redis, "question_stats", local.date(), run, lease_ttl_s=3600)
