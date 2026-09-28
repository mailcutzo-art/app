"""``GET /v1/home`` (docs/api-play.md, "Home")."""

from typing import Any

from fastapi import APIRouter

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.home import service
from app.modules.system.runtime import RuntimeConfigDep

router = APIRouter(tags=["home"])


@router.get("/home")
async def read_home(
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    config: RuntimeConfigDep,
    clock: ClockDep,
) -> dict[str, Any]:
    """Every Home section with its own ``status``; a failed section never blanks the rest."""
    return await service.home(db, redis, auth.user_id, config=config, now=clock())
