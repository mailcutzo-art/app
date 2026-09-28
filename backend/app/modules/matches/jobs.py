"""Worker jobs for live games: settlement retries and the reconciler.

- **Settlement retries.** The owner node settles a match the moment it ends; anything still in
  ``settle:q`` after ``settle_retry_after_s`` (a crashed node, Postgres down) is settled here.
  Settlement is exactly-once, so racing an rt node is harmless. Lag over a minute is logged as
  an error for alerting.
- **Reconciler.** A match still ``live`` in Postgres past its longest possible duration plus
  5 minutes, with no state left in Redis (Redis lost it, or creation failed half way), is
  voided and its casual entries refunded.
"""

import uuid
from datetime import datetime, timedelta

import structlog
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import redis_now_ms, utc_now
from app.core.config import Settings, get_settings
from app.core.jobs import lease
from app.core.resources import Resources
from app.modules.matches.models import (
    EndReason,
    Match,
    MatchParticipant,
    MatchStatus,
    ParticipantResult,
)
from app.modules.matches.ports import Integrations, integrations
from app.modules.matches.settlement import SessionFactory, SettleDeps, settle_match
from app.modules.realtime import keys, rstr

log = structlog.stdlib.get_logger("app.worker")

LAG_ALERT_S = 60
RECONCILE_GRACE = timedelta(minutes=5)
BATCH = 100


async def settle_pending(deps: SettleDeps) -> int:
    """Settle matches waiting longer than the retry delay; returns how many settled."""
    now = await redis_now_ms(deps.redis)
    cutoff = now - round(deps.settings.settle_retry_after_s * 1000)
    waiting: list[tuple[str, float]] = await deps.redis.zrangebyscore(  # type: ignore[assignment]
        keys.SETTLE_QUEUE, "-inf", cutoff, start=0, num=BATCH, withscores=True
    )
    settled = 0
    for raw_mid, since in waiting:
        mid = rstr.as_str(raw_mid)
        lag_s = (now - float(since)) / 1000
        if lag_s > LAG_ALERT_S:
            log.error("settlement.lagging", match_id=mid, lag_s=round(lag_s))
        try:
            settled += int(await settle_match(deps, mid))
        except Exception:
            log.exception("settlement.retry_failed", match_id=mid)
    return settled


async def reconcile(
    db: AsyncSession,
    redis: Redis,
    plugins: Integrations,
    *,
    now: datetime,
) -> list[uuid.UUID]:
    """Void live matches past their longest duration + 5 minutes that Redis no longer has."""
    candidates = (
        await db.scalars(
            select(Match)
            .where(Match.status == MatchStatus.LIVE.value, Match.created_at < now - RECONCILE_GRACE)
            .order_by(Match.created_at)
            .limit(BATCH)
        )
    ).all()
    voided = []
    for candidate in candidates:
        longest = timedelta(milliseconds=int(candidate.config.get("max_duration_ms", 0)))
        if candidate.created_at + longest + RECONCILE_GRACE > now:
            continue
        mid = str(candidate.id)
        if await redis.exists(keys.match(mid), keys.match_final(mid)):
            continue  # still running, or ended and waiting for settlement
        match = await db.get(Match, candidate.id, with_for_update=True, populate_existing=True)
        if match is None or match.status != MatchStatus.LIVE:
            continue
        match.status = MatchStatus.VOIDED.value
        match.end_reason = EndReason.VOIDED.value
        match.finished_at = match.settled_at = now
        cards = match.config.get("cards", {})
        seats = []
        for seat, (uid, card) in enumerate(cards.items(), start=1):
            is_bot = bool(card.get("is_bot"))
            seats.append(
                {
                    "match_id": match.id,
                    "seat": seat,
                    "user_id": None if is_bot else uuid.UUID(uid),
                    "is_bot": is_bot,
                    "card": card,
                    "result": ParticipantResult.VOIDED.value,
                }
            )
        if seats:
            await db.execute(insert(MatchParticipant).values(seats).on_conflict_do_nothing())
        for uid, hold_id in sorted(match.config.get("holds", {}).items()):
            await plugins.escrow.release(db, hold_id=hold_id, key=f"m:{mid}:{uid}:refund")
        await db.commit()
        for uid, card in cards.items():
            if not card.get("is_bot") and await redis.get(keys.busy(uid)) == f"m:{mid}":
                await redis.delete(keys.busy(uid))
        log.warning("match.reconciled", match_id=mid)
        voided.append(match.id)
    return voided


def _deps(resources: Resources, settings: Settings, sessionmaker: SessionFactory) -> SettleDeps:
    return SettleDeps(
        redis=resources.redis,
        sessionmaker=sessionmaker,
        settings=settings,
        integrations=integrations,
    )


async def settle_pending_job(resources: Resources) -> None:
    async with lease(resources.redis, "settle_pending", ttl_s=60) as acquired:
        if acquired:
            await settle_pending(_deps(resources, get_settings(), resources.sessionmaker))


async def reconcile_matches_job(resources: Resources) -> None:
    async with lease(resources.redis, "reconcile_matches", ttl_s=120) as acquired:
        if not acquired:
            return
        async with resources.sessionmaker() as db:
            voided = await reconcile(db, resources.redis, integrations, now=utc_now())
        if voided:
            log.info("worker.matches_reconciled", voided=len(voided))
