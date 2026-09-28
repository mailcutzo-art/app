"""Daily missions, the streak and its freezes, and achievements."""

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import Request
from starlette.responses import Response

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.idempotency import IDEMPOTENCY_KEY_HEADER, IdempotencyDep
from app.core.security import CurrentAuth
from app.modules.progression import achievements, missions, streaks
from app.modules.progression.models import StreakState
from app.modules.progression.schemas import (
    AchievementOut,
    AchievementsOut,
    CalendarDayOut,
    MissionsOut,
    StreakOut,
)
from app.modules.progression.service import missions_summary

router = APIRouter(tags=["progression"])

DaysQuery = Annotated[int, Query(ge=1, le=90)]


@router.get("/me/missions")
async def read_missions(auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> MissionsOut:
    """Today's three missions (created on the first request of the IST day), the all-three
    bonus and the streak. Rewards are credited automatically."""
    return MissionsOut.model_validate(
        await missions_summary(db, auth.user_id, clock()), strict=False
    )


@router.post(
    "/me/missions/{mission_id}/swap",
    responses={
        404: {"description": "MISSION_NOT_FOUND: not one of today's missions"},
        409: {"description": "SWAP_USED, MISSION_DONE or NO_SWAP"},
    },
)
async def swap_mission(
    mission_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> MissionsOut:
    """Swap one unfinished mission for another of its slot; one free swap a day. Returns the
    missions as ``GET /v1/me/missions`` does."""
    now = clock()
    await missions.swap(db, auth.user_id, mission_id, now=now)
    return MissionsOut.model_validate(await missions_summary(db, auth.user_id, now), strict=False)


async def _streak_out(
    db: AsyncSession, user_id: uuid.UUID, status: streaks.StreakStatus, *, days: int, now: datetime
) -> StreakOut:
    calendar = await streaks.calendar(db, user_id, days=days, now=now)
    return StreakOut(
        days=status.days,
        best=status.best,
        today_done=status.today_done,
        freezes=status.freezes,
        max_freezes=streaks.MAX_FREEZES,
        freeze_price=streaks.FREEZE_PRICE,
        calendar=[
            CalendarDayOut(day=d.day, state=d.state.value if d.state else None) for d in calendar
        ],
        freezes_used=[d.day for d in calendar if d.state == StreakState.FROZEN],
    )


@router.get("/me/streak")
async def read_streak(
    auth: CurrentAuth, db: SessionDep, clock: ClockDep, days: DaysQuery = 30
) -> StreakOut:
    """The streak, freezes held, and a calendar of the last ``days`` IST days (oldest first):
    ``active`` days counted, ``frozen`` ones were covered by a freeze."""
    now = clock()
    status = await streaks.evaluate(db, auth.user_id, now=now)
    return await _streak_out(db, auth.user_id, status, days=days, now=now)


@router.post(
    "/me/streak/freezes",
    response_model=StreakOut,
    responses={409: {"description": "FREEZE_LIMIT or INSUFFICIENT_COINS"}},
)
async def buy_freeze(
    request: Request, auth: CurrentAuth, db: SessionDep, clock: ClockDep, idem: IdempotencyDep
) -> Response:
    """Buy a streak freeze for 50 coins (hold at most 2). Needs an ``Idempotency-Key``."""
    now = clock()
    status = await streaks.buy_freeze(
        db, auth.user_id, key=request.headers[IDEMPOTENCY_KEY_HEADER], now=now
    )
    return await idem.complete(await _streak_out(db, auth.user_id, status, days=30, now=now))


@router.get("/me/achievements")
async def read_achievements(auth: CurrentAuth, db: SessionDep) -> AchievementsOut:
    """Earned achievements (newest first), then progress on the others."""
    views = await achievements.list_achievements(db, auth.user_id)
    return AchievementsOut(
        earned=sum(v.earned_at is not None for v in views),
        total=len(views),
        items=[
            AchievementOut(
                id=v.id,
                title=v.title,
                description=v.description,
                icon=v.icon,
                coins=v.coins,
                progress=v.progress,
                target=v.target,
                earned=v.earned_at is not None,
                earned_at=v.earned_at,
            )
            for v in views
        ],
    )
