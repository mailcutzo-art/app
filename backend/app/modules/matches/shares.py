"""Battle results for the social "share a win" feature (``social.shares``).

Only the player's own settled match can be shared: aborted and voided games have no result, and a
live one isn't over yet.
"""

import uuid
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import Subject
from app.modules.economy.models import LedgerEntry
from app.modules.matches.models import (
    Match,
    MatchAnswer,
    MatchParticipant,
    MatchQuestion,
    MatchStatus,
)
from app.modules.progression.models import XpEvent


async def match_share_source(
    db: AsyncSession, user_id: uuid.UUID, match_ref: str
) -> dict[str, Any] | None:
    try:
        match_id = uuid.UUID(match_ref)
    except ValueError:
        return None
    row = (
        await db.execute(
            select(Match, Subject.name)
            .join(Subject, Subject.id == Match.subject_id)
            .where(Match.id == match_id, Match.status == MatchStatus.SETTLED)
        )
    ).one_or_none()
    if row is None:
        return None
    match, subject = row
    seats = list(
        await db.scalars(
            select(MatchParticipant)
            .where(MatchParticipant.match_id == match_id)
            .order_by(MatchParticipant.seat)
        )
    )
    mine = next((seat for seat in seats if seat.user_id == user_id), None)
    if mine is None or mine.result not in ("win", "draw", "loss"):
        return None
    others = [seat for seat in seats if seat.seat != mine.seat]
    # In a group battle the opponent is the best other player.
    best = max(others, key=lambda seat: seat.score, default=None)

    positions = list(
        await db.scalars(
            select(MatchQuestion.position)
            .where(MatchQuestion.match_id == match_id)
            .order_by(MatchQuestion.position)
        )
    )
    answers = {
        answer.position: answer
        for answer in await db.scalars(
            select(MatchAnswer).where(
                MatchAnswer.match_id == match_id, MatchAnswer.seat == mine.seat
            )
        )
    }

    def outcome(position: int) -> str:
        answer = answers.get(position)
        if answer is None or answer.option_id is None:
            return "skipped"
        return "correct" if answer.is_correct else "wrong"

    chapter = match.sources[0].get("name") if len(match.sources) == 1 else None
    rating_change = (
        round(mine.rating_after - mine.rating_before)
        if mine.rating_before is not None and mine.rating_after is not None
        else None
    )
    coins = await db.scalar(
        select(func.sum(LedgerEntry.delta)).where(
            LedgerEntry.user_id == user_id,
            LedgerEntry.ref_kind == "match",
            LedgerEntry.ref_id == str(match_id),
        )
    )
    xp = await db.scalar(
        select(func.sum(XpEvent.amount)).where(
            XpEvent.user_id == user_id, XpEvent.ref_id == match_id
        )
    )
    return {
        "match_id": match_id,
        "mode": match.kind,
        "result": mine.result,
        "subject": subject,
        "chapter": chapter,
        "score": mine.score,
        "opponent_score": best.score if best else 0,
        "opponent_id": best.user_id if best and not best.is_bot else None,
        "opponent_name": best.card.get("display_name") if best and best.is_bot else None,
        "questions": [outcome(position) for position in positions],
        "rating_change": rating_change,
        "coins": int(coins) if coins is not None else None,
        "xp": int(xp) if xp is not None else None,
    }
