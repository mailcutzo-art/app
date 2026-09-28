"""The leaderboards in the rest of the app: settlement, the Battle tab, profiles and visibility.

``install()`` (called from ``app.modules.matches.wiring.install``) registers:

- the ``leaderboards`` settlement hook: queues ``lb.match`` for settled games against people and
  adds ``match.settled.rank`` after a rated game: ``{"board": "rating:physics", "before": 47,
  "after": 42}``, or ``{"board", "games_to_rank"}`` while the player isn't on the board. The
  position after is predicted from the new rating (the board itself is written by the outbox
  handler once the settlement commits);
- ``integrations.leaders`` for the Battle tab: "Physics this week: Riya leads · you're #12";
- ``ratings[].position`` on public profiles;
- visibility hooks (bans, the shadow pool, account deletion and restore, the public-boards
  setting) that queue ``lb.sync_user``.

Positions are on the player's own exam's boards (All India without an exam, or for a subject
their exam doesn't include).
"""

import uuid
from collections.abc import Mapping, Sequence
from datetime import datetime
from typing import Any

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.modules.leaderboards import boards, keys, service
from app.modules.leaderboards.boards import primary_view
from app.modules.leaderboards.events import MATCH_TOPIC, request_sync
from app.modules.matches.models import RATED_KINDS
from app.modules.matches.ports import Integrations, SettlementContext
from app.modules.moderation.models import ModerationKind
from app.modules.moderation.service import register_action_hook, register_ban_hook
from app.modules.outbox.service import enqueue
from app.modules.ratings.models import Rating
from app.modules.social.privacy import register_privacy_hook
from app.modules.social.profiles import register_rating_positions
from app.modules.users.deletion import on_account_deleted, on_account_restored
from app.modules.users.models import User

Pieces = Mapping[uuid.UUID, Mapping[str, Any]]


async def rank_fragment(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, subject: str, *, now: datetime
) -> dict[str, Any] | None:
    """``match.settled.rank`` for a rated game in ``subject`` (after the rating was applied)."""
    user = await db.get(User, user_id)
    if user is None or user_id in await boards.hidden_ids(db, now=now, among=[user_id]):
        return None
    board = f"rating:{subject}"
    row = await db.get(Rating, (user_id, subject))
    if row is None or not boards.rating_eligible(row, now):
        return {"board": board, "games_to_rank": boards.games_to_rank(row, now)}
    catalog = await boards.load_catalog(db)
    view = primary_view(user.goal)
    if not catalog.allowed(subject, view):
        view = keys.ALL
    key = keys.rating_key(view, subject)
    score = boards.rating_entry(row).score
    before = await boards.position(redis, key, user_id)
    higher = int(await redis.zcount(key, f"({score!r}", "+inf"))
    current = await redis.zscore(key, str(user_id))
    if current is not None and float(current) > score:
        higher -= 1  # the player's own old entry
    return {"board": board, "before": before, "after": higher + 1}


async def settlement_hook(ctx: SettlementContext) -> Pieces:
    if ctx.status != "settled" or ctx.has_bot or ctx.kind not in boards.POINTS_KINDS:
        return {}
    await enqueue(
        ctx.db, MATCH_TOPIC, {"match_id": str(ctx.match_id)}, key=f"{MATCH_TOPIC}:{ctx.match_id}"
    )
    if ctx.kind not in RATED_KINDS or ctx.redis is None:
        return {}
    pieces: dict[uuid.UUID, Mapping[str, Any]] = {}
    for player in ctx.players:
        if player.rating_delta is None:
            continue
        pieces[player.user_id] = {
            "rank": await rank_fragment(ctx.db, ctx.redis, player.user_id, ctx.subject, now=ctx.now)
        }
    return pieces


async def leaders(
    db: AsyncSession, redis: Redis, viewer_id: uuid.UUID, subjects: Sequence[str]
) -> Mapping[str, Mapping[str, Any]]:
    """Per subject: this week's leader on the viewer's exam board and the viewer's position."""
    viewer = await db.get(User, viewer_id)
    goal = viewer.goal if viewer is not None else None
    now = utc_now()
    out: dict[str, Mapping[str, Any]] = {}
    for subject in subjects:
        board = keys.Board(keys.Family.WEEKLY_SUBJECT, subject)
        rows, me = await service.weekly_leaders(
            db, redis, viewer_id, board, goal=goal, top=1, now=now
        )
        out[subject] = {
            "leader": rows[0].model_dump(mode="json") if rows else None,
            "me": {"position": me.position if me else None},
        }
    return out


async def profile_positions(
    db: AsyncSession, redis: Redis, target_id: uuid.UUID, ratings: list[Any]
) -> list[Any]:
    target = await db.get(User, target_id)
    scopes = [str(item["scope"]) for item in ratings]
    found = await service.rating_positions(
        redis, target_id, target.goal if target else None, scopes
    )
    # Only items with a ``position`` slot get one (a provider may leave it out).
    return [
        {**item, "position": found.get(str(item["scope"]))} if "position" in item else item
        for item in ratings
    ]


async def _sync_after(db: AsyncSession, user_id: uuid.UUID, _now: datetime) -> None:
    await request_sync(db, user_id)


async def _sync_after_action(
    db: AsyncSession, user_id: uuid.UUID, kind: ModerationKind, _now: datetime
) -> None:
    if kind == ModerationKind.SHADOW_POOL:
        await request_sync(db, user_id)


async def _sync_after_privacy(db: AsyncSession, user_id: uuid.UUID) -> None:
    await request_sync(db, user_id)


def connect(target: Integrations) -> None:
    target.leaders = leaders
    target.hooks.register("leaderboards", settlement_hook)


def install() -> None:
    register_rating_positions(profile_positions)
    register_ban_hook(_sync_after)
    on_account_deleted(_sync_after)
    on_account_restored(_sync_after)
    register_action_hook(_sync_after_action)
    register_privacy_hook(_sync_after_privacy)
