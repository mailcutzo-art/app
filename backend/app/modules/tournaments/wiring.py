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
from collections.abc import Sequence
from datetime import datetime
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.modules.content.models import Subject
from app.modules.economy.jobs import HoldRef, register_liveness
from app.modules.economy.models import RefKind
from app.modules.home.service import HomeContext, register_home_section
from app.modules.leaderboards.service import HallEntry, register_hall_of_fame
from app.modules.matches.busy import register_busy_check
from app.modules.matches.ports import Integrations, integrations
from app.modules.moderation.service import register_ban_hook
from app.modules.tournaments import service
from app.modules.tournaments.models import (
    TERMINAL,
    Tournament,
    TournamentEntry,
    TournamentPrize,
    TournamentStatus,
)
from app.modules.tournaments.results import settlement_hook
from app.modules.tournaments.standings_view import standings_snapshot
from app.modules.users.deletion import on_account_deleted
from app.modules.users.models import User


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


async def hall_entries(db: AsyncSession, subject: str, limit: int) -> Sequence[HallEntry]:
    """Leaderboards' Hall of Fame: the latest winners of finished tournaments in ``subject``
    (``""``: all-subject ones), newest first, valued by their points."""
    statement = (
        select(Tournament, TournamentPrize, TournamentEntry.points)
        .join(
            TournamentPrize,
            and_(TournamentPrize.tournament_id == Tournament.id, TournamentPrize.place == 1),
        )
        .outerjoin(
            TournamentEntry,
            and_(
                TournamentEntry.tournament_id == Tournament.id,
                TournamentEntry.user_id == TournamentPrize.user_id,
            ),
        )
        .where(Tournament.status == TournamentStatus.FINISHED)
        .order_by(Tournament.finished_at.desc(), Tournament.id.desc())
        .limit(limit)
    )
    if subject:
        statement = statement.join(Subject, Subject.id == Tournament.subject_id).where(
            Subject.slug == subject
        )
    else:
        statement = statement.where(Tournament.subject_id.is_(None))
    rows = (await db.execute(statement)).all()
    return [
        HallEntry(user_id=prize.user_id, value=round(points or 0), value_display=t.title)
        for t, prize, points in rows
    ]


async def home_tournament(ctx: HomeContext) -> dict[str, Any] | None:
    """Home's tournament card: the player's own live one, else the next open one."""
    user = await ctx.db.get_one(User, ctx.user_id)
    return await service.next_tournament(ctx.db, get_settings(), user, ctx.now)


async def home_live(ctx: HomeContext) -> dict[str, Any] | None:
    """Home's ``live``: a tournament that needs the player now (checked in and running, or
    check-in closing)."""
    found = await service.busy_check(
        ctx.db, ctx.redis, ctx.user_id, int(ctx.now.timestamp() * 1000)
    )
    if found is None:
        return None
    out = found.model_dump(mode="json")
    return {**out, "action": {"params": {}, **out["action"]}, "state": None, "until": None}


def install() -> None:
    register_hall_of_fame(hall_entries)
    register_home_section("tournament", home_tournament)
    register_home_section("live", home_live)
    connect(integrations, get_settings())
    register_busy_check(service.busy_check)
    register_liveness(RefKind.TOURNAMENT, hold_live)
    register_ban_hook(withdraw_on_ban)
    on_account_deleted(withdraw_on_delete)
