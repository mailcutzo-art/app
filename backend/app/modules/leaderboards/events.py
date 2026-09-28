"""Keeping the boards current: outbox handlers, the settlement hook and visibility changes.

Outbox topics (handlers registered on import; this module is in ``HANDLER_MODULES``):

- ``xp.awarded`` ``{"user_id", "ist_day"}``: queued by ``progression.xp`` with every award
  that gave XP; refreshes the player's ``weekly_xp`` entry for that week.
- ``lb.match`` ``{"match_id"}``: queued by the ``leaderboards`` settlement hook for settled
  rated, casual and tournament games; refreshes each player's ``weekly:{subject}`` entry and,
  after a rated game, their rating entries.
- ``lb.sync_user`` ``{"user_id"}``: queued when a player's visibility may have changed (a ban,
  the shadow pool, an account deleted or restored, the public-boards setting); refreshes every
  entry of theirs.

Each refresh recomputes from Postgres and writes absolute scores (``boards``), so every handler
is idempotent. Entering the top 100, 10 or 3 of a board on the player's own view puts a
``rank_milestone`` in their inbox, at most once per board, milestone and week.
"""

import uuid
from collections.abc import Mapping
from datetime import date, datetime, timedelta
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import new_id
from app.modules.content.models import Subject
from app.modules.leaderboards import boards, keys
from app.modules.leaderboards.boards import Catalog, Entry, Move, Target
from app.modules.matches.models import RATED_KINDS, Match, MatchParticipant, MatchStatus
from app.modules.notifications.service import notify
from app.modules.outbox.service import OutboxContext, enqueue, register
from app.modules.progression.xp import XP_AWARDED_TOPIC
from app.modules.ratings.models import OVERALL
from app.modules.users.models import User

XP_TOPIC = XP_AWARDED_TOPIC
MATCH_TOPIC = "lb.match"
SYNC_TOPIC = "lb.sync_user"


def board_title(board: keys.Board, names: Mapping[str, str]) -> str:
    subject = names.get(board.subject or "", (board.subject or "").title())
    match board.family:
        case keys.Family.WEEKLY_XP:
            return "Last week" if board.last else "This week"
        case keys.Family.WEEKLY_SUBJECT:
            return f"{subject} last week" if board.last else f"{subject} this week"
        case keys.Family.RATING:
            return "Overall rating" if board.subject == OVERALL else subject
        case keys.Family.FRIENDS_WEEKLY:
            return "Friends this week"
        case keys.Family.FRIENDS_RATING:
            return "Friends by rating"
        case keys.Family.HALL_OF_FAME:
            return f"{subject} Hall of Fame"


async def refresh(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    entries: Mapping[Target, Entry | None],
    *,
    now: datetime,
    catalog: Catalog | None = None,
) -> list[Move]:
    """Write the player's recomputed ``entries`` and tell them about big moves."""
    user = await db.get(User, user_id)
    if user is None:
        return []
    catalog = catalog or await boards.load_catalog(db)
    hidden = user_id in await boards.hidden_ids(db, now=now, among=[user_id])
    moves = await boards.write_user(
        redis, user_id, entries, goal=user.goal, hidden=hidden, catalog=catalog
    )
    current = keys.week_of(now)
    for move in moves:
        threshold = move.crossed()
        if threshold is None or (move.target.week is not None and move.target.week != current):
            continue
        board = move.target.board(current)
        title = board_title(board, catalog.names)
        await notify(
            db,
            user_id,
            kind="rank_milestone",
            title=f"You're in the top {threshold}!",
            body=f"#{move.after} on {title}. Keep it up.",
            icon="trophy",
            action={"route": "/leaderboards", "params": {"board": board.id}},
            key=f"rank_milestone:{board.id}:{threshold}:{current.isoformat()}",
        )
    return moves


def _live_week(week: date, now: datetime) -> bool:
    """Only this week's and last week's boards are kept."""
    current = keys.week_of(now)
    return week in (current, current - timedelta(days=7))


async def rating_targets(
    db: AsyncSession, user_id: uuid.UUID, scopes: list[str], *, now: datetime
) -> dict[Target, Entry | None]:
    found = await boards.rating_entries(db, now=now, user_id=user_id)
    return {Target("r", scope): found.get((user_id, scope)) for scope in scopes}


async def sync_user(db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, now: datetime) -> None:
    """Recompute every entry of the player (this week, last week and ratings)."""
    catalog = await boards.load_catalog(db)
    entries: dict[Target, Entry | None] = {}
    current = keys.week_of(now)
    for week in (current, current - timedelta(days=7)):
        xp = await boards.weekly_xp(db, week, user_id=user_id)
        entries[Target("xp", week=week)] = xp.get(user_id)
        points = await boards.weekly_points(db, week, user_id=user_id)
        for subject in catalog.names:
            entries[Target("wk", subject, week)] = points.get((user_id, subject))
    entries.update(await rating_targets(db, user_id, [OVERALL, *catalog.names], now=now))
    await refresh(db, redis, user_id, entries, now=now, catalog=catalog)


# --- Outbox handlers ----------------------------------------------------------------------------


async def _on_xp(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    user_id = uuid.UUID(payload["user_id"])
    week = keys.week_of(date.fromisoformat(payload["ist_day"]))
    if not _live_week(week, ctx.now):
        return
    found = await boards.weekly_xp(ctx.db, week, user_id=user_id)
    await refresh(
        ctx.db, ctx.redis, user_id, {Target("xp", week=week): found.get(user_id)}, now=ctx.now
    )


async def _on_match(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    match = await ctx.db.get(Match, uuid.UUID(payload["match_id"]))
    if match is None or match.status != MatchStatus.SETTLED.value or match.finished_at is None:
        return
    catalog = await boards.load_catalog(ctx.db)
    slug = (await ctx.db.get_one(Subject, match.subject_id)).slug
    seats = (
        await ctx.db.scalars(select(MatchParticipant).where(MatchParticipant.match_id == match.id))
    ).all()
    if any(seat.is_bot for seat in seats):
        return
    week = keys.week_of(match.finished_at)
    for seat in sorted(seats, key=lambda s: str(s.user_id)):
        if seat.user_id is None:
            continue
        entries: dict[Target, Entry | None] = {}
        if match.kind in boards.POINTS_KINDS and _live_week(week, ctx.now):
            points = await boards.weekly_points(ctx.db, week, user_id=seat.user_id, subject=slug)
            entries[Target("wk", slug, week)] = points.get((seat.user_id, slug))
        if match.kind in RATED_KINDS:
            entries.update(await rating_targets(ctx.db, seat.user_id, [OVERALL, slug], now=ctx.now))
        if entries:
            await refresh(ctx.db, ctx.redis, seat.user_id, entries, now=ctx.now, catalog=catalog)


async def _on_sync(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    await sync_user(ctx.db, ctx.redis, uuid.UUID(payload["user_id"]), now=ctx.now)


register(XP_TOPIC, _on_xp)
register(MATCH_TOPIC, _on_match)
register(SYNC_TOPIC, _on_sync)


async def request_sync(db: AsyncSession, user_id: uuid.UUID, _now: datetime | None = None) -> None:
    """Queue a full refresh of the player's entries (in the caller's transaction)."""
    await enqueue(db, SYNC_TOPIC, {"user_id": str(user_id)}, key=f"{SYNC_TOPIC}:{new_id()}")
