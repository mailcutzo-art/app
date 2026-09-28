"""Standings as stored: recomputed from the pairings with the pure ``standings`` rules inside
each settlement (at most 256 rows), and read back for ``t.standings`` and the REST table."""

import uuid
from collections.abc import Sequence
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.matches.players import load_players
from app.modules.tournaments.models import (
    PairingStatus,
    Tournament,
    TournamentEntry,
    TournamentPairing,
)
from app.modules.tournaments.standings import Entrant, GameResult, RoundRecord, compute_standings


async def field_entries(db: AsyncSession, tournament_id: uuid.UUID) -> list[TournamentEntry]:
    """The players of a started tournament (checked in at the start), registration order."""
    return list(
        await db.scalars(
            select(TournamentEntry)
            .where(TournamentEntry.tournament_id == tournament_id, TournamentEntry.checked_in)
            .order_by(TournamentEntry.registered_at, TournamentEntry.user_id)
        )
    )


def _records(pairings: Sequence[TournamentPairing]) -> dict[uuid.UUID, list[RoundRecord]]:
    out: dict[uuid.UUID, list[RoundRecord]] = {}
    for p in pairings:
        if p.status != PairingStatus.DONE or p.result_a is None:
            continue
        opponent = str(p.b_id) if p.b_id is not None else None
        out.setdefault(p.a_id, []).append(RoundRecord(p.round, opponent, _r(p.result_a)))
        if p.b_id is not None and p.result_b is not None:
            out.setdefault(p.b_id, []).append(RoundRecord(p.round, str(p.a_id), _r(p.result_b)))
    return out


def _r(value: str) -> GameResult:
    return GameResult(value)


async def recompute(db: AsyncSession, tournament: Tournament) -> list[TournamentEntry]:
    """Points, tie-breaks, W/D/L and live ranks of every player, from the finished pairings.
    Returns the entries in rank order."""
    entries = await field_entries(db, tournament.id)
    if not entries:
        return []
    pairings = (
        await db.scalars(
            select(TournamentPairing).where(TournamentPairing.tournament_id == tournament.id)
        )
    ).all()
    records = _records(pairings)
    entrants = [
        Entrant(
            id=str(entry.user_id),
            registered_order=order,
            withdrawn=entry.withdrawn,
            records=records.get(entry.user_id, ()),
            quiz_points=entry.quiz_points,
            correct_count=entry.correct_count,
            correct_time_ms=entry.correct_time_ms,
        )
        for order, entry in enumerate(entries)
    ]
    rounds = max([tournament.current_round, *(p.round for p in pairings)], default=0)
    by_id = {str(entry.user_id): entry for entry in entries}
    ranked: list[TournamentEntry] = []
    for row in compute_standings(entrants, rounds):
        entry = by_id[row.entrant_id]
        entry.points = row.points
        entry.bh = row.buchholz
        entry.bh_c1 = row.buchholz_cut1
        entry.sb = row.sonneborn_berger
        entry.rank = row.rank
        results = [r.result for r in records.get(entry.user_id, ())]
        entry.wins = sum(r in {GameResult.WIN, GameResult.FORFEIT_WIN} for r in results)
        entry.draws = sum(r == GameResult.DRAW for r in results)
        entry.losses = sum(
            r in {GameResult.LOSS, GameResult.FORFEIT_LOSS, GameResult.DOUBLE_FORFEIT}
            for r in results
        )
        ranked.append(entry)
    await db.flush()
    return ranked


def points_out(value: float) -> float | int:
    """3.0 as 3, 2.5 as 2.5."""
    return int(value) if float(value).is_integer() else value


async def standings_snapshot(db: AsyncSession, tournament_id: uuid.UUID) -> dict[str, Any] | None:
    """The ``t.standings`` payload (``me`` is added per viewer by the gateway)."""
    tournament = await db.get(Tournament, tournament_id)
    if tournament is None:
        return None
    entries = [e for e in await field_entries(db, tournament_id) if e.rank is not None]
    entries.sort(key=lambda e: e.rank or 0)
    players = await load_players(db, [e.user_id for e in entries])
    rows = []
    for entry in entries:
        info = players.get(entry.user_id)
        rows.append(
            {
                "rank": entry.rank,
                "uid": str(entry.user_id),
                "name": info.display_name if info else "Player",
                "avatar": {"tone": info.tone, "symbol": info.symbol} if info else None,
                "points": points_out(entry.points),
                "w": entry.wins,
                "d": entry.draws,
                "l": entry.losses,
                "bh_c1": points_out(entry.bh_c1),
                "bh": points_out(entry.bh),
                "sb": points_out(entry.sb),
                "withdrawn": entry.withdrawn,
            }
        )
    return {"tournament_id": str(tournament_id), "round": tournament.current_round, "rows": rows}
