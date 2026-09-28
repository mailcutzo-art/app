"""The gateway over real sockets: handshake checks, limits, heartbeats, devices, revocation,
resume, restarts and failover between nodes."""

import asyncio
import time
import uuid

import orjson
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import update
from websockets.asyncio.client import connect

from app.core.config import Settings
from app.modules.matches.ports import Integrations
from app.modules.realtime import keys
from app.modules.realtime.control import disconnect_banned
from app.modules.users.authz import invalidate_authz
from app.modules.users.models import User
from tests.helpers import bearer
from tests.rt_helpers import (
    Bot,
    LockedSessions,
    RtServer,
    connect_bot,
    fast_settings,
    run_rt,
    search,
    sign_in,
    ticket,
    until_shown,
)


async def hello_close(rt: RtServer, api: AsyncClient, login: dict, **fields: object) -> tuple:  # type: ignore[type-arg]
    """Say hello with ``fields`` over a fresh ticket and return how the server closed."""
    bot = await connect_bot(rt.url, api, login, welcome=False) if not fields else None
    if bot is None:
        ws = await connect(rt.url, proxy=None)
        bot = Bot(ws, login["user"]["id"], "probe")
        data = {
            "ticket": await ticket(api, login["access_token"]),
            "proto": 1,
            "build": 7,
            "resume": [],
            **fields,
        }
        await bot.send("hello", data)
    return await bot.wait_closed()


async def bot_game(bot: Bot) -> str:
    await bot.send(
        "mm.join", {"mode": "bot", "subject": "physics", "chapter": None, "idem": uuid.uuid4().hex}
    )
    found = await bot.expect("mm.found")
    mid: str = found["d"]["match_id"]
    await bot.expect("match.snapshot")
    return mid


async def test_welcome_describes_the_connection(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")
    before = int(time.time() * 1000)

    bot = await connect_bot(rt.url, api, login)
    welcome = bot.seen("welcome")[0]

    assert welcome["ch"] == "u"
    assert welcome["d"]["user_id"] == login["user"]["id"]
    assert welcome["d"]["hb_s"] == 1
    assert welcome["d"]["active"] == []
    assert abs(welcome["d"]["server_ms"] - before) < 5000
    assert len(welcome["d"]["conn_id"]) >= 8
    await bot.close()


async def test_a_ticket_works_once(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")
    value = await ticket(api, login["access_token"])
    first = Bot(await connect(rt.url, proxy=None), login["user"]["id"], "first")
    await first.send("hello", {"ticket": value, "proto": 1, "build": 7})
    await first.expect("welcome")

    second = Bot(await connect(rt.url, proxy=None), login["user"]["id"], "second")
    await second.send("hello", {"ticket": value, "proto": 1, "build": 7})

    assert await second.wait_closed() == (4401, "bad ticket")
    await first.close()


async def test_tickets_are_short_lived_single_use_and_rate_limited(
    api: AsyncClient, redis: Redis
) -> None:
    login = await sign_in(api, "asha@example.com")

    response = await api.post("/v1/rt/tickets", headers=bearer(login["access_token"]))
    stored = await redis.get(keys.rt_ticket(response.json()["ticket"]))
    ttl = await redis.ttl(keys.rt_ticket(response.json()["ticket"]))
    statuses = [
        (await api.post("/v1/rt/tickets", headers=bearer(login["access_token"]))).status_code
        for _ in range(20)
    ]

    assert response.json()["expires_in"] == 30
    assert len(response.json()["ticket"]) == 43  # 32 bytes, base64url
    assert stored is not None
    assert orjson.loads(stored)["uid"] == login["user"]["id"]
    assert 0 < ttl <= 30
    assert statuses[-1] == 429


async def test_a_signed_out_session_is_refused(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")
    value = await ticket(api, login["access_token"])
    await api.post("/v1/auth/logout", headers=bearer(login["access_token"]))

    bot = Bot(await connect(rt.url, proxy=None), login["user"]["id"], "late")
    await bot.send("hello", {"ticket": value, "proto": 1, "build": 7})

    assert await bot.wait_closed() == (4403, "session revoked")


async def test_logging_out_closes_the_socket(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")
    bot = await connect_bot(rt.url, api, login)

    await api.post("/v1/auth/logout", headers=bearer(login["access_token"]))

    assert (await bot.wait_closed())[0] == 4403


async def test_a_ban_closes_every_socket_and_refuses_new_ones(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    login = await sign_in(api, "asha@example.com")
    bot = await connect_bot(rt.url, api, login)
    value = await ticket(api, login["access_token"])
    user_id = uuid.UUID(login["user"]["id"])
    async with sessions() as db:
        await db.execute(update(User).where(User.id == user_id).values(status="banned"))
        await db.commit()
    await invalidate_authz(redis, user_id)

    await disconnect_banned(redis, user_id)
    again = Bot(await connect(rt.url, proxy=None), login["user"]["id"], "again")
    await again.send("hello", {"ticket": value, "proto": 1, "build": 7})

    assert await bot.wait_closed() == (4403, "account banned")
    assert await again.wait_closed() == (4403, "account unavailable")


async def test_other_protocol_versions_must_update(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")

    assert await hello_close(rt, api, login, proto=2) == (4426, "update required")


@pytest.mark.parametrize("rt_settings", [fast_settings(min_build=10)])
async def test_old_builds_must_update_unless_a_game_is_running(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    login = await sign_in(api, "asha@example.com")

    closed = await hello_close(rt, api, login, build=7)
    await redis.set(keys.busy(login["user"]["id"]), "m:" + str(uuid.uuid4()))
    playing = await connect_bot(rt.url, api, login, build=7)

    assert closed == (4426, "update required")
    assert playing.seen("welcome")
    await playing.close()


async def test_clock_sync(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))

    await bot.send("clock.ping", {"c0": 12345})
    pong = await bot.expect("clock.pong")

    assert pong["d"]["c0"] == 12345
    assert abs(pong["d"]["s"] - time.time() * 1000) < 5000
    await bot.close()


@pytest.mark.parametrize("rt_settings", [fast_settings(rt_hb_idle_s=2, rt_hb_queue_s=1)])
async def test_the_server_pings_and_announces_the_interval(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))

    ping = await bot.expect("ping", wait_s=3)
    await search(bot)
    hb = await bot.expect("hb")
    await bot.request("mm.cancel", {})
    idle = await bot.expect("hb")

    assert bot.seen("welcome")[0]["d"]["hb_s"] == 2  # idle
    assert ping["d"]["n"] >= 1
    assert hb["d"] == {"s": 1}  # queued
    assert idle["d"] == {"s": 2}
    await bot.close()


@pytest.mark.parametrize("rt_settings", [fast_settings(rt_stale_idle_s=1.0)])
async def test_a_silent_socket_is_closed(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))
    bot.answer_pings = False

    assert await bot.wait_closed(wait_s=5) == (1000, "stale")


async def test_too_many_frames_close_with_4429(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))

    for n in range(45):
        await bot.send("clock.ping", {"c0": n})
    limited = await bot.expect("error")

    assert limited["d"]["code"] == "RATE_LIMITED"
    assert await bot.wait_closed() == (4429, "rate limited")


async def test_an_oversized_frame_closes_with_4400(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))

    await bot.send("clock.ping", {"c0": 1, "pad": "x" * 5000})

    assert await bot.wait_closed() == (4400, "bad message")


async def test_unknown_types_are_ignored(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))

    await bot.send("something.new", {"x": 1})
    await bot.send("clock.ping", {"c0": 7})

    assert (await bot.expect("clock.pong"))["d"]["c0"] == 7
    await bot.close()


async def test_a_newer_socket_replaces_the_older_one(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")
    first = await connect_bot(rt.url, api, login)

    second = await connect_bot(rt.url, api, login)

    assert await first.wait_closed() == (4409, "playing on another device")
    assert second.closed is None
    await second.close()


async def test_a_live_match_moves_to_another_device_only_on_takeover(
    rt: RtServer, api: AsyncClient
) -> None:
    phone = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"), name="phone")
    mid = await bot_game(phone)
    tablet_login = await sign_in(api, "asha@example.com", install_id="tablet")

    refused = await connect_bot(rt.url, api, tablet_login, name="tablet", welcome=False)
    error = await refused.expect("error")
    refused_close = await refused.wait_closed()
    moved = await connect_bot(rt.url, api, tablet_login, name="tablet", takeover=True)
    snapshot = await moved.expect("match.snapshot")

    assert error["d"]["code"] == "LIVE_ELSEWHERE"
    assert error["d"]["details"] == {"match_id": mid}
    assert refused_close == (4409, "live elsewhere")
    assert await phone.wait_closed() == (4409, "playing on another device")
    assert moved.seen("welcome")[0]["d"]["active"][0]["id"] == mid
    assert snapshot["d"]["match_id"] == mid
    await moved.close()


async def test_sync_sends_a_snapshot_or_not_found(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))
    mid = await bot_game(bot)

    await bot.send("sync", {"ch": f"m:{mid}", "last_seq": 0})
    snapshot = await bot.expect("match.snapshot")
    unknown = await bot.request("sync", {"ch": f"m:{uuid.uuid4()}", "last_seq": 0})

    assert snapshot["d"]["phase"] == "ready_wait"
    assert snapshot["seq"] == 0
    assert snapshot["d"]["players"][0]["uid"] == bot.user_id
    assert unknown["d"]["code"] == "NOT_FOUND"
    await bot.close()


async def test_answers_for_other_matches_or_questions_are_refused(
    rt: RtServer, api: AsyncClient
) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))
    mid = await bot_game(bot)
    await bot.request("match.ready", {"match_id": mid})
    show = await bot.expect("q.show")
    await until_shown(show)

    stranger = await bot.request(
        "ans.submit", {"match_id": str(uuid.uuid4()), "q": 1, "opt": "abcde", "el_ms": 1}
    )
    bogus = await bot.request("ans.submit", {"match_id": mid, "q": 1, "opt": "zzzzz", "el_ms": 1})
    future = await bot.request(
        "ans.submit", {"match_id": mid, "q": 2, "opt": show["d"]["options"][0]["id"], "el_ms": 1}
    )
    malformed = await bot.request("ans.submit", {"match_id": mid, "q": "1"})

    assert stranger["d"]["status"] == "invalid"
    assert bogus["d"]["status"] == "invalid"
    assert future["d"]["status"] == "wrong_phase"
    assert malformed["d"]["code"] == "BAD_REQUEST"
    await bot.close()


async def test_a_server_restart_closes_with_1012_and_extends_the_grace(
    rt: RtServer, api: AsyncClient, redis: Redis, rt_settings: Settings
) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))
    mid = await bot_game(bot)

    rt.server.should_exit = True
    closed = await bot.wait_closed()
    now_ms = int(time.time() * 1000)
    for _ in range(50):  # the server records the drop as it shuts down
        state = orjson.loads(await redis.hget(keys.match_players(mid), bot.user_id) or "{}")
        if not state["connected"] and not await redis.exists(keys.match_lease(mid)):
            break
        await asyncio.sleep(0.1)

    assert closed[0] == 1012
    assert state["connected"] is False
    assert state["grace_until"] >= now_ms + rt_settings.match_drain_grace_ms - 1000
    assert await redis.get(keys.match_lease(mid)) is None  # handed back for adoption


async def test_another_node_adopts_a_match_whose_owner_died(
    rt: RtServer,
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"))
    mid = await bot_game(bot)
    await bot.request("match.ready", {"match_id": mid})
    show = await bot.expect("q.show")
    owner = rt.node

    async with run_rt(rt_settings, sessions, plugins) as other:
        await owner.engine.stop(release=False)  # the owner's timers die; its lease lapses
        started = time.monotonic()
        reveal = await bot.expect("q.reveal", wait_s=6)
        adopted_after = time.monotonic() - started
        end = await bot.expect("match.end", wait_s=8)
        assert other.node.node_id != owner.node_id

    assert show["d"]["q"] == 1
    assert reveal["d"]["q"] == 1
    assert adopted_after < 5
    assert end["d"]["reason"] == "normal"
    await bot.close()
