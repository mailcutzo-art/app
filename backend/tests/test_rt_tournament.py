"""A tournament round over the socket: ``t.pairing`` → ``match.ready`` → the game → the pairing
result; standings on ``t:<id>``; tournament no-shows in the engine; and BUSY for mm.join."""

import uuid
from datetime import timedelta

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select

from app.core.clock import utc_now
from app.core.config import Settings
from app.modules.matches.ports import Integrations
from app.modules.realtime.engine import scripts
from app.modules.tournaments.models import (
    TournamentEntry,
    TournamentPairing,
    TournamentStatus,
)
from tests.rt_helpers import (
    LockedSessions,
    RtServer,
    connect_bot,
    correct_option,
    fast_settings,
    sign_in,
    until_shown,
)
from tests.test_match_settlement import advance_until
from tests.tournament_helpers import (
    deliver_outbox,
    deps,
    funded_user,
    make_tournament,
    tick,
    tournament_plugins,
)


@pytest.fixture
def rt_settings() -> Settings:
    return fast_settings(tournament_questions=2, tournament_ready_ms=3000, tournament_grace_ms=1200)


@pytest.fixture
def plugins(rt_settings: Settings) -> Integrations:
    return tournament_plugins(rt_settings)


async def _running_tournament(
    sessions: LockedSessions, redis: Redis, settings: Settings, players: list[uuid.UUID]
) -> uuid.UUID:
    """A locked tournament whose checked-in field is ``players`` (in seed order), started."""
    now = utc_now()
    async with sessions() as db:
        t = await make_tournament(
            db, now=now - timedelta(hours=2), starts_in=timedelta(hours=2), fee=0, pool=0
        )
        t.status = TournamentStatus.LOCKED.value
        t.players = len(players)
        for index, user in enumerate(players):
            db.add(
                TournamentEntry(
                    tournament_id=t.id,
                    user_id=user,
                    checked_in=True,
                    registered_at=now - timedelta(minutes=60 - index),
                )
            )
        await db.commit()
    await tick(deps(redis, sessions, settings), now)
    return t.id


async def test_a_round_over_the_socket(
    rt: RtServer,
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
) -> None:
    asha_login = await sign_in(api, "asha@example.com")
    ravi_login = await sign_in(api, "ravi@example.com")
    asha = await connect_bot(rt.url, api, asha_login, name="asha")
    ravi = await connect_bot(rt.url, api, ravi_login, name="ravi")
    async with sessions() as db:
        others = [await funded_user(db, "x1"), await funded_user(db, "x2")]
        await db.commit()
    # Seeds 1 and 3 meet in round 1 (1 v 3, 2 v 4).
    field = [uuid.UUID(asha.user_id), others[0], uuid.UUID(ravi.user_id), others[1]]
    tid = await _running_tournament(sessions, redis, rt_settings, field)

    assert (await asha.request("sub", {"ch": f"t:{tid}"}))["t"] == "ack"
    standings = asha.seen("t.standings")[-1]
    assert len(standings["d"]["rows"]) == 4
    assert standings["ch"] == f"t:{tid}"
    assert standings["d"]["me"]["uid"] == asha.user_id

    await deliver_outbox(sessions, redis, rt_settings)
    pairing = await asha.expect("t.pairing")
    await ravi.expect("t.pairing")
    mid = pairing["d"]["match_id"]
    assert pairing["d"]["opponent"]["uid"] == ravi.user_id
    assert pairing["d"]["ready_by"] > 0
    for bot in (asha, ravi):
        await bot.expect("match.snapshot", lambda f: f["ch"] == f"m:{mid}")
        assert (await bot.request("match.ready", {"match_id": mid}))["t"] == "ack"
    for q in (1, 2):
        show = await asha.expect("q.show", lambda f, q=q: f["d"]["q"] == q)
        await until_shown(show)
        right = await correct_option(redis, mid, q)
        await asha.request("ans.submit", {"match_id": mid, "q": q, "opt": right, "el_ms": 900})
    end = await asha.expect("match.end", wait_s=10)
    assert end["d"]["result"] == "win"
    await asha.expect("match.settled", wait_s=10)
    async with sessions() as db:
        board = await db.scalar(
            select(TournamentPairing).where(TournamentPairing.match_id == uuid.UUID(mid))
        )
        assert board is not None
        assert board.status == "done"
        winner = asha.user_id
        mine = board.result_a if str(board.a_id) == winner else board.result_b
        assert mine == "win"
        entry = await db.get_one(TournamentEntry, (tid, uuid.UUID(winner)), populate_existing=True)
        assert entry.points == 1
    await asha.request("unsub", {"ch": f"t:{tid}"})


async def test_tournament_no_shows_in_the_engine(
    api: AsyncClient, redis: Redis, sessions: LockedSessions, rt_settings: Settings
) -> None:
    async with sessions() as db:
        players = [await funded_user(db, f"n{i}") for i in range(4)]
        await db.commit()
    tid = await _running_tournament(sessions, redis, rt_settings, players)
    async with sessions() as db:
        boards = list(
            await db.scalars(
                select(TournamentPairing)
                .where(TournamentPairing.tournament_id == tid)
                .order_by(TournamentPairing.board)
            )
        )
    one, two = (str(b.match_id) for b in boards)
    # Board 1: only one player gets ready, so the other is a no-show (a forfeit win).
    await scripts.ready(redis, one, str(boards[0].a_id))
    step = await advance_until(redis, one, "finished", "aborted")
    assert step.status == "finished"
    # Board 2: nobody shows: a double no-show.
    step = await advance_until(redis, two, "finished", "aborted")
    assert step.status == "aborted"
    final = await redis.get(f"m:{{{two}}}:final")
    assert final is not None
    assert '"reason":"no_show"' in final


async def test_checked_in_players_are_busy_for_quick_battles(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions, rt_settings: Settings
) -> None:
    login = await sign_in(api, "kiran@example.com")
    bot = await connect_bot(rt.url, api, login, name="kiran")
    async with sessions() as db:
        t = await make_tournament(
            db, now=utc_now(), reg_opens_in=timedelta(hours=-1), starts_in=timedelta(minutes=3)
        )
        t.status = TournamentStatus.LOCKED.value
        db.add(TournamentEntry(tournament_id=t.id, user_id=uuid.UUID(bot.user_id), checked_in=True))
        await db.commit()
    reply = await bot.request(
        "mm.join", {"mode": "rated", "subject": "physics", "chapter": None, "idem": "i1"}
    )
    assert reply["t"] == "error"
    assert reply["d"]["code"] == "BUSY"
    assert reply["d"]["details"]["active"]["kind"] == "tournament"
    assert reply["d"]["details"]["active"]["id"] == str(t.id)
