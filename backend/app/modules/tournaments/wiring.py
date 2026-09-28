"""Connecting tournaments to the rest of the app, at process start (``install``):

- the settlement hook (first among the progress hooks: the tournament row is locked before
  progress rows and wallets) and the ``t.standings`` snapshot for ``sub``;
- the busy check that keeps registered and checked-in players out of games that would clash;
- the hold reaper's liveness check: an entry fee stays held while its tournament hasn't
  started (or been cancelled) and the player is still in;
- a ban or an account deletion withdraws the player from every tournament not yet over
  (refunded before the start).
"""

import uuid
from datetime import datetime

from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.modules.economy.jobs import HoldRef, register_liveness
from app.modules.economy.models import RefKind
from app.modules.matches.busy import register_busy_check
from app.modules.matches.ports import Integrations, integrations
from app.modules.moderation.service import register_ban_hook
from app.modules.tournaments import service
from app.modules.tournaments.models import TERMINAL, Tournament, TournamentEntry
from app.modules.tournaments.results import settlement_hook
from app.modules.tournaments.standings_view import standings_snapshot
from app.modules.users.deletion import on_account_deleted


async def hold_live(db: AsyncSession, _redis: Redis, ref: HoldRef) -> bool:
    try:
        tournament_id = uuid.UUID(ref.ref_id)
    except ValueError:
        return False
    row = (
        await db.execute(
            select(Tournament.status, TournamentEntry.withdrawn, TournamentEntry.hold_id)
            .join(TournamentEntry, TournamentEntry.tournament_id == Tournament.id)
            .where(Tournament.id == tournament_id, TournamentEntry.user_id == ref.user_id)
        )
    ).first()
    if row is None:
        return False
    status, withdrawn, hold_id = row
    return status not in TERMINAL and not withdrawn and hold_id == ref.hold_id


async def withdraw_everywhere(
    db: AsyncSession, user_id: uuid.UUID, now: datetime, reason: str
) -> None:
    ids = list(
        await db.scalars(
            select(TournamentEntry.tournament_id)
            .join(Tournament, Tournament.id == TournamentEntry.tournament_id)
            .where(
                TournamentEntry.user_id == user_id,
                ~TournamentEntry.withdrawn,
                Tournament.status.not_in([s.value for s in TERMINAL]),
            )
            .order_by(TournamentEntry.tournament_id)
        )
    )
    for tournament_id in ids:
        t = await service.locked(db, tournament_id)
        entry = await db.get(TournamentEntry, (tournament_id, user_id), populate_existing=True)
        if entry is not None and not entry.withdrawn and t.status not in TERMINAL:
            await service.withdraw_entry(db, t, entry, now=now, reason=reason)


async def withdraw_on_ban(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> None:
    await withdraw_everywhere(db, user_id, now, "banned")


async def withdraw_on_delete(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> None:
    await withdraw_everywhere(db, user_id, now, "deleted")


def connect(target: Integrations, settings: Settings) -> Integrations:
    target.progress_hooks.register("tournament", settlement_hook(settings), first=True)
    target.standings = standings_snapshot
    return target


def install() -> None:
    connect(integrations, get_settings())
    register_busy_check(service.busy_check)
    register_liveness(RefKind.TOURNAMENT, hold_live)
    register_ban_hook(withdraw_on_ban)
    on_account_deleted(withdraw_on_delete)
