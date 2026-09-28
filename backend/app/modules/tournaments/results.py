"""Tournament game results: the settlement hook and everything a result changes.

The hook runs inside the match's settlement transaction, first among the progress hooks, so
the lock order is the tournament's everywhere: tournament row, entries, then progress rows and
wallets. It records the pairing's result (once: a settled pairing is never touched again),
adds the quiz points, counts missed rounds (two in a row withdraw the player), recomputes the
standings, schedules ``t.standings`` and, when the round's last game is in, closes the round
so the worker pairs the next one after the pause.
"""

import uuid
from collections.abc import Mapping
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.modules.matches.models import MatchAnswer
from app.modules.matches.ports import SettlementContext, SettlementHook
from app.modules.notifications.service import notify
from app.modules.tournaments import events
from app.modules.tournaments.models import (
    PairingStatus,
    RoundStatus,
    Tournament,
    TournamentEntry,
    TournamentPairing,
    TournamentRound,
    TournamentStatus,
)
from app.modules.tournaments.standings import GameResult
from app.modules.tournaments.standings_view import recompute

MISSED = frozenset({GameResult.FORFEIT_LOSS, GameResult.DOUBLE_FORFEIT})
ABSENCE_LIMIT = 2


def _pairing_results(ctx: SettlementContext) -> dict[uuid.UUID, GameResult]:
    """Each player's result: played games as they ended, no-shows as forfeits, and a void
    (both dropped) as a double forfeit."""
    if ctx.status == "aborted":  # nobody showed
        return {p.user_id: GameResult.DOUBLE_FORFEIT for p in ctx.players}
    if ctx.status != "settled":
        return {p.user_id: GameResult.DOUBLE_FORFEIT for p in ctx.players}
    if ctx.reason == "no_show":
        return {
            p.user_id: GameResult.FORFEIT_LOSS if p.forfeited else GameResult.FORFEIT_WIN
            for p in ctx.players
        }
    return {p.user_id: GameResult(p.result) for p in ctx.players}


async def _correct_ms(db: AsyncSession, match_id: uuid.UUID) -> dict[uuid.UUID, tuple[int, int]]:
    rows = await db.execute(
        select(MatchAnswer.user_id, func.count(), func.coalesce(func.sum(MatchAnswer.time_ms), 0))
        .where(MatchAnswer.match_id == match_id, MatchAnswer.is_correct)
        .group_by(MatchAnswer.user_id)
    )
    return {
        user_id: (int(count or 0), int(total or 0)) for user_id, count, total in rows if user_id
    }


def settlement_hook(settings: Settings) -> SettlementHook:
    """``matches.ports.SettlementHooks`` entry (a progress hook, registered first)."""

    async def hook(ctx: SettlementContext) -> Mapping[uuid.UUID, Mapping[str, Any]]:
        if ctx.kind == "tournament":
            await record_game(ctx, settings)
        return {}

    return hook


async def record_game(ctx: SettlementContext, settings: Settings) -> None:
    db = ctx.db
    tournament_id = await db.scalar(
        select(TournamentPairing.tournament_id).where(TournamentPairing.match_id == ctx.match_id)
    )
    if tournament_id is None:
        return
    t = await db.get(Tournament, tournament_id, with_for_update=True, populate_existing=True)
    pairing = await db.scalar(
        select(TournamentPairing)
        .where(TournamentPairing.match_id == ctx.match_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if t is None or pairing is None or pairing.status == PairingStatus.DONE:
        return
    if t.status != TournamentStatus.RUNNING:
        return  # cancelled meanwhile: the game's rating stands, nothing else changes
    await record_pairing(
        db,
        settings,
        t,
        pairing,
        _pairing_results(ctx),
        scores={p.user_id: p.score for p in ctx.players},
        correct=await _correct_ms(db, ctx.match_id),
        counts_absence=ctx.reason == "no_show" or ctx.status == "aborted",
        now=ctx.now,
    )


async def record_pairing(
    db: AsyncSession,
    settings: Settings,
    t: Tournament,
    pairing: TournamentPairing,
    results: Mapping[uuid.UUID, GameResult],
    *,
    scores: Mapping[uuid.UUID, int],
    correct: Mapping[uuid.UUID, tuple[int, int]],
    counts_absence: bool,
    now: datetime,
) -> None:
    """Store one board's result (the tournament row is locked) and everything it changes."""
    pairing.status = PairingStatus.DONE.value
    pairing.finished_at = now
    pairing.result_a = results[pairing.a_id].value
    pairing.score_a = scores.get(pairing.a_id, 0)
    players = [pairing.a_id]
    if pairing.b_id is not None:
        pairing.result_b = results[pairing.b_id].value
        pairing.score_b = scores.get(pairing.b_id, 0)
        players.append(pairing.b_id)
    for user_id in sorted(players):
        entry = await db.get_one(
            TournamentEntry, (t.id, user_id), with_for_update=True, populate_existing=True
        )
        entry.quiz_points += scores.get(user_id, 0)
        count, time_ms = correct.get(user_id, (0, 0))
        entry.correct_count += count
        entry.correct_time_ms += time_ms
        missed = results[user_id] in MISSED and counts_absence
        entry.absences = entry.absences + 1 if missed else 0
        if missed and entry.absences >= ABSENCE_LIMIT and not entry.withdrawn:
            entry.withdrawn = True
            entry.withdrawn_at = now
            entry.withdraw_reason = "absent"
            await notify(
                db,
                user_id,
                kind="tournament_withdrawn",
                title=f"Withdrawn from {t.title}",
                body="You missed two rounds in a row, so you were taken out of the tournament. "
                "Your games so far still count for the standings.",
                icon="trophy",
                action={"route": f"/arena/{t.id}", "params": {}},
                key=f"tournament_withdrawn:{t.id}",
            )
    await db.flush()
    await recompute(db, t)
    await events.schedule_standings(
        db, t.id, now=now, interval_ms=settings.tournament_standings_interval_ms
    )
    await close_round_if_done(db, settings, t, pairing.round, now=now)


async def close_round_if_done(
    db: AsyncSession, settings: Settings, t: Tournament, number: int, *, now: datetime
) -> bool:
    """Once every board of the round has a result: the round is done and the next pairing is
    due after the pause."""
    pending = await db.scalar(
        select(func.count()).where(
            TournamentPairing.tournament_id == t.id,
            TournamentPairing.round == number,
            TournamentPairing.status == PairingStatus.PENDING,
        )
    )
    if pending:
        return False
    row = await db.get_one(TournamentRound, (t.id, number), populate_existing=True)
    if row.status == RoundStatus.DONE:
        return False
    row.status = RoundStatus.DONE.value
    row.finished_at = now
    t.next_action_at = now + timedelta(seconds=settings.tournament_pause_s)
    await events.channel_event(
        db,
        t.id,
        "t.round",
        {
            "round": number,
            "status": "done",
            "starts_at": _ms(row.started_at),
            "ends_at": _ms(now),
            "next_at": _ms(t.next_action_at),
        },
        key=f"round:{t.id}:{number}:done",
    )
    await db.flush()
    return True


def _ms(moment: datetime | None) -> int | None:
    return int(moment.timestamp() * 1000) if moment is not None else None
