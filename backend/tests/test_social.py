"""Friends, requests, presence, blocks, activity, search, public profiles and privacy."""

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.models import Notification
from app.modules.social import blocks
from app.modules.social import friends as friends_module
from app.modules.social import privacy as privacy_module
from app.modules.social import profiles as profiles_module
from app.modules.social.activity import record_activity
from app.modules.social.models import FriendRequest, RequestStatus
from app.modules.social.presence import Presence, get_presence_many, read_presence, set_presence
from app.modules.social.privacy import can_challenge, have_played
from app.modules.social.relations import are_blocked, blocked_ids
from tests.helpers import FakeClock, bearer, dev_login
from tests.platform_helpers import bare_user
from tests.social_helpers import MINOR, Player, befriend, friend_ids, player


async def send(client: AsyncClient, sender: Player, target: Player) -> dict[str, Any]:
    response = await client.post(
        "/v1/friend-requests", json={"user_id": target.uid}, headers=sender.headers
    )
    return {**response.json(), "http": response.status_code}


async def inbox_kinds(db: AsyncSession, who: Player) -> list[str]:
    rows = await db.scalars(
        select(Notification.kind).where(Notification.user_id == who.id).order_by(Notification.id)
    )
    return list(rows)


@pytest.fixture
def played_with_everyone(monkeypatch: pytest.MonkeyPatch) -> None:
    async def played(_db: object, _a: uuid.UUID, _b: uuid.UUID) -> bool:
        return True

    monkeypatch.setattr(privacy_module, "_have_played", played)


# --- Requests ---------------------------------------------------------------------------------


async def test_a_request_accepted_makes_friends(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    sent = await send(client, asha, ravi)
    requests = (await client.get("/v1/me/friend-requests", headers=ravi.headers)).json()
    accepted = await client.post(f"/v1/friend-requests/{sent['id']}/accept", headers=ravi.headers)

    assert sent["http"] == 201
    assert sent["direction"] == "outgoing"
    assert sent["user"]["id"] == ravi.uid
    assert sent["user"]["level"] == 1
    assert "email" not in sent["user"]
    assert [item["id"] for item in requests["incoming"]] == [sent["id"]]
    assert requests["incoming"][0]["user"]["handle"] == asha.handle
    assert requests["outgoing"] == []
    assert accepted.status_code == 200
    assert accepted.json()["status"] == "accepted"
    assert await friend_ids(client, asha) == [ravi.uid]
    assert await friend_ids(client, ravi) == [asha.uid]
    assert await inbox_kinds(db_session, ravi) == ["friend_request"]
    assert await inbox_kinds(db_session, asha) == ["friend_accepted"]


async def test_asking_twice_returns_the_same_request(client: AsyncClient) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    first, second = await send(client, asha, ravi), await send(client, asha, ravi)

    assert first["id"] == second["id"]
    assert second["http"] == 201


async def test_asking_back_accepts_the_pending_request(client: AsyncClient) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    first = await send(client, asha, ravi)
    back = await send(client, ravi, asha)

    assert back["id"] == first["id"]
    assert back["http"] == 201
    assert back["direction"] == "incoming"
    assert (await client.get("/v1/me/friend-requests", headers=asha.headers)).json() == {
        "incoming": [],
        "outgoing": [],
    }
    assert await friend_ids(client, asha) == [ravi.uid]
    again = await send(client, asha, ravi)
    assert (again["http"], again["error"]["code"]) == (409, "ALREADY_FRIENDS")


async def test_decline_and_cancel(client: AsyncClient, db_session: AsyncSession) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    declined = await send(client, asha, ravi)
    response = await client.post(
        f"/v1/friend-requests/{declined['id']}/decline", headers=ravi.headers
    )
    assert response.json()["status"] == "declined"
    late = await client.post(f"/v1/friend-requests/{declined['id']}/accept", headers=ravi.headers)
    assert (late.status_code, late.json()["error"]["code"]) == (409, "REQUEST_CLOSED")

    withdrawn = await send(client, asha, ravi)  # a new request after a decline is fine
    assert withdrawn["id"] != declined["id"]
    cancel = await client.delete(f"/v1/friend-requests/{withdrawn['id']}", headers=asha.headers)
    assert cancel.status_code == 204
    status = await db_session.scalar(
        select(FriendRequest.status).where(FriendRequest.id == uuid.UUID(withdrawn["id"]))
    )
    assert status == RequestStatus.CANCELLED
    assert await friend_ids(client, asha) == []


async def test_requests_to_yourself_or_nobody_fail(client: AsyncClient) -> None:
    asha = await player(client, "asha")

    own = await client.post("/v1/friend-requests", json={"user_id": asha.uid}, headers=asha.headers)
    ghost = await client.post(
        "/v1/friend-requests", json={"user_id": str(uuid.uuid4())}, headers=asha.headers
    )

    assert own.status_code == 422
    assert (ghost.status_code, ghost.json()["error"]["code"]) == (404, "USER_NOT_FOUND")


async def test_removing_a_friend(client: AsyncClient) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    await befriend(client, asha, ravi)

    response = await client.delete(f"/v1/me/friends/{ravi.uid}", headers=asha.headers)

    assert response.status_code == 204
    assert await friend_ids(client, asha) == []
    assert await friend_ids(client, ravi) == []


# --- Limits and privacy -------------------------------------------------------------------------


async def test_twenty_requests_a_day(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    for index in range(20):
        other = await bare_user(db_session, f"p{index}")
        db_session.add(FriendRequest(from_id=asha.id, to_id=other, created_at=clock()))
    await db_session.commit()

    over = await send(client, asha, ravi)
    clock.advance(days=1)
    asha.headers = await sign_in_again(client, "asha")
    tomorrow = await send(client, asha, ravi)

    assert (over["http"], over["error"]["code"]) == (409, "LIMIT_REACHED")
    assert over["error"]["details"] == {"limit": "daily", "max": 20}
    assert tomorrow["http"] == 201


async def test_pending_and_friend_caps(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    asha, ravi, meera, kiran = [
        await player(client, name) for name in ("asha", "ravi", "meera", "kiran")
    ]
    monkeypatch.setattr(friends_module, "MAX_PENDING", 1)
    monkeypatch.setattr(friends_module, "MAX_FRIENDS", 1)

    assert (await send(client, asha, ravi))["http"] == 201
    pending = await send(client, asha, meera)
    await befriend(client, meera, kiran)
    full = await send(client, ravi, kiran)

    assert pending["error"]["details"]["limit"] == "pending"
    assert (full["http"], full["error"]["details"]["limit"]) == (409, "their_friends")


async def test_privacy_can_refuse_requests(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    await client.put(
        "/v1/me/settings/privacy",
        json={
            "friend_requests": "nobody",
            "challenges": "friends",
            "presence": "friends",
            "public_boards": True,
        },
        headers=ravi.headers,
    )

    refused = await send(client, asha, ravi)

    assert (refused["http"], refused["error"]["code"]) == (403, "NOT_ALLOWED")
    assert refused["error"]["details"] == {"reason": "nobody"}


async def test_minors_only_hear_from_people_they_played(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    asha, teen = await player(client, "asha"), await player(client, "teen", birth_year=MINOR)

    refused = await send(client, asha, teen)

    async def played(_db: object, a: uuid.UUID, b: uuid.UUID) -> bool:
        return {a, b} == {asha.id, teen.id}

    privacy_module.register_have_played(played)
    try:
        allowed = await send(client, asha, teen)
    finally:
        monkeypatch.setattr(privacy_module, "_have_played", privacy_module._never_played)

    assert refused["error"]["details"] == {"reason": "played_with"}
    assert allowed["http"] == 201


async def test_have_played_defaults_to_false(db_session: AsyncSession) -> None:
    assert await have_played(db_session, uuid.uuid4(), uuid.uuid4()) is False


async def test_privacy_settings_defaults_and_changes(client: AsyncClient) -> None:
    adult, teen = await player(client, "asha"), await player(client, "teen", birth_year=MINOR)

    adult_defaults = (await client.get("/v1/me/settings/privacy", headers=adult.headers)).json()
    teen_defaults = (await client.get("/v1/me/settings/privacy", headers=teen.headers)).json()
    choice = {
        "friend_requests": "played_with",
        "challenges": "nobody",
        "presence": "nobody",
        "public_boards": False,
    }
    saved = await client.put("/v1/me/settings/privacy", json=choice, headers=adult.headers)
    bad = await client.put(
        "/v1/me/settings/privacy", json={**choice, "presence": "everyone"}, headers=adult.headers
    )

    assert adult_defaults == {
        "friend_requests": "everyone",
        "challenges": "everyone",
        "presence": "friends",
        "public_boards": True,
        "is_minor": False,
    }
    assert teen_defaults == {
        "friend_requests": "played_with",
        "challenges": "friends",
        "presence": "friends",
        "public_boards": True,
        "is_minor": True,
    }
    assert saved.json() == {**choice, "is_minor": False}
    assert (await client.get("/v1/me/settings/privacy", headers=adult.headers)).json() == {
        **choice,
        "is_minor": False,
    }
    assert bad.status_code == 422
    widen = await client.put(
        "/v1/me/settings/privacy",
        json={**choice, "friend_requests": "everyone"},
        headers=teen.headers,
    )
    assert widen.status_code == 422
    assert widen.json()["error"]["details"]["fields"] == {
        "friend_requests": privacy_module.MINOR_REQUESTS_MESSAGE
    }


async def test_minor_defaults_lift_at_eighteen(client: AsyncClient, clock: FakeClock) -> None:
    teen = await player(client, "teen", birth_year=clock().year - 17)

    clock.advance(days=366)
    grown = (
        await client.get("/v1/me/settings/privacy", headers=await sign_in_again(client, "teen"))
    ).json()

    assert grown["friend_requests"] == "everyone"
    assert grown["is_minor"] is False
    assert teen.handle


async def sign_in_again(client: AsyncClient, name: str) -> dict[str, str]:
    login = await dev_login(client, f"{name}@example.com", install_id=f"install-{name}")
    return bearer(login["access_token"])


async def test_challenge_rules(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    asha, ravi, teen = (
        await player(client, "asha"),
        await player(client, "ravi"),
        await player(client, "teen", birth_year=MINOR),
    )

    assert await can_challenge(db_session, asha.id, ravi.id, now=clock()) is True
    assert await can_challenge(db_session, asha.id, teen.id, now=clock()) is False  # friends only
    assert await can_challenge(db_session, asha.id, asha.id, now=clock()) is False
    await befriend(client, teen, asha)
    assert await can_challenge(db_session, asha.id, teen.id, now=clock()) is True
    await client.post("/v1/blocks", json={"user_id": asha.uid}, headers=ravi.headers)
    assert await can_challenge(db_session, asha.id, ravi.id, now=clock()) is False


# --- Presence ---------------------------------------------------------------------------------


async def test_presence_is_for_friends_who_share_it(
    client: AsyncClient, db_session: AsyncSession, redis: Redis
) -> None:
    asha, ravi, meera = [await player(client, name) for name in ("asha", "ravi", "meera")]
    await befriend(client, asha, ravi)
    await set_presence(redis, ravi.id, Presence.IN_BATTLE, ttl_s=60)
    await set_presence(redis, meera.id, "online", ttl_s=60)

    listed = (await client.get("/v1/me/friends", headers=asha.headers)).json()["items"]
    seen = await get_presence_many(redis, [ravi.id, meera.id], db=db_session, viewer_id=asha.id)
    await client.put(
        "/v1/me/settings/privacy",
        json={
            "friend_requests": "everyone",
            "challenges": "everyone",
            "presence": "nobody",
            "public_boards": True,
        },
        headers=ravi.headers,
    )
    hidden = (await client.get("/v1/me/friends", headers=asha.headers)).json()["items"]

    assert listed[0]["presence"] == "in_battle"
    assert listed[0]["can_challenge"] is True
    assert seen == {ravi.id: Presence.IN_BATTLE, meera.id: Presence.OFFLINE}  # not a friend
    assert hidden[0]["presence"] == "offline"
    assert (await read_presence(redis, [meera.id])) == {meera.id: Presence.ONLINE}
    await set_presence(redis, meera.id, "offline")
    assert (await read_presence(redis, [meera.id])) == {meera.id: Presence.OFFLINE}
    assert 0 < await redis.ttl(f"presence:{ravi.id}") <= 60


async def test_friends_list_pages_by_name(client: AsyncClient) -> None:
    asha = await player(client, "asha")
    names = ["zoya", "bala", "meera"]
    for name in names:
        await befriend(client, asha, await player(client, name))

    first = (await client.get("/v1/me/friends?limit=2", headers=asha.headers)).json()
    second = (
        await client.get(
            f"/v1/me/friends?limit=2&cursor={first['next_cursor']}", headers=asha.headers
        )
    ).json()

    assert [item["display_name"] for item in first["items"]] == ["Bala", "Meera"]
    assert [item["display_name"] for item in second["items"]] == ["Zoya"]
    assert second["next_cursor"] is None


# --- Blocks -----------------------------------------------------------------------------------


async def test_blocking_ends_everything_between_the_two(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    asha, ravi, meera = [await player(client, name) for name in ("asha", "ravi", "meera")]
    await befriend(client, asha, ravi)
    pending = await send(client, meera, asha)

    blocked = await client.post("/v1/blocks", json={"user_id": ravi.uid}, headers=asha.headers)
    await client.post("/v1/blocks", json={"user_id": meera.uid}, headers=asha.headers)
    listed = (await client.get("/v1/me/blocks", headers=asha.headers)).json()

    assert blocked.status_code == 204
    assert await friend_ids(client, asha) == []
    assert await friend_ids(client, ravi) == []
    status = await db_session.scalar(
        select(FriendRequest.status).where(FriendRequest.id == uuid.UUID(pending["id"]))
    )
    assert status == RequestStatus.CANCELLED
    assert {item["user"]["id"] for item in listed["items"]} == {ravi.uid, meera.uid}
    assert await are_blocked(db_session, ravi.id, asha.id)  # either direction counts
    assert await blocked_ids(db_session, ravi.id) == {asha.id}
    assert await blocked_ids(db_session, asha.id) == {ravi.id, meera.id}
    # Neither can find, view or ask the other.
    for viewer, other in ((asha, ravi), (ravi, asha)):
        profile = await client.get(f"/v1/users/{other.handle}", headers=viewer.headers)
        search = await client.get(f"/v1/users/search?q={other.handle}", headers=viewer.headers)
        assert profile.status_code == 404
        assert search.json()["items"] == []
    ask = await send(client, ravi, asha)
    assert (ask["http"], ask["error"]["code"]) == (404, "USER_NOT_FOUND")

    unblocked = await client.delete(f"/v1/blocks/{ravi.uid}", headers=asha.headers)
    assert unblocked.status_code == 204
    assert not await are_blocked(db_session, asha.id, ravi.id)
    assert (await client.get(f"/v1/users/{ravi.handle}", headers=asha.headers)).status_code == 200


async def test_block_hooks_run(client: AsyncClient, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[uuid.UUID, uuid.UUID]] = []

    async def hook(_db: object, blocker: uuid.UUID, blocked: uuid.UUID, _now: object) -> None:
        calls.append((blocker, blocked))

    monkeypatch.setattr(blocks, "_BLOCK_HOOKS", [])
    blocks.register_block_hook(hook)
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    await client.post("/v1/blocks", json={"user_id": ravi.uid}, headers=asha.headers)
    own = await client.post("/v1/blocks", json={"user_id": asha.uid}, headers=asha.headers)

    assert calls == [(asha.id, ravi.id)]
    assert own.status_code == 422


# --- Search and profiles ------------------------------------------------------------------------


async def test_search_by_handle_prefix(client: AsyncClient) -> None:
    asha = await player(client, "asha")
    exact = await player(client, "rav", handle="rav_1")
    longer = await player(client, "ravi", handle="rav_10")
    await player(client, "other", handle="ravx_22")  # "_" is literal, not a wildcard
    await befriend(client, asha, longer)

    found = (await client.get("/v1/users/search?q=@RAV_1", headers=asha.headers)).json()
    short = await client.get("/v1/users/search?q=ra", headers=asha.headers)

    assert [(item["id"], item["relationship"]) for item in found["items"]] == [
        (exact.uid, "none"),
        (longer.uid, "friend"),
    ]
    assert set(found["items"][0]) == {
        "id", "handle", "display_name", "avatar", "level", "relationship"
    }  # fmt: skip
    assert short.status_code == 422
    assert short.json()["error"]["details"]["fields"]["q"] == profiles_module.QUERY_MESSAGE


async def test_public_profile(client: AsyncClient, monkeypatch: pytest.MonkeyPatch) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    async def ratings(_db: object, _viewer: uuid.UUID, target: uuid.UUID) -> list[Any]:
        return [{"scope": "physics", "rating": {"display": "1500?"}, "target": str(target)}]

    monkeypatch.setattr(profiles_module, "_SECTIONS", {})
    profiles_module.register_profile_section("ratings", ratings)
    with pytest.raises(ValueError, match="unknown profile section"):
        profiles_module.register_profile_section("secrets", ratings)

    before = (await client.get(f"/v1/users/{ravi.handle.upper()}", headers=asha.headers)).json()
    request = await send(client, asha, ravi)
    requested = (await client.get(f"/v1/users/{asha.handle}", headers=ravi.headers)).json()
    missing = await client.get("/v1/users/nobody_here", headers=asha.headers)

    assert before["id"] == ravi.uid
    assert before["relationship"] == "none"
    assert before["can_challenge"] is True
    assert before["limited"] is False
    assert before["ratings"] == [
        {"scope": "physics", "rating": {"display": "1500?"}, "target": ravi.uid}
    ]
    assert before["form"] == []
    assert before["h2h"] is None
    assert before["friend_request"] is None
    assert "email" not in before
    assert requested["relationship"] == "requested"
    assert requested["friend_request"] == {"id": request["id"], "direction": "incoming"}
    assert (missing.status_code, missing.json()["error"]["code"]) == (404, "USER_NOT_FOUND")


async def test_minors_show_strangers_only_their_card(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    asha, teen = await player(client, "asha"), await player(client, "teen", birth_year=MINOR)

    async def form(_db: object, _viewer: uuid.UUID, _target: uuid.UUID) -> list[str]:
        return ["win"]

    monkeypatch.setattr(profiles_module, "_SECTIONS", {"form": form})

    stranger = (await client.get(f"/v1/users/{teen.handle}", headers=asha.headers)).json()
    await befriend(client, teen, asha)
    friend = (await client.get(f"/v1/users/{teen.handle}", headers=asha.headers)).json()

    assert stranger["limited"] is True
    assert stranger["form"] == []
    assert stranger["ratings"] == []
    assert stranger["h2h"] is None
    assert stranger["can_challenge"] is False  # minors default to friends-only challenges
    assert stranger["display_name"] == "Teen"
    assert stranger["level"] == 1
    assert friend["limited"] is False
    assert friend["form"] == ["win"]
    assert friend["can_challenge"] is True


# --- Activity ---------------------------------------------------------------------------------


async def test_friends_activity_from_the_last_week(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    asha, ravi, meera = [await player(client, name) for name in ("asha", "ravi", "meera")]
    await befriend(client, asha, ravi)
    assert await record_activity(db_session, ravi.id, "level_up", {"level": 5}, key="level:5")
    assert not await record_activity(db_session, ravi.id, "level_up", {"level": 5}, key="level:5")
    await record_activity(db_session, meera.id, "streak", {"days": 7}, key="streak:7")
    await db_session.commit()

    feed = (await client.get("/v1/me/activity", headers=asha.headers)).json()["items"]
    clock.advance(days=8)
    later = (
        await client.get("/v1/me/activity", headers=await sign_in_again(client, "asha"))
    ).json()["items"]

    kinds = [(item["user"]["id"], item["kind"]) for item in feed]
    assert (ravi.uid, "level_up") in kinds
    assert (ravi.uid, "friend") in kinds  # "Ravi is now friends with Asha"
    assert all(user_id != meera.uid for user_id, _ in kinds)  # not a friend
    friend_item = next(item for item in feed if item["kind"] == "friend")
    assert friend_item["payload"]["friend"]["id"] == asha.uid
    assert later == []


async def test_activity_never_shows_a_minors_friendships_to_strangers(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    teen = await player(client, "teen", birth_year=MINOR)
    await befriend(client, asha, ravi)
    await befriend(client, teen, ravi)

    feed = (await client.get("/v1/me/activity", headers=asha.headers)).json()["items"]

    others = [item["payload"]["friend"]["id"] for item in feed if item["kind"] == "friend"]
    assert teen.uid not in others
    assert asha.uid in others


# --- Scoping: nobody touches another player's requests, blocks or settings ---------------------


async def test_other_players_requests_blocks_and_settings_are_out_of_reach(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    asha, ravi, eve = [await player(client, name) for name in ("asha", "ravi", "eve")]
    request = await send(client, asha, ravi)
    await client.post("/v1/blocks", json={"user_id": ravi.uid}, headers=asha.headers)  # cancels it
    fresh = await send(client, ravi, eve)

    # Eve can't accept, decline or cancel requests that aren't hers to answer or withdraw.
    for method, path in (
        ("POST", f"/v1/friend-requests/{request['id']}/accept"),
        ("POST", f"/v1/friend-requests/{request['id']}/decline"),
        ("DELETE", f"/v1/friend-requests/{request['id']}"),
        ("DELETE", f"/v1/friend-requests/{fresh['id']}"),  # sent by Ravi, not Eve
    ):
        response = await client.request(method, path, headers=eve.headers)
        assert (response.status_code, response.json()["error"]["code"]) == (
            404,
            "FRIEND_REQUEST_NOT_FOUND",
        ), path
    # The sender can't accept their own request.
    own = await client.post(f"/v1/friend-requests/{fresh['id']}/accept", headers=ravi.headers)
    assert own.status_code == 404
    # Lists only ever show the caller's own.
    assert (await client.get("/v1/me/friend-requests", headers=asha.headers)).json() == {
        "incoming": [],
        "outgoing": [],
    }
    assert (await client.get("/v1/me/blocks", headers=eve.headers)).json()["items"] == []
    # Eve can't lift Asha's block: DELETE /blocks/{id} only removes Eve's own blocks.
    await client.delete(f"/v1/blocks/{ravi.uid}", headers=eve.headers)
    await client.delete(f"/v1/blocks/{asha.uid}", headers=eve.headers)
    assert await are_blocked(db_session, asha.id, ravi.id)
    # Settings are always the caller's: there is no way to name another player.
    await client.put(
        "/v1/me/settings/privacy",
        json={
            "friend_requests": "nobody",
            "challenges": "nobody",
            "presence": "nobody",
            "public_boards": False,
        },
        headers=eve.headers,
    )
    assert (await client.get("/v1/me/settings/privacy", headers=asha.headers)).json()[
        "friend_requests"
    ] == "everyone"
    # Removing a "friend" who isn't one changes nothing for anyone.
    removed = await client.delete(f"/v1/me/friends/{ravi.uid}", headers=eve.headers)
    assert removed.status_code == 204
    pending = await db_session.scalar(
        select(func.count()).where(
            FriendRequest.id == uuid.UUID(fresh["id"]),
            FriendRequest.status == RequestStatus.PENDING.value,
        )
    )
    assert pending == 1


async def test_social_endpoints_need_sign_in(client: AsyncClient) -> None:
    some_id = uuid.uuid4()
    for method, path in (
        ("GET", "/v1/me/friends"),
        ("POST", "/v1/friend-requests"),
        ("GET", "/v1/me/friend-requests"),
        ("POST", f"/v1/friend-requests/{some_id}/accept"),
        ("DELETE", f"/v1/me/friends/{some_id}"),
        ("GET", "/v1/me/activity"),
        ("POST", "/v1/blocks"),
        ("GET", "/v1/me/blocks"),
        ("GET", "/v1/users/search?q=abc"),
        ("GET", "/v1/users/abc"),
        ("GET", "/v1/me/settings/privacy"),
        ("POST", "/v1/reports"),
    ):
        assert (await client.request(method, path)).status_code == 401, path
