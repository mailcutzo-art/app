"""The Arena: tournament cards, detail, standings, your games, registration and check-in
(docs/api-play.md, "Tournaments")."""

import uuid
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Query
from starlette.responses import Response

from app.core.clock import ClockDep
from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.idempotency import IdempotencyDep
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.security import CurrentUserId
from app.modules.tournaments import service

router = APIRouter(tags=["tournaments"])

CursorQuery = Annotated[str | None, Query(max_length=512)]
LimitQuery = Annotated[int, Query(ge=1, le=100)]
_write_limit = rate_limit("tournaments.write", capacity=20, refill_per_sec=20 / 60, scope="user")


@router.get("/tournaments")
async def list_tournaments(
    user_id: CurrentUserId,
    db: SessionDep,
    settings: SettingsDep,
    status: Literal["open", "upcoming", "live", "finished"] = "open",
    goal: Literal["neet", "jee"] | None = None,
    cursor: CursorQuery = None,
    limit: LimitQuery = 20,
) -> dict[str, Any]:
    """Arena cards: open (registration or check-in), upcoming (scheduled or locked), live and
    finished (or cancelled). ``goal`` also includes tournaments open to both exams."""
    return await service.list_cards(
        db, settings, user_id, status=status, goal=goal, cursor=cursor, limit=limit
    )


@router.get("/me/tournaments")
async def my_tournaments(
    user_id: CurrentUserId,
    db: SessionDep,
    settings: SettingsDep,
    cursor: CursorQuery = None,
    limit: LimitQuery = 20,
) -> dict[str, Any]:
    """Your tournaments, newest first; finished ones add ``final_rank``, ``prize``, ``xp``
    and ``points``."""
    return await service.my_tournaments(db, settings, user_id, cursor=cursor, limit=limit)


@router.get("/tournaments/{tournament_id}")
async def tournament_detail(
    tournament_id: uuid.UUID,
    user_id: CurrentUserId,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
) -> dict[str, Any]:
    return await service.detail(db, redis, settings, tournament_id, user_id)


@router.post(
    "/tournaments/{tournament_id}/register", status_code=200, dependencies=[Depends(_write_limit)]
)
async def register(
    tournament_id: uuid.UUID,
    user_id: CurrentUserId,
    db: SessionDep,
    settings: SettingsDep,
    clock: ClockDep,
    idem: IdempotencyDep,
) -> Response:
    """Register and hold the entry fee; answers the updated card. 409 ``TOURNAMENT_FULL``,
    ``REGISTRATION_CLOSED``, ``INSUFFICIENT_COINS``, ``SCHEDULE_CONFLICT``; 403
    ``NOT_ALLOWED`` (``details.reason``: ``no_shows`` or ``exam``)."""
    out = await service.register(db, settings, tournament_id, user_id, now=clock())
    return await idem.complete(out)


@router.delete("/tournaments/{tournament_id}/register", dependencies=[Depends(_write_limit)])
async def withdraw(
    tournament_id: uuid.UUID,
    user_id: CurrentUserId,
    db: SessionDep,
    settings: SettingsDep,
    clock: ClockDep,
) -> dict[str, Any]:
    """Withdraw (also "Can't make it"): ``{"tournament": card, "refunded": coins}``."""
    return await service.withdraw(db, settings, tournament_id, user_id, now=clock())


@router.post("/tournaments/{tournament_id}/check-in", dependencies=[Depends(_write_limit)])
async def check_in(
    tournament_id: uuid.UUID,
    user_id: CurrentUserId,
    db: SessionDep,
    settings: SettingsDep,
    clock: ClockDep,
) -> dict[str, Any]:
    """From 15 to 2 minutes before the start; answers the updated card. 409
    ``CHECK_IN_CLOSED`` or ``NOT_REGISTERED``."""
    return await service.check_in(db, settings, tournament_id, user_id, now=clock())


@router.get("/tournaments/{tournament_id}/standings")
async def standings(
    tournament_id: uuid.UUID,
    user_id: CurrentUserId,
    db: SessionDep,
    cursor: CursorQuery = None,
    limit: LimitQuery = 50,
) -> dict[str, Any]:
    return await service.standings(db, tournament_id, user_id, cursor=cursor, limit=limit)


@router.get("/tournaments/{tournament_id}/me")
async def my_games(
    tournament_id: uuid.UUID, user_id: CurrentUserId, db: SessionDep, redis: RedisDep
) -> dict[str, Any]:
    return await service.my_games(db, redis, tournament_id, user_id)
