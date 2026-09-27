"""Coach tips for the signed-in player."""

from typing import Annotated

from fastapi import APIRouter, Path

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.coach import service
from app.modules.coach.schemas import TipsOut
from app.modules.content.catalog import resolve_goal

router = APIRouter(tags=["coach"])


@router.get("/me/tips")
async def list_tips(auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep) -> TipsOut:
    """Up to five tips once the player has answered enough questions."""
    goal = await resolve_goal(db, auth.user_id, None)
    return await service.current_tips(db, redis, auth.user_id, goal=goal, now=clock())


@router.post("/me/tips/{key:path}/dismiss", status_code=204)
async def dismiss_tip(
    key: Annotated[str, Path(min_length=1, max_length=200, pattern=r"^[^\s]+$")],
    auth: CurrentAuth,
    db: SessionDep,
    clock: ClockDep,
) -> None:
    """Hide this tip for 7 days."""
    await service.dismiss_tip(db, auth.user_id, key, now=clock())
