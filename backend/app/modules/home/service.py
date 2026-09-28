"""``GET /v1/home``: every Home section, each with its own status (docs/api-play.md, "Home").

Sections are computed one after another on the request's session, each inside its own
SAVEPOINT: a section that fails (a bug, a missing row, a Redis hiccup) is rolled back alone and
answers ``{"status": "error", "error": {"code", "message"}}``, so one failure never blanks Home.
(They share one ``AsyncSession``, which can't run statements concurrently; every section is a
few indexed reads.)

- ``hero``: the overall rating, the rank on ``rating:overall`` (or rated games still needed),
  coins and level.
- ``live``: a search, match or room in progress (the realtime busy marker); otherwise whatever a
  registered ``live`` provider reports (the tournaments module: checking in or running).
- ``continue``: the latest unfinished practice session, else the coach's next suggestion.
- ``tip``: the top coach tip. ``missions``: today's missions and the streak.
- ``leaders``: the top 3 of this week's XP board on the player's exam, and their own row.
- ``tournament``: from a registered provider (the next or live tournament), else null.
- ``welcome``: ``{"coins": 100}`` once, on the first Home after onboarding (not a section).
- ``maintenance_banner``: planned maintenance starting within 2 hours, ``{"message", "at",
  "until"}`` (not a section), else null.
"""

import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

import structlog
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST, iso_utc
from app.core.errors import INTERNAL_ERROR_MESSAGE, AppError
from app.modules.coach.service import current_tips
from app.modules.economy.service import get_wallet, pop_welcome
from app.modules.leaderboards import boards, keys, service
from app.modules.leaderboards.boards import primary_view
from app.modules.leaderboards.stats import level_of
from app.modules.matches.service import active_for
from app.modules.practice.progress import continue_session
from app.modules.practice.sessions import user_goal
from app.modules.progression.service import missions_summary
from app.modules.ratings.models import OVERALL, Rating
from app.modules.ratings.service import rating_out
from app.modules.system.runtime import RuntimeConfig
from app.modules.users.models import User

log = structlog.stdlib.get_logger(__name__)

MAINTENANCE_NOTICE = timedelta(hours=2)
LEADERS_TOP = 3


@dataclass(frozen=True, slots=True)
class HomeContext:
    db: AsyncSession
    redis: Redis
    user_id: uuid.UUID
    now: datetime


Section = Callable[[HomeContext], Awaitable[Any]]


async def _nothing(_ctx: HomeContext) -> Any:
    return None


# Sections other modules supply: ``tournament`` (the next or live tournament card) and ``live``
# (a tournament that needs the player now, asked when no search, match or room is in progress).
_PROVIDED: dict[str, Section] = {"tournament": _nothing, "live": _nothing}


def register_home_section(name: str, provider: Section) -> None:
    """Supply the ``tournament`` section or the tournament part of ``live``."""
    if name not in _PROVIDED:
        raise ValueError(f"unknown home section {name!r}")
    _PROVIDED[name] = provider


async def hero(ctx: HomeContext) -> dict[str, Any]:
    user = await ctx.db.get_one(User, ctx.user_id)
    row = await ctx.db.get(Rating, (ctx.user_id, OVERALL))
    key = keys.rating_key(primary_view(user.goal), OVERALL)
    position = await boards.position(ctx.redis, key, ctx.user_id)
    return {
        "rating": rating_out(row),
        "rank": {
            "board": "rating:overall",
            "position": position,
            "games_to_rank": None if position else boards.games_to_rank(row, ctx.now),
        },
        "coins": (await get_wallet(ctx.db, ctx.user_id)).balance,
        "level": (await level_of(ctx.db, ctx.user_id)).model_dump(),
    }


async def live(ctx: HomeContext) -> dict[str, Any] | None:
    active = await active_for(ctx.redis, str(ctx.user_id))
    if active is not None:
        found_active = active.model_dump(mode="json")
        action = {"params": {}, **found_active["action"]}
        return {**found_active, "action": action, "state": None, "until": None}
    found: dict[str, Any] | None = await _PROVIDED["live"](ctx)
    return found


async def continue_(ctx: HomeContext) -> dict[str, Any] | None:
    session = await continue_session(ctx.db, ctx.user_id, now=ctx.now)
    if session is not None:
        return {"kind": "practice", **session.model_dump(mode="json")}
    goal = await user_goal(ctx.db, ctx.user_id)
    tips = (await current_tips(ctx.db, ctx.redis, ctx.user_id, goal=goal, now=ctx.now)).tips
    if len(tips) < 2:
        return None
    tip = tips[1]  # the top tip has its own card
    return {
        "kind": "suggestion",
        "key": tip.key,
        "message": tip.message,
        "action": tip.action,
        "params": tip.params,
    }


async def tip(ctx: HomeContext) -> dict[str, Any] | None:
    goal = await user_goal(ctx.db, ctx.user_id)
    tips = (await current_tips(ctx.db, ctx.redis, ctx.user_id, goal=goal, now=ctx.now)).tips
    if not tips:
        return None
    top = tips[0]
    return {"key": top.key, "message": top.message, "action": top.action, "params": top.params}


async def missions(ctx: HomeContext) -> dict[str, Any]:
    return await missions_summary(ctx.db, ctx.user_id, ctx.now)


async def leaders(ctx: HomeContext) -> dict[str, Any]:
    user = await ctx.db.get_one(User, ctx.user_id)
    rows, me = await service.weekly_leaders(
        ctx.db,
        ctx.redis,
        ctx.user_id,
        keys.Board(keys.Family.WEEKLY_XP),
        goal=user.goal,
        top=LEADERS_TOP,
        now=ctx.now,
    )
    return {
        "board": "weekly_xp",
        "top": [row.model_dump(mode="json") for row in rows],
        "me": me.model_dump(mode="json") if me else None,
    }


async def tournament(ctx: HomeContext) -> Any:
    return await _PROVIDED["tournament"](ctx)


SECTIONS: dict[str, Section] = {
    "hero": hero,
    "live": live,
    "continue": continue_,
    "tip": tip,
    "missions": missions,
    "leaders": leaders,
    "tournament": tournament,
}


async def _section(ctx: HomeContext, name: str, section: Section) -> dict[str, Any]:
    try:
        async with ctx.db.begin_nested():
            data = await section(ctx)
    except AppError as exc:
        return {"status": "error", "error": {"code": exc.code, "message": exc.message}}
    except Exception:
        log.exception("home.section_failed", section=name, user_id=str(ctx.user_id))
        return {
            "status": "error",
            "error": {"code": "INTERNAL_ERROR", "message": INTERNAL_ERROR_MESSAGE},
        }
    return {"status": "ok", "data": data}


def maintenance_banner(config: RuntimeConfig, now: datetime) -> dict[str, Any] | None:
    """Planned maintenance starting within 2 hours: ``{"message", "at", "until"}``."""
    at = config.maintenance_at
    if at is None or not now < at <= now + MAINTENANCE_NOTICE:
        return None
    message = config.maintenance_message or (
        f"Planned maintenance at {at.astimezone(IST):%H:%M} IST. Matches in progress will finish."
    )
    return {"message": message, "at": iso_utc(at), "until": iso_utc(config.maintenance_until)}


async def home(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    *,
    config: RuntimeConfig,
    now: datetime,
) -> dict[str, Any]:
    ctx = HomeContext(db=db, redis=redis, user_id=user_id, now=now)
    out: dict[str, Any] = {}
    for name, section in SECTIONS.items():
        out[name] = await _section(ctx, name, section)
    welcome = None
    try:
        async with db.begin_nested():
            coins = await pop_welcome(db, user_id, now=now)
        welcome = {"coins": coins} if coins is not None else None
    except Exception:
        log.exception("home.welcome_failed", user_id=str(user_id))
    out["welcome"] = welcome
    out["maintenance_banner"] = maintenance_banner(config, now)
    return out
