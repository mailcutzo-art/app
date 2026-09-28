"""Helpers for the tournament tests: tournaments, funded players, the worker and results."""

import uuid
from collections.abc import Callable, Mapping
from contextlib import AbstractAsyncContextManager
from datetime import datetime, timedelta
from typing import Any

import httpx
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.modules.content.models import Subject
from app.modules.economy.models import CoinReason
from app.modules.economy.service import credit, get_wallet
from app.modules.matches.ports import (
    Integrations,
    SettledPlayer,
    SettlementContext,
    default_integrations,
)
from app.modules.matches.settlement import SettleDeps
from app.modules.outbox.service import dispatch_due
from app.modules.tournaments import wiring
from app.modules.tournaments.lifecycle import run_due
from app.modules.tournaments.models import Tournament, TournamentPairing, TournamentStatus
from app.modules.tournaments.results import record_game
from app.modules.users.models import User

Sessions = Callable[[], AbstractAsyncContextManager[AsyncSession]]


def tournament_plugins(settings: Settings) -> Integrations:
    plugins = default_integrations()
    wiring.connect(plugins, settings)
    return plugins


async def make_tournament(
    db: AsyncSession,
    *,
    now: datetime,
    starts_in: timedelta = timedelta(hours=3),
    reg_opens_in: timedelta = timedelta(hours=1),
    fee: int = 10,
    pool: int = 1000,
    capacity: int = 64,
    min_players: int = 4,
    rounds: int = 5,
    goal: str = "neet",
    subject: str | None = "physics",
    title: str = "Physics Cup",
) -> Tournament:
    subject_id = (
        await db.scalar(select(Subject.id).where(Subject.slug == subject)) if subject else None
    )
    t = Tournament(
        title=title,
        subject_id=subject_id,
        goal=goal,
        rounds=rounds,
        entry_fee=fee,
        prize_pool=pool,
        capacity=capacity,
        min_players=min_players,
        reg_opens_at=now + reg_opens_in,
        starts_at=now + starts_in,
        status=TournamentStatus.SCHEDULED.value,
        next_action_at=now + reg_opens_in,
    )
    db.add(t)
    await db.flush()
    return t


async def funded_user(
    db: AsyncSession, name: str, *, goal: str = "neet", coins: int = 200
) -> uuid.UUID:
    user = User(
        display_name=name.title(), email=f"{name}-{uuid.uuid4().hex[:6]}@example.com", goal=goal
    )
    db.add(user)
    await db.flush()
    if coins:
        await credit(
            db,
            user.id,
            coins,
            reason=CoinReason.ADJUSTMENT,
            title="Test coins",
            key=f"seed:{user.id}",
        )
    return user.id


async def balance(db: AsyncSession, user_id: uuid.UUID) -> int:
    return (await get_wallet(db, user_id)).balance


def deps(redis: Redis, sessions: Sessions, settings: Settings) -> SettleDeps:
    return SettleDeps(
        redis=redis,
        sessionmaker=sessions,
        settings=settings,
        integrations=tournament_plugins(settings),
    )


async def tick(worker: SettleDeps, now: datetime) -> int:
    return await run_due(worker, now=now)


async def status(sessions: Sessions, tournament_id: uuid.UUID) -> Tournament:
    async with sessions() as db:
        return await db.get_one(Tournament, tournament_id, populate_existing=True)


async def pending(
    sessions: Sessions, tournament_id: uuid.UUID, number: int
) -> list[TournamentPairing]:
    async with sessions() as db:
        return list(
            await db.scalars(
                select(TournamentPairing)
                .where(
                    TournamentPairing.tournament_id == tournament_id,
                    TournamentPairing.round == number,
                    TournamentPairing.status == "pending",
                )
                .order_by(TournamentPairing.board)
            )
        )


async def settle_game(
    sessions: Sessions,
    settings: Settings,
    pairing: TournamentPairing,
    outcome: Mapping[uuid.UUID, str],
    *,
    now: datetime,
    reason: str = "normal",
    status: str = "settled",
    scores: Mapping[uuid.UUID, int] | None = None,
) -> None:
    """Settle a tournament game through the settlement hook. ``outcome`` is win, draw or loss
    per player; ``reason="no_show"`` with ``loss`` marks the absent player."""
    assert pairing.match_id is not None
    assert pairing.b_id is not None
    async with sessions() as db:
        players = [
            SettledPlayer(
                user_id=user_id,
                result=outcome.get(user_id, "aborted"),
                score=(scores or {}).get(user_id, 0),
                correct=0,
                answered=0,
                place=None,
                forfeited=reason == "no_show" and outcome.get(user_id) == "loss",
                rating_delta=None,
            )
            for user_id in (pairing.a_id, pairing.b_id)
        ]
        ctx = SettlementContext(
            db=db,
            match_id=pairing.match_id,
            kind="tournament",
            status=status,
            reason=reason,
            subject="physics",
            players=players,
            has_bot=False,
            opponents={},
            coins={},
            questions=settings.tournament_questions,
            finished_at=now,
            now=now,
        )
        await record_game(ctx, settings)
        await db.commit()


async def deliver_outbox(sessions: Sessions, redis: Redis, settings: Settings) -> None:
    async with sessions() as db, httpx.AsyncClient() as http:
        await dispatch_due(
            db, redis=redis, http=http, settings=settings, now=datetime.now().astimezone()
        )


def by_user(rows: list[Any]) -> dict[uuid.UUID, Any]:
    return {row.user_id: row for row in rows}
