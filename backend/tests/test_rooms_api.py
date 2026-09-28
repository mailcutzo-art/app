"""Rooms and invites over REST: creating rooms, previews by code, invites and the join page."""

import uuid

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select

from app.core.config import Settings
from app.modules.matches.busy import register_busy_check, unregister_busy_check
from app.modules.matches.ports import NoopEscrow
from app.modules.matches.schemas import ActiveOut
from app.modules.matches.withdraw import withdraw_player
from app.modules.notifications.models import Notification
from app.modules.realtime import keys
from app.modules.rooms.models import InviteStatus, Room, RoomInvite
from tests.helpers import FakeClock
from tests.room_helpers import join, make_room, online, room_settings, seen_or_next
from tests.rt_helpers import LockedSessions, RtServer, search
from tests.social_helpers import befriend, player


@pytest.fixture
def rt_settings() -> Settings:
    return room_settings()


async def test_creating_a_room_is_idempotent_and_takes_the_busy_slot(
    client: AsyncClient, redis: Redis
) -> None:
    host = await player(client, "aarav")
    key = uuid.uuid4().hex
    body = {"kind": "group", "settings": {"subject": "physics", "chapters": ["kinematics"]}}
    first = await client.post(
        "/v1/rooms", json=body, headers={**host.headers, "Idempotency-Key": key}
    )
    assert first.status_code == 201, first.text
    again = await client.post(
        "/v1/rooms", json=body, headers={**host.headers, "Idempotency-Key": key}
    )
    assert again.json() == first.json()
    room = first.json()
    assert await redis.get(keys.busy(host.uid)) == f"r:{room['room_id']}"
    other = await client.post(
        "/v1/rooms", json=body, headers={**host.headers, "Idempotency-Key": uuid.uuid4().hex}
    )
    assert other.status_code == 409
    error = other.json()["error"]
    assert error["code"] == "BUSY"
    assert error["details"]["active"]["kind"] == "room"
    assert error["details"]["active"]["title"] == "Group Battle"

    bad = await client.post(
        "/v1/rooms",
        json={"kind": "friend", "settings": {"subject": "physics", "questions": 8}},
        headers={**(await player(client, "riya")).headers, "Idempotency-Key": "k1"},
    )
    assert bad.status_code == 422
    assert "questions" in bad.json()["error"]["details"]["fields"]


async def test_a_tournament_busy_check_refuses_a_room(client: AsyncClient) -> None:
    host = await player(client, "aarav")
    seen: list[int] = []

    async def tournament_soon(_db, _redis, user_id, until):  # type: ignore[no-untyped-def]
        seen.append(until)
        return ActiveOut(
            kind="tournament", id="t1", title="Physics Cup", action={"route": "/arena/t1"}
        )

    register_busy_check(tournament_soon)
    try:
        response = await client.post(
            "/v1/rooms",
            json={"kind": "friend", "settings": {"subject": "physics"}},
            headers={**host.headers, "Idempotency-Key": uuid.uuid4().hex},
        )
    finally:
        unregister_busy_check(tournament_soon)
    assert response.status_code == 409
    assert response.json()["error"]["details"]["active"]["title"] == "Physics Cup"
    assert len(seen) == 1


async def test_previews_say_who_can_join(client: AsyncClient) -> None:
    host = await player(client, "aarav")
    friend = await player(client, "riya")
    stranger = await player(client, "neha")
    blocked = await player(client, "kabir")
    await befriend(client, host, friend)
    await befriend(client, host, blocked)
    room = await make_room(client, host, "group", join="friends", questions=15, seconds=20)
    code = room["code"]

    mine = await client.get(f"/v1/rooms/code/{code.lower()}", headers=friend.headers)
    assert mine.status_code == 200, mine.text
    preview = mine.json()
    assert preview["joinable"] is True
    assert preview["reason"] is None
    assert preview["kind"] == "group"
    assert preview["host"]["id"] == host.uid
    assert (preview["questions"], preview["seconds"], preview["capacity"]) == (15, 20, 8)
    assert preview["members"] == 1

    outsider = (await client.get(f"/v1/rooms/code/{code}", headers=stranger.headers)).json()
    assert outsider["joinable"] is False
    assert outsider["reason"] == "friends_only"
    await client.post("/v1/blocks", json={"user_id": host.uid}, headers=blocked.headers)
    blocker = (await client.get(f"/v1/rooms/code/{code}", headers=blocked.headers)).json()
    assert blocker["reason"] == "blocked"

    missing = await client.get("/v1/rooms/code/ABCDEF", headers=friend.headers)
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "ROOM_NOT_FOUND"


async def test_the_join_page_carries_the_code(client: AsyncClient, settings: Settings) -> None:
    response = await client.get("/j/k7m2qx")
    assert response.status_code == 200
    page = response.text
    assert "K7M2QX" in page
    assert "referrer=room_code%3DK7M2QX" in page
    assert f"id={settings.android_package}" in page
    assert response.headers["content-type"].startswith("text/html")
    assert (await client.get("/j/nope!")).status_code == 404


async def test_an_invite_is_delivered_listed_and_accepted(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    (aarav, host), (riya, friend) = [await online(rt, api, n) for n in ("aarav", "riya")]
    await befriend(api, aarav, riya)
    room = await make_room(api, aarav, "group", join="friends")
    rid = room["room_id"]
    await join(host, room_id=rid)
    sent = await api.post(
        "/v1/invites", json={"to_user_id": riya.uid, "room_id": rid}, headers=aarav.headers
    )
    assert sent.status_code == 201, sent.text
    invite_id = sent.json()["invite_id"]
    received = await friend.expect("invite.received")
    assert received["ch"] == "u"
    assert received["d"]["invite_id"] == invite_id
    assert received["d"]["from"]["uid"] == aarav.uid
    assert received["d"]["kind"] == "group"
    assert received["d"]["subject"] == "physics"

    mine = (await api.get("/v1/me/invites", headers=riya.headers)).json()
    assert [i["invite_id"] for i in mine["incoming"]] == [invite_id]
    assert mine["incoming"][0]["from"]["id"] == aarav.uid
    assert mine["outgoing"] == []
    theirs = (await api.get("/v1/me/invites", headers=aarav.headers)).json()
    assert theirs["outgoing"][0]["to"]["id"] == riya.uid

    accepted = await api.post(f"/v1/invites/{invite_id}/accept", headers=riya.headers)
    assert accepted.status_code == 200, accepted.text
    assert accepted.json() == {"room_id": rid, "code": room["code"]}
    for bot in (host, friend):
        update = await bot.expect("invite.updated")
        assert update["d"] == {"invite_id": invite_id, "status": "accepted"}
    await join(friend, room_id=rid)
    await host.expect("room.state", lambda f: len(f["d"]["members"]) == 2)
    async with sessions() as db:
        kinds = (
            await db.scalars(
                select(Notification.kind).where(Notification.user_id.in_([riya.id, aarav.id]))
            )
        ).all()
        assert kinds.count("invite") == 2  # the invite,
        assert "Riya joined your room"
    for bot in (host, friend):
        await bot.close()


async def test_invites_expire_and_can_be_declined_or_cancelled(
    rt: RtServer, api: AsyncClient, clock: FakeClock
) -> None:
    (aarav, host), (riya, friend) = [await online(rt, api, n) for n in ("aarav", "riya")]
    await befriend(api, aarav, riya)
    rid = (await make_room(api, aarav))["room_id"]

    async def invite() -> str:
        sent = await api.post(
            "/v1/invites", json={"to_user_id": riya.uid, "room_id": rid}, headers=aarav.headers
        )
        assert sent.status_code == 201, sent.text
        value: str = sent.json()["invite_id"]
        return value

    first = await invite()
    assert (await api.post(f"/v1/invites/{first}/decline", headers=riya.headers)).status_code == 204
    declined = await host.expect("invite.updated")
    assert declined["d"]["status"] == "declined"

    second = await invite()
    assert (await api.delete(f"/v1/invites/{second}", headers=aarav.headers)).status_code == 204
    cancelled = await friend.expect("invite.updated", lambda f: f["d"]["invite_id"] == second)
    assert cancelled["d"]["status"] == "cancelled"

    third = await invite()
    clock.advance(minutes=3)
    late = await api.post(f"/v1/invites/{third}/accept", headers=riya.headers)
    assert late.status_code == 410
    assert late.json()["error"]["code"] == "INVITE_EXPIRED"
    expired = await host.expect("invite.updated", lambda f: f["d"]["invite_id"] == third)
    assert expired["d"]["status"] == "expired"
    assert (await api.get("/v1/me/invites", headers=riya.headers)).json()["incoming"] == []
    for bot in (host, friend):
        await bot.close()


async def test_invites_respect_friendship_privacy_blocks_and_busy_friends(
    rt: RtServer, api: AsyncClient, sessions: LockedSessions
) -> None:
    (aarav, host), (riya, friend) = [await online(rt, api, n) for n in ("aarav", "riya")]
    neha = await player(api, "neha")
    kabir = await player(api, "kabir")
    await befriend(api, aarav, riya)
    await befriend(api, aarav, kabir)
    rid = (await make_room(api, aarav, "group"))["room_id"]

    async def invite(who: str) -> dict:  # type: ignore[type-arg]
        response = await api.post(
            "/v1/invites", json={"to_user_id": who, "room_id": rid}, headers=aarav.headers
        )
        return {"status": response.status_code, **response.json()}

    stranger = await invite(neha.uid)
    assert stranger["status"] == 403
    assert stranger["error"]["code"] == "NOT_ALLOWED"

    await api.put(
        "/v1/me/settings/privacy",
        json={
            "friend_requests": "everyone",
            "challenges": "nobody",
            "presence": "friends",
            "public_boards": True,
        },
        headers=kabir.headers,
    )
    private = await invite(kabir.uid)
    assert private["status"] == 403
    assert private["error"]["details"]["reason"] == "privacy"

    # Riya is searching: she's busy, with where.
    await search(friend, "rated")
    busy = await invite(riya.uid)
    assert busy["status"] == 409
    assert busy["error"]["code"] == "BUSY"
    assert busy["error"]["details"]["active"]["kind"] == "queue"
    await friend.request("mm.cancel", {})

    # A pending invite is cancelled when one blocks the other.
    pending = await invite(riya.uid)
    assert pending["status"] == 201
    await api.post("/v1/blocks", json={"user_id": aarav.uid}, headers=riya.headers)
    async with sessions() as db:
        row = await db.get_one(RoomInvite, uuid.UUID(pending["invite_id"]))
        assert row.status == InviteStatus.CANCELLED
    for bot in (host, friend):
        await bot.close()


async def test_a_banned_or_deleted_player_leaves_their_room(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    (aarav, host), (riya, friend) = [await online(rt, api, n) for n in ("aarav", "riya")]
    room = await make_room(api, aarav, "group")
    rid = room["room_id"]
    await join(host, room_id=rid)
    await join(friend, code=room["code"])
    async with sessions() as db:
        assert await withdraw_player(db, redis, NoopEscrow(), aarav.id) == "left"
        await db.commit()
    state = await seen_or_next(friend, "room.state", lambda f: f["d"]["host"] == riya.uid)
    assert [m["uid"] for m in state["d"]["members"]] == [riya.uid]
    assert await redis.get(keys.busy(aarav.uid)) is None
    async with sessions() as db:
        assert (await db.get_one(Room, uuid.UUID(rid))).closed_at is None
        assert await withdraw_player(db, redis, NoopEscrow(), riya.id) == "left"
        await db.commit()
        assert (await db.get_one(Room, uuid.UUID(rid))).close_reason == "empty"
    for bot in (host, friend):
        await bot.close()
