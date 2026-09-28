"""Matches data for social features: "played with" and the profile's ``ratings``, ``form`` and
``h2h`` sections (docs/api-play.md, "Profiles and stats").

Social decides who may see what (a minor seen by a non-friend gets none of these, blocked
players get a 404); these only read the data.
"""

import uuid
from typing import Any

from sqlalchemy import exists, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.modules.matches.models import (
    HeadToHead,
    Match,
    MatchKind,
    MatchParticipant,
    MatchStatus,
)
from app.modules.ratings.models import OVERALL, Rating
from app.modules.ratings.service import rating_out

FORM_GAMES = 5
FORM_RESULTS = ("win", "draw", "loss")


async def have_played(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    """Whether the two players met in a settled match (for "played with" privacy)."""
    lo, hi = sorted((a, b))
    if await db.get(HeadToHead, (lo, hi)) is not None:
        return True
    mine, theirs = aliased(MatchParticipant), aliased(MatchParticipant)
    return bool(
        await db.scalar(
            select(
                exists()
                .where(mine.user_id == a, theirs.user_id == b, theirs.match_id == mine.match_id)
                .where(Match.id == mine.match_id, Match.status == MatchStatus.SETTLED.value)
            )
        )
    )


async def profile_ratings(
    db: AsyncSession, _viewer_id: uuid.UUID, target_id: uuid.UUID
) -> list[dict[str, Any]]:
    """``[{"scope", "rating", "position"}]``: overall first, then subjects by name. Positions
    belong to the leaderboards (null until they rank the player)."""
    rows = list(
        await db.scalars(select(Rating).where(Rating.user_id == target_id, Rating.games > 0))
    )
    rows.sort(key=lambda row: (row.scope != OVERALL, row.scope))
    return [{"scope": row.scope, "rating": rating_out(row), "position": None} for row in rows]


async def profile_form(db: AsyncSession, _viewer_id: uuid.UUID, target_id: uuid.UUID) -> list[str]:
    """The last 5 results against people, newest first (Practice Bot games don't count)."""
    rows = await db.scalars(
        select(MatchParticipant.result)
        .join(Match, Match.id == MatchParticipant.match_id)
        .where(
            MatchParticipant.user_id == target_id,
            MatchParticipant.result.in_(FORM_RESULTS),
            Match.status == MatchStatus.SETTLED.value,
            Match.kind != MatchKind.BOT.value,
        )
        .order_by(Match.settled_at.desc(), Match.id.desc())
        .limit(FORM_GAMES)
    )
    return [str(result) for result in rows]


async def profile_h2h(
    db: AsyncSession, viewer_id: uuid.UUID, target_id: uuid.UUID
) -> dict[str, int] | None:
    """The viewer's record against the player (``wins`` are the viewer's), or null if they
    never finished a game together."""
    lo, hi = sorted((viewer_id, target_id))
    row = await db.get(HeadToHead, (lo, hi))
    if row is None:
        return None
    wins, losses = (row.lo_wins, row.hi_wins) if viewer_id == lo else (row.hi_wins, row.lo_wins)
    return {"wins": wins, "draws": row.draws, "losses": losses}
