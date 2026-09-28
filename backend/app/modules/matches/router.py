"""The Battle tab, match history, results, reviews and opponents (``docs/api-play.md``).

``/v1/matches/*`` answers even old builds and during maintenance (``matches_router``), so a game
in progress can always show its result.
"""

import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Query

from app.core.clock import ClockDep, redis_now_ms
from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.content.catalog import resolve_goal
from app.modules.matches import service
from app.modules.matches.ports import integrations
from app.modules.matches.schemas import (
    BattleSetupOut,
    MatchesOut,
    MatchOut,
    OpponentsOut,
    ReviewOut,
)

router = APIRouter(tags=["battles"])
matches_router = APIRouter(tags=["battles"])

CursorQuery = Annotated[str | None, Query(max_length=512)]
LimitQuery = Annotated[int, Query(ge=1, le=100)]
KindQuery = Annotated[
    Literal["quick_rated", "quick_casual", "bot", "friend", "group", "tournament"] | None,
    Query(),
]


@router.get("/battle/setup")
async def battle_setup(
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
    goal: Annotated[str | None, Query(max_length=32)] = None,
) -> BattleSetupOut:
    """Everything the Battle tab needs: subjects with chapters and ratings, coins, cooldown,
    what the player is busy with, the last selection, players searching and leaders."""
    goal = await resolve_goal(db, auth.user_id, goal)
    return await service.battle_setup(
        db,
        redis,
        settings,
        integrations,
        auth.user_id,
        goal=goal,
        now_ms=await redis_now_ms(redis),
    )


@router.get("/me/matches")
async def match_history(
    auth: CurrentAuth,
    db: SessionDep,
    kind: KindQuery = None,
    cursor: CursorQuery = None,
    limit: LimitQuery = 20,
) -> MatchesOut:
    """Ended matches, newest first."""
    return await service.history(db, auth.user_id, kind=kind, cursor=cursor, limit=limit)


@matches_router.get("/matches/{match_id}")
async def read_match(
    match_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, redis: RedisDep
) -> MatchOut:
    """The result with its status and, once settled, this player's ``match.settled`` numbers.
    404 unless the caller played in it."""
    return await service.match_result(db, redis, auth.user_id, match_id)


@matches_router.get("/matches/{match_id}/review")
async def review_match(
    match_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, redis: RedisDep
) -> ReviewOut:
    """Every question with both players' answers, the explanation and the bookmark state.
    409 ``MATCH_NOT_OVER`` while the game runs."""
    return await service.review(db, redis, auth.user_id, match_id)


@router.get("/me/opponents")
async def recent_opponents(
    auth: CurrentAuth,
    db: SessionDep,
    clock: ClockDep,
    days: Annotated[int, Query(ge=1, le=90)] = 30,
) -> OpponentsOut:
    """People played recently (never the bot), each with the head-to-head record."""
    return await service.opponents(db, integrations, auth.user_id, days=days, now=clock())


@router.get("/me/rivals")
async def rivals(auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> OpponentsOut:
    """Opponents played 3 or more times in 60 days."""
    return await service.opponents(
        db,
        integrations,
        auth.user_id,
        days=service.RIVAL_DAYS,
        min_games=service.RIVAL_MIN_GAMES,
        now=clock(),
    )
