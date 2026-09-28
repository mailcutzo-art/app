"""Rooms over real sockets: friend duels and group battles from lobby to result."""

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select

from app.core.config import Settings
from app.modules.matches.models import Match, MatchParticipant
from app.modules.realtime import keys
from app.modules.rooms.models import Room, RoomKick, RoomMember
from tests.room_helpers import (
    join,
    make_room,
    online,
    play_out,
    room_settings,
    seen_or_next,
    shorten,
)
from tests.rt_helpers import (
    Bot,
    LockedSessions,
    RtServer,
    connect_bot,
    correct_option,
    search,
    until_shown,
)


@pytest.fixture
def rt_settings() -> Settings:
    return room_settings()


async def test_a_friend_duel_from_code_to_rematch(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    aarav, host = await online(rt, api, "aarav")
    riya, friend = await online(rt, api, "riya")
    room = await make_room(api, aarav, "friend", chapter="kinematics", seconds=15)
    rid, code = room["room_id"], room["code"]
    assert len(code) == 6
    assert room["link"].endswith(f"/j/{code}")
    assert await redis.get(keys.busy(aarav.uid)) == f"r:{rid}"

    await join(host, room_id=rid)
    first = await host.expect("room.state")
    assert first["ch"] == f"r:{rid}"
    assert first["d"]["host"] == aarav.uid
    assert first["d"]["settings"]["chapters"] == ["kinematics"]
    await join(friend, code=code.lower())
    joined = await host.expect("room.state", lambda f: len(f["d"]["members"]) == 2)
    assert [m["role"] for m in joined["d"]["members"]] == ["host", "player"]

    # Both ready: the duel starts by itself.
    for bot in (host, friend):
        assert (await bot.request("room.ready", {"room_id": rid, "ready": True}))["t"] == "ack"
    started = await friend.expect("room.started", wait_s=5)
    mid = started["d"]["match_id"]
    for bot in (host, friend):
        snapshot = await bot.expect("match.snapshot", lambda f: f["ch"] == f"m:{mid}")
        assert snapshot["d"]["kind"] == "friend"
        assert snapshot["d"]["limit_ms"] == 1500  # 15 s, scaled for tests
        assert (await bot.request("match.ready", {"match_id": mid}))["t"] == "ack"
    end = await play_out(redis, mid, [host, friend], total=5)
    assert end["d"]["result"] == "win"
    assert end["d"]["reason"] == "normal"
    settled = await host.expect("match.settled", wait_s=8)
    assert settled["d"]["rating"] is None
    assert settled["d"]["coins"] is None
    assert settled["d"]["xp"]["delta"] == 10  # half of casual, unrated, no coins

    # Back in the lobby with a rematch window; both accept and a new game starts.
    between = await seen_or_next(host, "room.state", lambda f: f["d"]["status"] == "finished")
    assert between["d"]["rematch"]["until"] > 0
    assert await redis.get(keys.busy(riya.uid)) == f"r:{rid}"
    await friend.request("room.rematch", {"room_id": rid, "accept": True})
    offered = await host.expect(
        "room.state", lambda f: (f["d"]["rematch"] or {}).get("offered_by") == riya.uid
    )
    assert offered["d"]["status"] == "finished"
    await host.request("room.rematch", {"room_id": rid, "accept": True})
    again = await host.expect("room.started", lambda f: f["d"]["match_id"] != mid)
    assert again["d"]["match_id"] != mid

    async with sessions() as db:
        match = await db.get_one(Match, uuid.UUID(mid))
        assert match.kind == "friend"
        assert match.config["room_id"] == rid
        assert match.config["limit_ms"] == 1500
        assert match.config["total"] == 5
        assert {s["chapter"] for s in match.sources} == {"kinematics"}
        room_row = await db.get_one(Room, uuid.UUID(rid))
        assert room_row.games == 2
    for bot in (host, friend):
        await bot.close()


async def test_a_friend_host_leaving_closes_the_lobby(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    aarav, host = await online(rt, api, "aarav")
    riya, friend = await online(rt, api, "riya")
    room = await make_room(api, aarav)
    rid = room["room_id"]
    await join(host, room_id=rid)
    await join(friend, code=room["code"])
    # A third player: the room is full.
    _, third = await online(rt, api, "neha")
    full = await third.request("room.join", {"code": room["code"]})
    assert full["d"]["code"] == "NOT_ALLOWED"
    assert full["d"]["details"]["reason"] == "full"

    await host.request("room.leave", {"room_id": rid})
    closed = await friend.expect("room.closed")
    assert closed["d"] == {"room_id": rid, "reason": "host_left"}
    assert await redis.get(keys.busy(riya.uid)) is None
    assert await redis.get(keys.room_code(room["code"])) is None
    async with sessions() as db:
        row = await db.get_one(Room, uuid.UUID(rid))
        assert row.close_reason == "host_left"
        assert row.closed_at is not None
    for bot in (host, friend, third):
        await bot.close()


async def test_a_friend_lobby_waits_for_a_host_who_is_away(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    aarav, host = await online(rt, api, "aarav")
    _, friend = await online(rt, api, "riya")
    room = await make_room(api, aarav)
    rid = room["room_id"]
    await join(host, room_id=rid)
    await host.send("client.state", {"state": "background"})
    away = await host.expect("room.state", lambda f: f["d"]["members"][0]["away"])
    assert away["d"]["members"][0]["connected"] is True
    await join(friend, code=room["code"])
    await host.close()  # the socket goes while sharing the link
    await friend.expect("room.state", lambda f: not f["d"]["members"][0]["connected"])
    await shorten(redis, rid, host_left_ms=300)
    closed = await friend.expect("room.closed", wait_s=5)
    assert closed["d"]["reason"] == "host_left"
    await friend.close()


async def test_an_idle_lobby_closes(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    aarav, host = await online(rt, api, "aarav")
    room = await make_room(api, aarav, "group")
    rid = room["room_id"]
    await join(host, room_id=rid)
    await shorten(redis, rid, idle_ms=300)
    closed = await host.expect("room.closed", wait_s=5)
    assert closed["d"]["reason"] == "idle"
    assert await redis.get(keys.busy(aarav.uid)) is None
    async with sessions() as db:
        row = await db.get_one(Room, uuid.UUID(rid))
        assert row.close_reason == "idle"
    gone = await host.request("room.join", {"code": room["code"]})
    assert gone["d"]["code"] == "NOT_FOUND"
    await host.close()


async def test_wrong_codes_are_limited(rt: RtServer, api: AsyncClient) -> None:
    aarav, bot = await online(rt, api, "aarav")
    for _ in range(5):
        wrong = await bot.request("room.join", {"code": "ZZZZZZ"})
        assert wrong["d"]["code"] == "NOT_FOUND"
    limited = await bot.request("room.join", {"code": "ZZZZZZ"})
    assert limited["d"]["code"] == "RATE_LIMITED"
    assert limited["d"]["details"]["retry_after_s"] >= 1
    response = await api.get("/v1/rooms/code/ZZZZZZ", headers=aarav.headers)
    assert response.status_code == 429
    await bot.close()


async def test_a_group_battle_with_a_late_joiner_standings_and_a_podium(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    names = ["aarav", "riya", "neha", "kabir"]
    people = [await online(rt, api, name) for name in names]
    (host_p, host), (_, riya), (_, neha), (kabir_p, kabir) = people
    room = await make_room(api, host_p, "group", questions=5, late_join=True, leaderboard=True)
    rid = room["room_id"]
    await join(host, room_id=rid)
    for bot in (riya, neha):
        await join(bot, code=room["code"])
    await host.expect("room.state", lambda f: len(f["d"]["members"]) == 3)
    too_early = await riya.request("room.start", {"room_id": rid})
    assert too_early["d"]["code"] == "NOT_ALLOWED"  # only the host starts
    assert (await host.request("room.start", {"room_id": rid}))["t"] == "ack"
    mid = (await host.expect("room.started"))["d"]["match_id"]
    bots = [host, riya, neha]
    for bot in bots:
        await bot.expect("match.snapshot", lambda f: f["ch"] == f"m:{mid}")
        await bot.request("match.ready", {"match_id": mid})

    # Kabir comes in late, during question 1: he plays from there.
    shows = [await bot.expect("q.show") for bot in bots]
    await join(kabir, code=room["code"])
    snapshot = await kabir.expect("match.snapshot", lambda f: f["ch"] == f"m:{mid}")
    assert kabir_p.uid in [p["uid"] for p in snapshot["d"]["players"]]
    joined = await host.expect("player.joined")
    assert joined["d"]["player"]["uid"] == kabir_p.uid
    assert joined["d"]["joined_q"] == 1

    # Everyone sees the same option ids, each in their own order.
    orders = [[o["id"] for o in show["d"]["options"]] for show in shows]
    assert all(sorted(order) == sorted(orders[0]) for order in orders)
    rest = await play_out_group(redis, mid, bots, kabir, shows)
    end = rest["end"]
    assert end["d"]["reason"] == "normal"
    ranking = end["d"]["ranking"]
    assert ranking[0] == [host_p.uid]
    assert sum(len(group) for group in ranking) == 4
    reveal = rest["reveal"]
    standings = reveal["d"]["standings"]
    assert standings[0]["place"] == 1
    assert standings[0]["uid"] == host_p.uid
    assert {"uid", "points", "place", "change"} <= set(standings[0])

    xp = {}
    for who, bot in people:
        settled = await bot.expect("match.settled", wait_s=8)
        xp[who.uid] = settled["d"]["xp"]["delta"]
    assert xp[host_p.uid] == 20
    assert set(xp.values()) == {20, 10}
    async with sessions() as db:
        seats = (
            await db.scalars(
                select(MatchParticipant).where(MatchParticipant.match_id == uuid.UUID(mid))
            )
        ).all()
        assert len(seats) == 4
        assert {s.place for s in seats if s.user_id == host_p.id} == {1}
    between = await seen_or_next(host, "room.state", lambda f: f["d"]["status"] == "finished")
    assert between["d"]["rematch"]["until"] > 0  # Play again stays open
    for _, bot in people:
        await bot.close()


async def play_out_group(
    redis: Redis, mid: str, bots: list[Bot], late: Bot, first_shows: list[dict[str, Any]]
) -> dict[str, Any]:
    """The host answers right, everyone else wrong; the late joiner plays from question 2."""
    shows = first_shows
    reveal = None
    for q in range(1, 6):
        if q > 1:
            shows = [await bot.expect("q.show", lambda f, q=q: f["d"]["q"] == q) for bot in bots]
            late_show = await late.expect("q.show", lambda f, q=q: f["d"]["q"] == q)
        await until_shown(shows[0])
        right = await correct_option(redis, mid, q)
        answering = list(zip(bots, shows, strict=True))
        if q > 1:
            answering.append((late, late_show))
        for index, (bot, show) in enumerate(answering):
            wrong = next(o["id"] for o in show["d"]["options"] if o["id"] != right)
            ack = await bot.request(
                "ans.submit",
                {"match_id": mid, "q": q, "opt": right if index == 0 else wrong, "el_ms": 50},
            )
            assert ack["d"]["status"] == "accepted", ack
        reveal = await bots[0].expect("q.reveal", lambda f, q=q: f["d"]["q"] == q)
    end = await bots[0].expect("match.end", wait_s=8)
    return {"end": end, "reveal": reveal}


async def test_group_host_controls_handover_kick_and_lock(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    (host_p, host), (riya_p, riya), (neha_p, neha) = [
        await online(rt, api, name) for name in ("aarav", "riya", "neha")
    ]
    room = await make_room(api, host_p, "group")
    rid, code = room["room_id"], room["code"]
    await join(host, room_id=rid)
    await join(riya, code=code)
    await join(neha, code=code)
    await host.expect("room.state", lambda f: len(f["d"]["members"]) == 3)

    # Kick: Neha is out and can't come back.
    kick = await host.request("room.kick", {"room_id": rid, "uid": neha_p.uid})
    assert kick["t"] == "ack"
    kicked = await neha.expect("room.kicked")
    assert kicked["d"] == {"room_id": rid}
    assert "seq" not in kicked
    refused = await neha.request("room.join", {"code": code})
    assert refused["d"]["code"] == "NOT_ALLOWED"
    assert refused["d"]["details"]["reason"] == "kicked"
    preview = await api.get(f"/v1/rooms/code/{code}", headers=neha_p.headers)
    assert preview.json()["joinable"] is False
    assert preview.json()["reason"] == "kicked"

    # Lock: nobody new.
    await host.request("room.lock", {"room_id": rid, "locked": True})
    _, kabir = await online(rt, api, "kabir")
    locked = await kabir.request("room.join", {"code": code})
    assert locked["d"]["details"]["reason"] == "locked"
    not_host = await riya.request("room.lock", {"room_id": rid, "locked": False})
    assert not_host["d"]["code"] == "NOT_ALLOWED"

    # The host drops for longer than the handover time: Riya (earliest connected) takes over.
    await host.close()
    await riya.expect("room.state", lambda f: not f["d"]["members"][0]["connected"])
    await shorten(redis, rid, handover_ms=200)
    handed = await riya.expect("room.state", lambda f: f["d"]["host"] == riya_p.uid, wait_s=5)
    roles = {m["uid"]: m["role"] for m in handed["d"]["members"]}
    assert roles == {host_p.uid: "player", riya_p.uid: "host"}

    # Transfer back and forth works for the new host.
    assert (await riya.request("room.transfer", {"room_id": rid, "uid": host_p.uid}))["t"] == "ack"
    async with sessions() as db:
        kick_row = await db.get(RoomKick, (uuid.UUID(rid), neha_p.id))
        assert kick_row is not None
        assert kick_row.kicked_by == host_p.id
        member = await db.get_one(RoomMember, (uuid.UUID(rid), neha_p.id))
        assert member.left_at is not None
    for bot in (riya, neha, kabir):
        await bot.close()


async def test_a_group_host_ends_the_game_on_the_current_scores(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    (host_p, host), (_, riya) = [await online(rt, api, n) for n in ("aarav", "riya")]
    room = await make_room(api, host_p, "group", questions=10)
    rid = room["room_id"]
    await join(host, room_id=rid)
    await join(riya, code=room["code"])
    await host.request("room.start", {"room_id": rid})
    mid = (await host.expect("room.started"))["d"]["match_id"]
    for bot in (host, riya):
        await bot.expect("match.snapshot", lambda f: f["ch"] == f"m:{mid}")
        await bot.request("match.ready", {"match_id": mid})
    await host.expect("q.show")
    assert (await host.request("room.end", {"room_id": rid}))["t"] == "ack"
    end = await riya.expect("match.end")
    assert end["d"]["reason"] == "ended_by_host"
    closed = await riya.expect("room.closed")
    assert closed["d"]["reason"] == "host_ended"
    assert await redis.get(keys.busy(host_p.uid)) is None
    for bot in (host, riya):
        await bot.close()


async def test_a_group_game_ends_when_fewer_than_two_are_left(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    (host_p, host), (riya_p, riya), (_, neha) = [
        await online(rt, api, n) for n in ("aarav", "riya", "neha")
    ]
    room = await make_room(api, host_p, "group", questions=10)
    rid = room["room_id"]
    await join(host, room_id=rid)
    for bot in (riya, neha):
        await join(bot, code=room["code"])
    await host.request("room.start", {"room_id": rid})
    mid = (await host.expect("room.started"))["d"]["match_id"]
    for bot in (host, riya, neha):
        await bot.expect("match.snapshot", lambda f: f["ch"] == f"m:{mid}")
        await bot.request("match.ready", {"match_id": mid})
    await host.expect("q.show")
    # Neha leaves (shown as left, never a forfeit), Riya drops: one left for too long.
    await neha.request("match.forfeit", {"match_id": mid})
    left = await host.expect("opp.conn", lambda f: f["d"]["state"] == "left")
    assert left["d"]["grace_until"] is None
    await riya.close()
    await host.expect("opp.conn", lambda f: f["d"]["uid"] == riya_p.uid)
    end = await host.expect("match.end", wait_s=5)
    assert end["d"]["reason"] in {"disconnected", "left"}
    assert end["d"]["ranking"]  # finished on the scores so far, nobody forfeited
    for bot in (host, neha):
        await bot.close()


async def test_a_busy_player_cant_make_a_room_and_mm_invite_makes_one(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    aarav, bot = await online(rt, api, "aarav")
    await search(bot, "rated")
    response = await api.post(
        "/v1/rooms",
        json={"kind": "friend", "settings": {"subject": "physics"}},
        headers={**aarav.headers, "Idempotency-Key": uuid.uuid4().hex},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "BUSY"
    assert response.json()["error"]["details"]["active"]["kind"] == "queue"

    reply = await bot.request("mm.respond", {"choice": "invite"})
    assert reply["t"] == "ack"
    rid, code = reply["d"]["room_id"], reply["d"]["code"]
    assert reply["d"]["link"].endswith(code)
    state = await bot.expect("room.state")
    assert state["d"]["kind"] == "friend"
    assert state["d"]["settings"]["chapters"] == ["kinematics"]
    assert await redis.get(keys.busy(aarav.uid)) == f"r:{rid}"
    welcome_again = await connect_bot(rt.url, api, aarav.login, name="again")
    welcome = welcome_again.seen("welcome")[0]
    assert welcome["d"]["active"] == [
        {"kind": "room", "id": rid, "ch": f"r:{rid}", "state": "lobby"}
    ]
    await welcome_again.expect("room.state")
    await welcome_again.close()
    await bot.close()
