"""``GET /v1/me/stats``: the Profile's stats card and rating chart (docs/api-play.md).

- ``ratings``: every scope with a rated game, overall first, with the position on the player's
  own exam board (null while off it).
- ``record``: wins, draws and losses per mode from settled matches (``rated``, ``casual``,
  ``bot``, ``friend``, ``group``, ``tournament``).
- ``accuracy`` and ``questions_answered``: every answer, practice and battles, from the running
  chapter totals.
- ``streak``: current and best (the streak is settled up to today first).
- ``rating_history``: the overall rating after each rated game in ``range``, oldest first.
"""

import uuid
from datetime import datetime, timedelta
from typing import Literal

from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import Subject
from app.modules.leaderboards import service
from app.modules.leaderboards.schemas import (
    LevelOut,
    RatingPointOut,
    RecordOut,
    ScopeRatingOut,
    StatsOut,
    StreakOut,
)
from app.modules.matches.models import Match, MatchKind, MatchParticipant, MatchStatus
from app.modules.matches.schemas import RatingOut
from app.modules.practice.models import UserChapterStats
from app.modules.progression import levels, streaks
from app.modules.progression.models import UserProgress
from app.modules.ratings.models import OVERALL, Rating, RatingHistory
from app.modules.ratings.service import rating_out, shown
from app.modules.users.models import User

StatsRange = Literal["30d", "90d", "all"]
RANGE_DAYS: dict[str, int | None] = {"30d": 30, "90d": 90, "all": None}
MODES: dict[str, str] = {
    MatchKind.QUICK_RATED.value: "rated",
    MatchKind.QUICK_CASUAL.value: "casual",
    MatchKind.BOT.value: "bot",
    MatchKind.FRIEND.value: "friend",
    MatchKind.GROUP.value: "group",
    MatchKind.TOURNAMENT.value: "tournament",
}


async def level_of(db: AsyncSession, user_id: uuid.UUID) -> LevelOut:
    """``{"level", "into_level", "for_next"}``, as on Home."""
    progress = await db.get(UserProgress, user_id)
    level, into, span = levels.progress(progress.xp if progress else 0)
    return LevelOut(level=level, into_level=into, for_next=span)


async def _record(db: AsyncSession, user_id: uuid.UUID) -> dict[str, RecordOut]:
    rows = await db.execute(
        select(Match.kind, MatchParticipant.result, func.count())
        .join(Match, Match.id == MatchParticipant.match_id)
        .where(
            MatchParticipant.user_id == user_id,
            Match.status == MatchStatus.SETTLED.value,
            MatchParticipant.result.in_(("win", "draw", "loss")),
        )
        .group_by(Match.kind, MatchParticipant.result)
    )
    counts: dict[str, dict[str, int]] = {mode: {} for mode in MODES.values()}
    for kind, result, count in rows:
        if kind in MODES:
            counts[MODES[kind]][result] = int(count)
    return {
        mode: RecordOut(wins=c.get("win", 0), draws=c.get("draw", 0), losses=c.get("loss", 0))
        for mode, c in counts.items()
    }


async def player_stats(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, range_: StatsRange, now: datetime
) -> StatsOut:
    user = await db.get_one(User, user_id)
    rows = list(await db.scalars(select(Rating).where(Rating.user_id == user_id, Rating.games > 0)))
    names = {row[0]: row[1] for row in await db.execute(select(Subject.slug, Subject.name))}
    rows.sort(key=lambda row: (row.scope != OVERALL, names.get(row.scope, row.scope)))
    positions = await service.rating_positions(redis, user_id, user.goal, [r.scope for r in rows])
    ratings = [
        ScopeRatingOut(
            scope=row.scope,
            name="Overall" if row.scope == OVERALL else names.get(row.scope, row.scope.title()),
            rating=RatingOut(**rating_out(row)),
            position=positions.get(row.scope),
        )
        for row in rows
    ]
    attempts, correct = (
        await db.execute(
            select(
                func.coalesce(func.sum(UserChapterStats.attempts), 0),
                func.coalesce(func.sum(UserChapterStats.correct), 0),
            ).where(UserChapterStats.user_id == user_id)
        )
    ).one()
    streak = await streaks.evaluate(db, user_id, now=now)
    history = select(RatingHistory.created_at, RatingHistory.rating_after).where(
        RatingHistory.user_id == user_id, RatingHistory.scope == OVERALL
    )
    days = RANGE_DAYS[range_]
    if days is not None:
        history = history.where(RatingHistory.created_at >= now - timedelta(days=days))
    points = await db.execute(history.order_by(RatingHistory.created_at, RatingHistory.id))
    return StatsOut(
        level=await level_of(db, user_id),
        ratings=ratings,
        record=await _record(db, user_id),
        accuracy=round(int(correct) / int(attempts), 4) if attempts else None,
        questions_answered=int(attempts),
        streak=StreakOut(current=streak.days, best=max(streak.best, streak.days)),
        rating_history=[RatingPointOut(at=at, value=shown(value)) for at, value in points],
    )
