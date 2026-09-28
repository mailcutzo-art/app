"""Achievements: about 15 badges, each earned once, paying 10-200 coins.

Every achievement measures one ``Metric``. Whatever moves a metric (a finished battle, a new
level, a longer streak, answers) calls ``signal``, which enqueues a ``progression.achievement``
outbox message in the caller's transaction; the outbox consumer applies it with ``apply`` and
awards what was reached. Match settlement also calls ``apply`` directly, so ``match.settled``
can list achievements earned by that match; the later outbox delivery then finds the event
already counted and changes nothing.

Counters add ``count`` once per ``event_id``. ``LEVEL`` and ``STREAK`` are absolute: the
progress becomes the larger of the old value and ``value``.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.economy.models import CoinReason, RefKind
from app.modules.economy.service import Ref, credit
from app.modules.notifications.service import notify
from app.modules.outbox.service import OutboxContext, enqueue, register
from app.modules.progression.models import (
    ABSOLUTE_METRICS,
    Achievement,
    Metric,
    ProgressEventDedupe,
    UserAchievement,
)
from app.modules.social.activity import record_activity

TOPIC = "progression.achievement"


@dataclass(frozen=True, slots=True)
class Earned:
    id: str
    title: str
    coins: int

    def fragment(self) -> dict[str, str]:
        """``match.settled.achievements`` item."""
        return {"id": self.id, "title": self.title}


async def signal(
    db: AsyncSession,
    user_id: uuid.UUID,
    metric: Metric,
    *,
    amount: int,
    event_id: str,
) -> None:
    """Queue a metric change: ``amount`` is added (counters) or is the new value (absolute)."""
    if amount <= 0:
        return
    await enqueue(
        db,
        TOPIC,
        {"user_id": str(user_id), "metric": metric.value, "amount": amount, "event_id": event_id},
        key=f"{TOPIC}:{user_id}:{metric.value}:{event_id}",
    )


async def apply(
    db: AsyncSession,
    user_id: uuid.UUID,
    metric: Metric,
    *,
    amount: int,
    event_id: str,
    now: datetime,
) -> list[Earned]:
    """Count one metric change (once per ``event_id``) and award what it completes."""
    if amount <= 0:
        return []
    claimed = await db.scalar(
        insert(ProgressEventDedupe)
        .values(user_id=user_id, kind=f"ach:{metric.value}", event_id=event_id)
        .on_conflict_do_nothing()
        .returning(ProgressEventDedupe.event_id)
    )
    if claimed is None:
        return []
    defs = (
        await db.scalars(
            select(Achievement).where(Achievement.metric == metric.value).order_by(Achievement.sort)
        )
    ).all()
    if not defs:
        return []
    statement = insert(UserAchievement).values(
        [{"user_id": user_id, "achievement_id": d.id, "progress": amount} for d in defs]
    )
    current = UserAchievement.__table__.c.progress
    grown = (
        func.greatest(current, statement.excluded.progress)
        if metric in ABSOLUTE_METRICS
        else current + statement.excluded.progress
    )
    progress = dict(
        (
            await db.execute(
                statement.on_conflict_do_update(
                    index_elements=["user_id", "achievement_id"],
                    set_={"progress": grown, "updated_at": func.now()},
                ).returning(UserAchievement.achievement_id, UserAchievement.progress)
            )
        ).all()
    )
    earned: list[Earned] = []
    for achievement in defs:
        if progress[achievement.id] >= achievement.target and await _mark_earned(
            db, user_id, achievement.id, now
        ):
            earned.append(await _reward(db, user_id, achievement))
    return earned


async def _mark_earned(
    db: AsyncSession, user_id: uuid.UUID, achievement_id: str, now: datetime
) -> bool:
    row = await db.get_one(
        UserAchievement,
        (user_id, achievement_id),
        with_for_update=True,
        populate_existing=True,
    )
    if row.earned_at is not None:
        return False
    row.earned_at = now
    await db.flush()
    return True


async def _reward(db: AsyncSession, user_id: uuid.UUID, achievement: Achievement) -> Earned:
    if achievement.coins > 0:
        await credit(
            db,
            user_id,
            achievement.coins,
            reason=CoinReason.ACHIEVEMENT,
            title=f"Achievement: {achievement.title}",
            key=f"achievement:{user_id}:{achievement.id}",
            ref=Ref(RefKind.ACHIEVEMENT, achievement.id),
        )
    reward = f" · +{achievement.coins} coins" if achievement.coins else ""
    await notify(
        db,
        user_id,
        kind="achievement",
        title=f"Achievement unlocked: {achievement.title}",
        body=f"{achievement.description}{reward}",
        icon=achievement.icon,
        action={"route": "/profile", "params": {"section": "achievements"}},
        key=f"achievement:{achievement.id}",
    )
    await record_activity(
        db,
        user_id,
        "achievement",
        {"achievement": achievement.id, "title": achievement.title},
        key=f"achievement:{achievement.id}",
    )
    return Earned(achievement.id, achievement.title, achievement.coins)


async def _handle(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    await apply(
        ctx.db,
        uuid.UUID(payload["user_id"]),
        Metric(payload["metric"]),
        amount=int(payload["amount"]),
        event_id=str(payload["event_id"]),
        now=ctx.now,
    )


register(TOPIC, _handle)


@dataclass(frozen=True, slots=True)
class AchievementView:
    id: str
    title: str
    description: str
    icon: str
    coins: int
    progress: int
    target: int
    earned_at: datetime | None


async def list_achievements(db: AsyncSession, user_id: uuid.UUID) -> list[AchievementView]:
    """Every achievement with the user's progress: earned ones first (newest first), then the
    rest in catalogue order."""
    rows = (
        await db.execute(
            select(Achievement, UserAchievement.progress, UserAchievement.earned_at)
            .outerjoin(
                UserAchievement,
                (UserAchievement.achievement_id == Achievement.id)
                & (UserAchievement.user_id == user_id),
            )
            .order_by(Achievement.sort)
        )
    ).all()
    views = [
        AchievementView(
            id=a.id,
            title=a.title,
            description=a.description,
            icon=a.icon,
            coins=a.coins,
            progress=min(progress or 0, a.target),
            target=a.target,
            earned_at=earned_at,
        )
        for a, progress, earned_at in rows
    ]
    earned = sorted(
        (v for v in views if v.earned_at is not None),
        key=lambda v: v.earned_at or datetime.min,
        reverse=True,
    )
    return earned + [v for v in views if v.earned_at is None]
