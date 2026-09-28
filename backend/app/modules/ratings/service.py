"""Reading ratings for display and applying Glicko-2 after a rated game.

Every rated game updates ``overall`` and the subject's scope. Both players are rated against
the other's pre-game values, and rows are locked in (user, scope) order so concurrent
settlements of one player never deadlock.
"""

import math
import uuid
from collections.abc import Collection, Sequence
from dataclasses import dataclass
from datetime import datetime
from fractions import Fraction
from typing import Any

from sqlalchemy import select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.ratings import glicko2
from app.modules.ratings.models import OVERALL, Rating, RatingHistory

SECONDS_PER_PERIOD = glicko2.PERIOD_DAYS * 24 * 60 * 60


def to_glicko(row: Rating | None) -> glicko2.Rating:
    if row is None:
        return glicko2.Rating()
    return glicko2.Rating(row.rating, row.rd, row.volatility)


def shown(value: float) -> int:
    """The rating as displayed, rounded half up."""
    return math.floor(Fraction(value) + Fraction(1, 2))


def rating_out(row: Rating | None) -> dict[str, Any]:
    """``{"display", "value", "provisional"}``: "—" before any rated game, "1523?" while
    provisional, "1523" once settled."""
    games = row.games if row is not None else 0
    rating = to_glicko(row)
    return {
        "display": glicko2.display_rating(rating, games),
        "value": shown(rating.rating) if games > 0 else None,
        "provisional": games == 0 or rating.rd > glicko2.PROVISIONAL_RD,
    }


async def load_ratings(
    db: AsyncSession, user_ids: Collection[uuid.UUID], scope: str
) -> dict[uuid.UUID, Rating]:
    rows = await db.scalars(
        select(Rating).where(Rating.user_id.in_(list(user_ids)), Rating.scope == scope)
    )
    return {row.user_id: row for row in rows}


@dataclass(frozen=True, slots=True)
class RatingChange:
    scope: str
    before: glicko2.Rating
    after: glicko2.Rating
    games_before: int

    @property
    def delta(self) -> int:
        return shown(self.after.rating) - shown(self.before.rating)

    def settled_out(self) -> dict[str, Any]:
        """``match.settled.rating``."""
        return {
            "scope": self.scope,
            "before": glicko2.display_rating(self.before, self.games_before),
            "after": glicko2.display_rating(self.after, self.games_before + 1),
            "delta": self.delta,
        }


def _idle_periods(row: Rating, now: datetime) -> float:
    if row.last_played_at is None or row.games == 0:
        return 0.0
    return max(0.0, (now - row.last_played_at).total_seconds() / SECONDS_PER_PERIOD)


async def apply_game(
    db: AsyncSession,
    *,
    match_id: uuid.UUID,
    a: uuid.UUID,
    b: uuid.UUID,
    score_a: float,
    subject: str,
    now: datetime,
) -> dict[uuid.UUID, dict[str, RatingChange]]:
    """Rate one game between ``a`` and ``b`` in ``overall`` and ``subject``.

    Idempotent per match: if the history already has this match, nothing changes and the
    recorded changes are returned.
    """
    scopes = sorted({OVERALL, subject})
    keys = sorted((user, scope) for user in (a, b) for scope in scopes)
    await db.execute(
        insert(Rating)
        .values([{"user_id": user, "scope": scope} for user, scope in keys])
        .on_conflict_do_nothing()
    )
    rows = {
        (row.user_id, row.scope): row
        for row in await db.scalars(
            select(Rating)
            .where(tuple_(Rating.user_id, Rating.scope).in_(keys))
            .order_by(Rating.user_id, Rating.scope)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    }
    recorded = await _recorded(db, match_id)
    if recorded:
        return recorded

    changes: dict[uuid.UUID, dict[str, RatingChange]] = {a: {}, b: {}}
    history = []
    for scope in scopes:
        row_a, row_b = rows[(a, scope)], rows[(b, scope)]
        before_a, before_b = to_glicko(row_a), to_glicko(row_b)
        after_a, after_b = glicko2.rate_game(
            before_a,
            before_b,
            score_a,
            idle_periods_a=_idle_periods(row_a, now),
            idle_periods_b=_idle_periods(row_b, now),
        )
        for user, row, before, after in (
            (a, row_a, before_a, after_a),
            (b, row_b, before_b, after_b),
        ):
            changes[user][scope] = RatingChange(scope, before, after, row.games)
            history.append(
                {
                    "match_id": match_id,
                    "user_id": user,
                    "scope": scope,
                    "rating_before": before.rating,
                    "rd_before": before.rd,
                    "rating_after": after.rating,
                    "rd_after": after.rd,
                    "volatility_after": after.volatility,
                    "created_at": now,
                }
            )
            row.rating, row.rd, row.volatility = after.rating, after.rd, after.volatility
            row.games += 1
            row.last_played_at = now
    await db.execute(insert(RatingHistory).values(history).on_conflict_do_nothing())
    await db.flush()
    return changes


async def _recorded(
    db: AsyncSession, match_id: uuid.UUID
) -> dict[uuid.UUID, dict[str, RatingChange]]:
    rows: Sequence[RatingHistory] = (
        await db.scalars(select(RatingHistory).where(RatingHistory.match_id == match_id))
    ).all()
    out: dict[uuid.UUID, dict[str, RatingChange]] = {}
    for row in rows:
        before = glicko2.Rating(row.rating_before, row.rd_before)
        after = glicko2.Rating(row.rating_after, row.rd_after, row.volatility_after)
        # The games count before this match is no longer known exactly; one less than now.
        current = await db.get(Rating, (row.user_id, row.scope))
        games_before = max(0, (current.games if current else 1) - 1)
        out.setdefault(row.user_id, {})[row.scope] = RatingChange(
            row.scope, before, after, games_before
        )
    return out
