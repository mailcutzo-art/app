"""The tournament lifecycle driven by the worker with a moving clock: every state, a 64-player
Swiss simulation, cancellations, and re-running steps after a crash."""

import uuid
from datetime import timedelta

import pytest
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import IST, utc_now
from app.core.config import Settings
from app.modules.economy.models import CoinReason, LedgerEntry
from app.modules.matches.models import Match
from app.modules.notifications.models import Notification
from app.modules.outbox.models import OutboxMessage
from app.modules.realtime import keys
from app.modules.tournaments import lifecycle, service
from app.modules.tournaments.models import (
    Tournament,
    TournamentEntry,
    TournamentPairing,
    TournamentPrize,
    TournamentStatus,
    TournamentTemplate,
)
from app.modules.tournaments.prizes import effective_pool
from tests.helpers import make_settings
from tests.rt_helpers import LockedSessions
from tests.tournament_helpers import (
    balance,
    deps,
    funded_user,
    make_tournament,
    pending,
    settle_game,
    status,
    tick,
)

S = TournamentStatus


@pytest.fixture
def t_settings() -> Settings:
    return make_settings(tournament_questions=2)


async def _register(
    sessions: LockedSessions, settings: Settings, t: Tournament, users: list[uuid.UUID], at
) -> None:
    async with sessions() as db:
        for user_id in users:
            await service.register(db, settings, t.id, user_id, now=at)
        await db.commit()


async def _check_in(
    sessions: LockedSessions, settings: Settings, t: Tournament, users: list[uuid.UUID], at
) -> None:
    async with sessions() as db:
        for user_id in users:
            await service.check_in(db, settings, t.id, user_id, now=at)
        await db.commit()


async def _kinds(db: AsyncSession, user_id: uuid.UUID) -> list[str]:
    return list(
        await db.scalars(
            select(Notification.kind)
            .where(Notification.user_id == user_id)
            .order_by(Notification.created_at, Notification.id)
        )
    )


async def test_every_state_with_a_moving_clock(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, t_settings: Settings
) -> None:
    sessions = LockedSessions(session_factory)
    worker = deps(redis, sessions, t_settings)
    now = utc_now()
    async with sessions() as db:
        t = await make_tournament(db, now=now, min_players=4)
        users = [await funded_user(db, f"p{i}") for i in range(6)]
        await db.commit()
    starts = t.starts_at

    assert await tick(worker, now) == 0  # nothing due before registration opens
    await tick(worker, t.reg_opens_at)
    assert (await status(sessions, t.id)).status == S.REG_OPEN
    await _register(sessions, t_settings, t, users, t.reg_opens_at)
    async with sessions() as db:
        assert await balance(db, users[0]) == 190  # the fee is held

    await tick(worker, starts - timedelta(minutes=30))  # at risk? 6 >= 4, so no notices
    async with sessions() as db:
        assert "tournament_at_risk" not in await _kinds(db, users[0])
    await tick(worker, starts - timedelta(minutes=15))
    assert (await status(sessions, t.id)).status == S.CHECK_IN
    await _check_in(sessions, t_settings, t, users[:5], starts - timedelta(minutes=10))
    await tick(worker, starts - timedelta(minutes=5))
    assert (await status(sessions, t.id)).status == S.LOCKED

    await tick(worker, starts)
    t = await status(sessions, t.id)
    assert t.status == S.RUNNING
    assert t.current_round == 1
    assert t.rounds_planned == 4  # min(5, 5 - 1, ceil(log2 5) + 2)
    async with sessions() as db:
        assert await balance(db, users[5]) == 200  # didn't check in: refunded
        no_show = await db.get_one(TournamentEntry, (t.id, users[5]))
        assert no_show.no_show
        assert no_show.withdrawn
        assert "tournament_check_in" in await _kinds(db, users[0])
        assert await balance(db, users[0]) == 190  # captured
    boards = await pending(sessions, t.id, 1)
    assert len(boards) == 2  # 5 players: two boards and a bye
    for board in boards:
        assert await redis.exists(keys.match(str(board.match_id)))

    moment = starts
    for number in range(1, 5):
        boards = await pending(sessions, t.id, number)
        if number == 2:
            # One board never plays: at the deadline its game ends as a double no-show.
            played, stuck = boards[:-1], boards[-1:]
        else:
            played, stuck = boards, []
        for board in played:
            assert board.b_id is not None
            await settle_game(
                sessions,
                t_settings,
                board,
                {board.a_id: "win", board.b_id: "loss"},
                now=moment,
                scores={board.a_id: 300, board.b_id: 100},
            )
        if stuck:
            moment += timedelta(seconds=t_settings.tournament_round_s)
            await tick(worker, moment)  # ends the game and settles it
            moment += timedelta(seconds=10)
            await tick(worker, moment)
            async with sessions() as db:
                board = await db.get_one(TournamentPairing, stuck[0].id, populate_existing=True)
                assert board.result_a == board.result_b == "double_forfeit"
                match = await db.get_one(Match, stuck[0].match_id)
                assert match.status == "aborted"
                assert match.end_reason == "no_show"
        moment += timedelta(seconds=t_settings.tournament_pause_s + 1)
        await tick(worker, moment)
    t = await status(sessions, t.id)
    assert t.status == S.FINISHED
    async with sessions() as db:
        entries = list(
            await db.scalars(
                select(TournamentEntry)
                .where(TournamentEntry.tournament_id == t.id, TournamentEntry.checked_in)
                .order_by(TournamentEntry.final_rank)
            )
        )
        assert [e.final_rank for e in entries] == [1, 2, 3, 4, 5]
        prizes = list(
            await db.scalars(select(TournamentPrize).where(TournamentPrize.tournament_id == t.id))
        )
        assert sum(p.amount for p in prizes) == effective_pool(1000, 5)
        winner = entries[0].user_id
        assert "tournament_result" in await _kinds(db, winner)
        topics = await db.scalars(
            select(OutboxMessage.payload).where(OutboxMessage.topic == "tournaments.user")
        )
        types = {p["type"] for p in topics}
        assert {"t.check_in", "t.pairing", "t.bye", "t.finished", "t.checked_in"} <= types
        won = await db.scalar(
            select(func.count()).where(
                OutboxMessage.key.like(
                    f"%:{winner}:tournament_wins:tournament_won:tournament:{t.id}"
                )
            )
        )
        assert won == 1
    assert t.next_action_at is None


async def test_too_few_checked_in_cancels_and_refunds(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, t_settings: Settings
) -> None:
    sessions = LockedSessions(session_factory)
    worker = deps(redis, sessions, t_settings)
    now = utc_now()
    async with sessions() as db:
        t = await make_tournament(db, now=now, min_players=8)
        users = [await funded_user(db, f"c{i}") for i in range(5)]
        await db.commit()
    await tick(worker, t.reg_opens_at)
    await _register(sessions, t_settings, t, users, t.reg_opens_at)
    await tick(worker, t.starts_at - timedelta(minutes=30))
    async with sessions() as db:
        assert "tournament_at_risk" in await _kinds(db, users[0])
        risk = await db.scalar(
            select(OutboxMessage.payload).where(
                OutboxMessage.key == f"tournaments.user:at_risk:{t.id}:{users[0]}"
            )
        )
        assert risk is not None
        assert risk["data"]["needed"] == 3
    for moment in (15, 5):
        await tick(worker, t.starts_at - timedelta(minutes=moment))
    await _check_in(sessions, t_settings, t, users, t.starts_at - timedelta(minutes=3))
    await tick(worker, t.starts_at)
    t = await status(sessions, t.id)
    assert t.status == S.CANCELLED
    assert t.cancel_reason == "not_enough_players"
    async with sessions() as db:
        assert [await balance(db, u) for u in users] == [200] * 5
        assert "tournament_cancelled" in await _kinds(db, users[0])


async def test_admin_cancel_while_running_refunds_the_captured_fees(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, t_settings: Settings
) -> None:
    sessions = LockedSessions(session_factory)
    worker = deps(redis, sessions, t_settings)
    now = utc_now()
    async with sessions() as db:
        t = await make_tournament(db, now=now)
        users = [await funded_user(db, f"a{i}") for i in range(4)]
        await db.commit()
    await tick(worker, t.reg_opens_at)
    await _register(sessions, t_settings, t, users, t.reg_opens_at)
    await tick(worker, t.starts_at - timedelta(minutes=15))
    await _check_in(sessions, t_settings, t, users, t.starts_at - timedelta(minutes=10))
    for moment in (t.starts_at - timedelta(minutes=5), t.starts_at):
        await tick(worker, moment)
    async with sessions() as db:
        assert await balance(db, users[0]) == 190
        running = await service.locked(db, t.id)
        await lifecycle.cancel(db, running, reason="admin", now=t.starts_at)
        await db.commit()
    async with sessions() as db:
        assert [await balance(db, u) for u in users] == [200] * 4
        payload = await db.scalar(
            select(OutboxMessage.payload).where(
                OutboxMessage.key == f"tournaments.user:cancelled:{t.id}:{users[0]}"
            )
        )
        assert payload["data"] == {"tournament_id": str(t.id), "reason": "admin", "refunded": 10}
    assert (await status(sessions, t.id)).status == S.CANCELLED


async def test_a_step_rerun_after_a_crash_changes_nothing_twice(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, t_settings: Settings
) -> None:
    sessions = LockedSessions(session_factory)
    worker = deps(redis, sessions, t_settings)
    now = utc_now()
    async with sessions() as db:
        t = await make_tournament(db, now=now)
        users = [await funded_user(db, f"k{i}") for i in range(6)]
        await db.commit()
    await tick(worker, t.reg_opens_at)
    await _register(sessions, t_settings, t, users, t.reg_opens_at)
    await tick(worker, t.starts_at - timedelta(minutes=15))
    await _check_in(sessions, t_settings, t, users[:5], t.starts_at - timedelta(minutes=10))
    await tick(worker, t.starts_at - timedelta(minutes=5))

    # The worker dies after doing the start step but before its commit.
    async with sessions() as db:
        locked = await service.locked(db, t.id)
        await lifecycle.step(db, worker, locked, t.starts_at)
        await db.rollback()
    assert (await status(sessions, t.id)).status == S.LOCKED
    assert await tick(worker, t.starts_at) == 1
    assert await tick(worker, t.starts_at) == 0  # nothing left to do: not re-run
    async with sessions() as db:
        refunds = await db.scalar(
            select(func.count()).where(
                LedgerEntry.user_id == users[5], LedgerEntry.reason == CoinReason.REFUND
            )
        )
        assert refunds == 1
        boards = await db.scalar(
            select(func.count()).where(TournamentPairing.tournament_id == t.id)
        )
        assert boards == 3

    # Settling the same game twice (a retry racing the owner) records it once.
    board = (await pending(sessions, t.id, 1))[0]
    assert board.b_id is not None
    for _ in range(2):
        await settle_game(
            sessions, t_settings, board, {board.a_id: "draw", board.b_id: "draw"}, now=t.starts_at
        )
    async with sessions() as db:
        entry = await db.get_one(TournamentEntry, (t.id, board.a_id), populate_existing=True)
        assert entry.points == 0.5


async def test_64_players_swiss_with_byes_no_shows_withdrawals_and_prizes(
    session_factory: async_sessionmaker[AsyncSession], redis: Redis, t_settings: Settings
) -> None:
    sessions = LockedSessions(session_factory)
    worker = deps(redis, sessions, t_settings)
    now = utc_now()
    async with sessions() as db:
        t = await make_tournament(db, now=now, rounds=6, fee=10, pool=3200, capacity=64)
        users = [await funded_user(db, f"s{i:02d}") for i in range(64)]
        await db.commit()
    await tick(worker, t.reg_opens_at)
    await _register(sessions, t_settings, t, users, t.reg_opens_at)
    async with sessions() as db:
        assert (await db.get_one(Tournament, t.id, populate_existing=True)).players == 64
        late = await funded_user(db, "late")
        with pytest.raises(service.TournamentFull):
            await service.register(db, t_settings, t.id, late, now=t.reg_opens_at)
    # One withdraws before the start (refunded), two never check in (refunded, no-shows).
    async with sessions() as db:
        out = await service.withdraw(db, t_settings, t.id, users[63], now=t.reg_opens_at)
        assert out["refunded"] == 10
        await db.commit()
    await tick(worker, t.starts_at - timedelta(minutes=15))
    await _check_in(sessions, t_settings, t, users[:61], t.starts_at - timedelta(minutes=10))
    await tick(worker, t.starts_at - timedelta(minutes=5))
    await tick(worker, t.starts_at)
    t = await status(sessions, t.id)
    assert t.rounds_planned == 6  # min(6, 60, ceil(log2 61) + 2 = 8)
    async with sessions() as db:
        assert await balance(db, users[63]) == 200
        assert await balance(db, users[62]) == 200
        assert (await db.get_one(TournamentEntry, (t.id, users[62]))).no_show

    absent = users[5]  # never shows: two missed rounds withdraw them
    quitter = users[10]  # leaves after round 2: no refund, no prize
    strength = {u: i for i, u in enumerate(users)}
    moment = t.starts_at
    for number in range(1, 7):
        boards = await pending(sessions, t.id, number)
        for board in boards:
            assert board.b_id is not None
            a, b = board.a_id, board.b_id
            if absent in (a, b):
                other = b if a == absent else a
                await settle_game(
                    sessions,
                    t_settings,
                    board,
                    {other: "win", absent: "loss"},
                    now=moment,
                    reason="no_show",
                )
                continue
            if (strength[a] + strength[b]) % 7 == 0:
                outcome = {a: "draw", b: "draw"}
            elif strength[a] < strength[b]:
                outcome = {a: "win", b: "loss"}
            else:
                outcome = {a: "loss", b: "win"}
            await settle_game(
                sessions,
                t_settings,
                board,
                outcome,
                now=moment,
                scores={a: 1000 - strength[a], b: 1000 - strength[b]},
            )
        if number == 2:
            async with sessions() as db:
                out = await service.withdraw(db, t_settings, t.id, quitter, now=moment)
                assert out["refunded"] == 0
                await db.commit()
        moment += timedelta(seconds=t_settings.tournament_pause_s + 1)
        await tick(worker, moment)
    t = await status(sessions, t.id)
    assert t.status == S.FINISHED
    async with sessions() as db:
        pairings = list(
            await db.scalars(
                select(TournamentPairing).where(TournamentPairing.tournament_id == t.id)
            )
        )
        entries = {
            e.user_id: e
            for e in await db.scalars(
                select(TournamentEntry).where(
                    TournamentEntry.tournament_id == t.id, TournamentEntry.checked_in
                )
            )
        }
        prizes = {
            p.user_id: p
            for p in await db.scalars(
                select(TournamentPrize).where(TournamentPrize.tournament_id == t.id)
            )
        }
        quitter_balance = await balance(db, quitter)
    # Swiss rules: no rematches, at most one bye each, withdrawn players unpaired afterwards.
    games = [frozenset((p.a_id, p.b_id)) for p in pairings if p.b_id is not None]
    assert len(games) == len(set(games))
    byes = [p.a_id for p in pairings if p.b_id is None]
    assert len(byes) == len(set(byes)) >= 1
    assert all(p.round <= 2 for p in pairings if quitter in (p.a_id, p.b_id))
    assert entries[absent].withdrawn
    assert entries[absent].withdraw_reason == "absent"
    assert all(p.round <= 2 for p in pairings if absent in (p.a_id, p.b_id))
    assert entries[quitter].withdrawn
    assert quitter_balance == 190
    # Standings and prizes: ranks 1..61, the pool fully paid, nothing for withdrawn players.
    assert sorted(e.final_rank for e in entries.values()) == list(range(1, 62))
    assert sum(p.amount for p in prizes.values()) == effective_pool(3200, 61)
    assert quitter not in prizes
    assert absent not in prizes
    assert [p.place for p in sorted(prizes.values(), key=lambda p: p.place)] == list(range(1, 11))
    first = min(entries.values(), key=lambda e: e.final_rank or 0)
    assert prizes[first.user_id].place == 1
    assert first.points == max(e.points for e in entries.values())


async def test_templates_create_instances_a_week_ahead_once(
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with session_factory() as db:
        db.add(
            TournamentTemplate(
                title="Daily Physics",
                goal="neet",
                subject_id=None,
                rrule="FREQ=DAILY;BYHOUR=19;BYMINUTE=0",
                entry_fee=10,
                prize_pool=500,
            )
        )
        await db.flush()
        now = utc_now()
        created = await lifecycle.expand_templates(db, now=now, days=7)
        again = await lifecycle.expand_templates(db, now=now, days=7)
        assert created in {7, 8}
        assert again == 0
        starts = list(
            await db.scalars(
                select(Tournament.starts_at).where(Tournament.title == "Daily Physics")
            )
        )
        assert all(s.astimezone(IST).hour == 19 for s in starts)
