"""Leaderboards and player stats (docs/api-play.md, "Leaderboards" and "Profiles and stats")."""

from typing import Annotated, Literal

from fastapi import APIRouter, Path, Query

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.leaderboards import service, stats
from app.modules.leaderboards.keys import PAGE
from app.modules.leaderboards.schemas import BoardPageOut, HubOut, StatsOut

router = APIRouter(tags=["leaderboards"])

GoalQuery = Annotated[Literal["neet", "jee"] | None, Query()]


@router.get("/leaderboards")
async def leaderboards_hub(
    auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep, goal: GoalQuery = None
) -> HubOut:
    """One card per board (its #1, your position and change since yesterday) and last week's
    top 3. ``goal`` shows one exam's players; without it, All India."""
    return await service.hub(db, redis, auth.user_id, goal=goal, now=clock())


@router.get("/leaderboards/{board}", responses={404: {"description": "BOARD_NOT_FOUND"}})
async def leaderboard(
    board: Annotated[str, Path(max_length=64)],
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    clock: ClockDep,
    goal: GoalQuery = None,
    cursor: Annotated[str | None, Query(max_length=512)] = None,
    limit: Annotated[int, Query(ge=1, le=PAGE)] = PAGE,
) -> BoardPageOut:
    """The top 100 in pages, your row, the 10 above and below you, or what you still need."""
    return await service.board_page(
        db, redis, auth.user_id, board, goal=goal, cursor=cursor, limit=limit, now=clock()
    )


@router.get("/me/stats")
async def my_stats(
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    clock: ClockDep,
    range_: Annotated[stats.StatsRange, Query(alias="range")] = "30d",
) -> StatsOut:
    """Ratings with positions, W/D/L per mode, accuracy, answers, streaks and the rating
    history over ``range``."""
    return await stats.player_stats(db, redis, auth.user_id, range_=range_, now=clock())
