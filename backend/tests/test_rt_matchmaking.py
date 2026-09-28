"""Matchmaking over real sockets: pairing rules, widening, offers, cancels and guards.

Waiting is simulated by moving a ticket's ``joined_ms`` (or its disconnect/background time)
back: the leader compares them with Redis time on every tick.
"""

import asyncio
import uuid

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.modules.matches.ports import InsufficientCoins, Integrations, NoopEscrow
from app.modules.realtime import keys
from app.modules.realtime.matchmaking import tickets
from tests.rt_helpers import (
    RtServer,
    backdate,
    connect_bot,
    fast_settings,
    no_frame,
    search,
    sign_in,
    ticket_key,
)


async def two_players(rt: RtServer, api: AsyncClient, **installs: str) -> tuple:  # type: ignore[type-arg]
    asha_login = await sign_in(api, "asha@example.com", install_id=installs.get("asha"))
    ravi_login = await sign_in(api, "ravi@example.com", install_id=installs.get("ravi"))
    asha = await connect_bot(rt.url, api, asha_login, name="asha")
    ravi = await connect_bot(rt.url, api, ravi_login, name="ravi")
    return asha, ravi


async def test_all_chapters_is_a_wildcard(rt: RtServer, api: AsyncClient) -> None:
    asha, ravi = await two_players(rt, api)

    await search(asha, chapter="kinematics")
    await search(ravi, chapter=None)
    found = await asha.expect("mm.found")
    other = await ravi.expect("mm.found")

    assert found["d"]["match_id"] == other["d"]["match_id"]
    assert found["d"]["sources"] == [
        {"chapter": "kinematics", "name": "Motion in a Straight Line", "count": 2}
    ]
    assert found["d"]["opponent"]["uid"] == ravi.user_id
    assert other["d"]["opponent"]["uid"] == asha.user_id


async def test_a_search_widens_to_the_whole_subject_at_15_s(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, _ = await two_players(rt, api)
    await search(asha, chapter="kinematics")
    await asha.expect("mm.status")

    await backdate(redis, asha.user_id, 16)
    widened = await asha.expect("mm.status")

    assert widened["d"]["widened"] is True
    assert widened["d"]["waited_s"] >= 15
    assert widened["d"]["window"] == 350  # never narrower than a new player's RD


@pytest.mark.parametrize("rt_settings", [fast_settings(match_questions=7)])
async def test_different_chapters_match_after_15_s_with_a_4_3_split(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, ravi = await two_players(rt, api)
    queued = await search(asha, chapter="kinematics")
    await search(ravi, chapter="laws-of-motion")
    await no_frame(asha, "mm.found")

    for bot in (asha, ravi):
        await backdate(redis, bot.user_id, 16)
    found = await asha.expect("mm.found")

    assert queued["d"]["chapter"] == "kinematics"
    # 4 from the chapter of whoever searched first, 3 from the other.
    assert found["d"]["sources"] == [
        {"chapter": "kinematics", "name": "Motion in a Straight Line", "count": 4},
        {"chapter": "laws-of-motion", "name": "Laws of Motion", "count": 3},
    ]


async def test_the_status_says_who_is_searching_and_the_typical_wait(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    await redis.lpush(keys.waits("physics", 0), 10, 20, 30)
    for hour in range(24):
        await redis.lpush(keys.waits("physics", hour), 10, 20, 30)
    asha, _ = await two_players(rt, api)

    await search(asha, chapter="kinematics")
    status = await asha.expect("mm.status")

    assert status["d"] == {
        "waited_s": 0,
        "widened": False,
        "window": 350,
        "online": 1,
        "p50_wait_s": 20,
    }


async def test_the_bot_is_offered_at_45_s_and_keep_searching_ends_at_the_deadline(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, _ = await two_players(rt, api)
    await redis.set(f"mm:searched:{asha.user_id}", 1)  # not a first-ever search
    await search(asha)

    await backdate(redis, asha.user_id, 21)
    await no_frame(asha, "mm.timeout", 0.3)
    await backdate(redis, asha.user_id, 25)
    offer = await asha.expect("mm.timeout")
    keep = await asha.request("mm.respond", {"choice": "keep"})
    key = await ticket_key(redis, asha.user_id)
    deadline = int(await redis.hget(key, "deadline_ms") or 0)
    now_ms = (await redis.time())[0] * 1000
    await redis.hset(key, "deadline_ms", now_ms - 1000)  # the extra 60 s have passed
    cancelled = await asha.expect("mm.cancelled")

    assert offer["d"] == {
        "waited_s": offer["d"]["waited_s"],
        "options": ["keep", "bot", "invite", "cancel"],
    }
    assert offer["d"]["waited_s"] >= 45
    assert keep["t"] == "ack"
    assert deadline >= now_ms + 59_000
    assert cancelled["d"] == {"reason": "timeout", "refunded": 0}
    assert await redis.get(keys.busy(asha.user_id)) is None
    assert not asha.seen("mm.found")  # a rated search never gets a bot by itself


async def test_a_first_ever_search_offers_the_bot_at_20_s(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, _ = await two_players(rt, api)
    await search(asha)

    await backdate(redis, asha.user_id, 21)
    offer = await asha.expect("mm.timeout")

    assert 20 <= offer["d"]["waited_s"] < 45


async def test_choosing_the_bot_ends_the_search_and_starts_an_unrated_game(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, _ = await two_players(rt, api)
    await search(asha, mode="rated", chapter="kinematics")
    await backdate(redis, asha.user_id, 46)
    await asha.expect("mm.timeout")

    reply = await asha.request("mm.respond", {"choice": "bot"})
    cancelled = await asha.expect("mm.cancelled")
    found = await asha.expect("mm.found")

    assert reply["t"] == "ack"
    assert cancelled["d"]["reason"] == "user"
    assert found["d"]["bot"] is True
    assert found["d"]["mode"] == "bot"


async def test_a_cancel_that_loses_the_race_gets_already_matched(
    rt: RtServer, api: AsyncClient
) -> None:
    asha, ravi = await two_players(rt, api)
    await search(asha)
    await search(ravi)
    found = await asha.expect("mm.found")

    reply = await asha.request("mm.cancel", {})

    assert reply["t"] == "error"
    assert reply["d"]["code"] == "ALREADY_MATCHED"
    assert reply["d"]["details"] == {"match_id": found["d"]["match_id"]}


async def test_cancel_releases_the_casual_hold(
    rt: RtServer, api: AsyncClient, plugins: Integrations
) -> None:
    asha, _ = await two_players(rt, api)
    await search(asha, mode="casual")

    reply = await asha.request("mm.cancel", {})
    cancelled = await asha.expect("mm.cancelled")

    escrow = plugins.escrow
    assert isinstance(escrow, NoopEscrow)
    assert reply["t"] == "ack"
    assert cancelled["d"] == {"reason": "user", "refunded": 5}
    assert [state for _, _, state in escrow.holds.values()] == ["released"]


class BrokeEscrow(NoopEscrow):
    async def hold(self, db: AsyncSession, *, user_id: uuid.UUID, amount: int, key: str) -> str:
        raise InsufficientCoins(balance=3)


@pytest.fixture
def broke(plugins: Integrations) -> Integrations:
    plugins.escrow = BrokeEscrow()
    return plugins


async def test_casual_needs_the_entry_fee(
    rt: RtServer, api: AsyncClient, broke: Integrations
) -> None:
    asha, _ = await two_players(rt, api)

    ref = await asha.send(
        "mm.join", {"mode": "casual", "subject": "physics", "chapter": None, "idem": "x1"}
    )
    reply = await asha.expect_reply(ref)

    assert reply["d"]["code"] == "INSUFFICIENT_COINS"
    assert reply["d"]["details"] == {"balance": 3, "needed": 5}


async def test_a_repeated_join_returns_the_same_ticket_and_another_is_busy(
    rt: RtServer, api: AsyncClient
) -> None:
    asha, _ = await two_players(rt, api)
    join = {"mode": "rated", "subject": "physics", "chapter": "kinematics", "idem": "same"}

    await asha.send("mm.join", join)
    first = await asha.expect("mm.queued")
    await asha.send("mm.join", join)
    again = await asha.expect("mm.queued")
    other = await asha.request("mm.join", {**join, "idem": "other"})

    assert again["d"]["ticket_id"] == first["d"]["ticket_id"]
    assert other["d"]["code"] == "BUSY"
    assert other["d"]["details"]["active"]["kind"] == "queue"
    assert other["d"]["details"]["active"]["id"] == first["d"]["ticket_id"]


async def test_three_aborts_in_an_hour_start_a_cooldown(
    rt: RtServer, api: AsyncClient, redis: Redis, rt_settings: Settings
) -> None:
    asha, _ = await two_players(rt, api)
    for n in range(3):
        until = await tickets.record_abort(redis, rt_settings, asha.user_id, f"m{n}")

    reply = await asha.request(
        "mm.join", {"mode": "rated", "subject": "physics", "chapter": None, "idem": "c1"}
    )

    assert until is not None
    assert reply["d"]["code"] == "COOLDOWN"
    assert reply["d"]["details"] == {"until": until}


async def test_the_background_for_more_than_10_s_stops_the_search(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, _ = await two_players(rt, api)
    await search(asha)

    await asha.send("client.state", {"state": "background"})
    await asyncio.sleep(0.1)
    await backdate(redis, asha.user_id, 11, "bg_ms")
    cancelled = await asha.expect("mm.cancelled")

    assert cancelled["d"] == {"reason": "background", "refunded": 0}
    assert await redis.zcard(keys.aborts(asha.user_id)) == 0  # never counts as an abort


async def test_a_ticket_survives_a_short_drop_and_is_cancelled_after_10_s(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    login = await sign_in(api, "asha@example.com")
    asha = await connect_bot(rt.url, api, login)
    await search(asha)
    ticket = await ticket_key(redis, asha.user_id)

    await asha.close()
    await asyncio.sleep(0.2)
    dropped_at = int(await redis.hget(ticket, "disc_ms") or 0)
    back = await connect_bot(rt.url, api, login)
    active = back.seen("welcome")[0]["d"]["active"]
    await asyncio.sleep(0.1)
    returned = int(await redis.hget(ticket, "disc_ms") or 0)
    await back.close()
    await asyncio.sleep(0.2)
    await backdate(redis, asha.user_id, 11, "disc_ms")
    for _ in range(40):
        if await redis.get(keys.busy(asha.user_id)) is None:
            break
        await asyncio.sleep(0.05)

    assert dropped_at > 0
    assert active[0]["kind"] == "queue"
    assert returned == 0
    assert await redis.get(keys.busy(asha.user_id)) is None
    assert not await redis.exists(ticket)


async def test_two_accounts_on_one_phone_are_never_paired(rt: RtServer, api: AsyncClient) -> None:
    asha, ravi = await two_players(rt, api, asha="shared-phone", ravi="shared-phone")

    await search(asha)
    await search(ravi)

    await no_frame(asha, "mm.found")


@pytest.fixture
def blocking(plugins: Integrations) -> Integrations:
    async def always(_db: AsyncSession, _a: uuid.UUID, _b: uuid.UUID) -> bool:
        return True

    plugins.are_blocked = always
    return plugins


async def test_blocked_players_are_never_paired(
    rt: RtServer, api: AsyncClient, blocking: Integrations
) -> None:
    asha, ravi = await two_players(rt, api)

    await search(asha)
    await search(ravi)

    await no_frame(asha, "mm.found")


async def test_a_pair_plays_at_most_3_rated_games_a_day(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, ravi = await two_players(rt, api)
    lo, hi = sorted((asha.user_id, ravi.user_id))
    now_ms = (await redis.time())[0] * 1000
    await redis.zadd(keys.pair_games(lo, hi), {f"m{n}": now_ms - n for n in range(3)})

    await search(asha, mode="rated")
    await search(ravi, mode="rated")
    await no_frame(asha, "mm.found")
    for bot in (asha, ravi):
        await bot.request("mm.cancel", {})
    await search(asha, mode="casual")
    await search(ravi, mode="casual")
    found = await asha.expect("mm.found")

    assert found["d"]["mode"] == "casual"
