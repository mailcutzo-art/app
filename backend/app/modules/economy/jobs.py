"""The hold reaper: returning coins stuck in holds whose game or tournament is gone.

A hold normally ends when its match settles or its tournament starts. If something crashed in
between, the reaper releases holds older than ``STUCK_AFTER`` whose reference is no longer
live. Whether a reference is live is asked of the module that owns it: realtime, rooms and
tournaments register a predicate per ``RefKind`` with ``register_liveness``. A kind with no
predicate counts as not live, so its stuck holds are refunded.
"""

import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta

import structlog
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import Clock, utc_now
from app.core.jobs import lease
from app.core.resources import Resources
from app.modules.economy.models import CoinHold, HoldStatus, RefKind
from app.modules.economy.service import locked_hold, release_hold
from app.modules.notifications.service import notify

log = structlog.stdlib.get_logger("app.worker")

STUCK_AFTER = timedelta(minutes=30)
REAP_BATCH = 200
REFUND_TITLE = "Refund: entry returned"


@dataclass(frozen=True, slots=True)
class HoldRef:
    hold_id: uuid.UUID
    user_id: uuid.UUID
    ref_kind: RefKind
    ref_id: str
    created_at: datetime


# (db, redis, hold) -> True while the thing the hold pays for may still use it.
LivenessCheck = Callable[[AsyncSession, Redis, HoldRef], Awaitable[bool]]

_LIVENESS: dict[RefKind, LivenessCheck] = {}


def register_liveness(kind: RefKind, check: LivenessCheck) -> None:
    """Tell the reaper how to decide whether holds for ``kind`` are still in use."""
    _LIVENESS[kind] = check


async def is_live(db: AsyncSession, redis: Redis, ref: HoldRef) -> bool:
    check = _LIVENESS.get(ref.ref_kind)
    return False if check is None else await check(db, redis, ref)


async def reap_stuck_holds(db: AsyncSession, redis: Redis, *, now: datetime) -> int:
    """Release open holds older than ``STUCK_AFTER`` that nothing live uses; each release
    commits on its own and tells the player. Returns how many were released."""
    stuck = (
        await db.execute(
            select(
                CoinHold.id,
                CoinHold.user_id,
                CoinHold.ref_kind,
                CoinHold.ref_id,
                CoinHold.created_at,
                CoinHold.amount,
            )
            .where(
                CoinHold.status == HoldStatus.HELD.value, CoinHold.created_at < now - STUCK_AFTER
            )
            .order_by(CoinHold.created_at)
            .limit(REAP_BATCH)
        )
    ).all()
    await db.commit()
    released = 0
    for hold_id, user_id, ref_kind, ref_id, created_at, amount in stuck:
        ref = HoldRef(hold_id, user_id, RefKind(ref_kind), ref_id, created_at)
        if await is_live(db, redis, ref):
            continue
        record, _wallet = await locked_hold(db, hold_id)
        if record.status != HoldStatus.HELD:  # settled since the scan
            await db.commit()
            continue
        await release_hold(db, hold_id, title=REFUND_TITLE)
        await notify(
            db,
            user_id,
            kind="refund",
            title=f"{amount} coins returned",
            body="Your entry didn't go ahead, so the coins are back in your wallet.",
            icon="coins",
            action={"route": "/wallet", "params": {}},
            key=f"refund:hold:{hold_id}",
        )
        await db.commit()
        released += 1
        log.info("coin_hold.reaped", hold_id=str(hold_id), ref_kind=ref_kind, amount=amount)
    return released


async def hold_reaper_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    async with lease(resources.redis, "hold_reaper", ttl_s=300) as acquired:
        if not acquired:
            return
        async with resources.sessionmaker() as db:
            await reap_stuck_holds(db, resources.redis, now=clock())
