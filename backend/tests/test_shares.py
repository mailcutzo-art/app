"""Sharing a battle result or progress to friends' activity (POST /v1/me/activity/shares)."""

import uuid
from datetime import timedelta
from typing import Any

import pytest
from httpx import AsyncClient, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.modules.content.models import Subject
from app.modules.practice.models import UserDailyStats
from app.modules.progression.models import UserProgress
from app.modules.social import profiles as profiles_module
from app.modules.social import shares
from app.modules.social.activity import HIDDEN_OPPONENT
from app.modules.social.models import ActivityEvent
from tests.helpers import FakeClock, bearer, dev_login
from tests.social_helpers import MINOR, Player, befriend, player

# match id -> (the player it belongs to, the payload the engine would build for them)
Matches = dict[uuid.UUID, tuple[uuid.UUID, dict[str, Any]]]


@pytest.fixture
def matches(monkeypatch: pytest.MonkeyPatch) -> Matches:
    """A stand-in for the realtime engine's source: each match belongs to one player."""
    known: Matches = {}
    sources: dict[str, shares.ShareSource] = {}
    monkeypatch.setattr(shares, "_SOURCES", sources)

    async def source(_db: AsyncSession, user_id: uuid.UUID, ref_id: str) -> dict[str, Any] | None:
        entry = known.get(uuid.UUID(ref_id))
        if entry is None or entry[0] != user_id:
            return None
        return entry[1]

    shares.register_share_source("match_result", source)
    return known


def a_match(
    known: Matches, owner: Player, *, opponent: Player | None = None, **fields: Any
) -> uuid.UUID:
    match_id = uuid.uuid4()
    payload: dict[str, Any] = {
        "match_id": match_id,
        "mode": "quick_rated",
        "result": "win",
        "subject": "Physics",
        "chapter": "Kinematics",
        "score": 840,
        "opponent_score": 610,
        "questions": ["correct", "correct", "wrong", "skipped", "correct"],
        "rating_change": 14,
        "coins": 50,
        "xp": 30,
    }
    if opponent is not None:
        payload["opponent_id"] = opponent.id
    else:
        payload["opponent_name"] = "Robo Ravi"
    payload.update(fields)
    known[match_id] = (owner.id, payload)
    return match_id


async def post_share(
    client: AsyncClient, who: Player, body: dict[str, Any], *, key: str | None = None
) -> Response:
    return await client.post(
        "/v1/me/activity/shares",
        json=body,
        headers={**who.headers, "Idempotency-Key": key or uuid.uuid4().hex},
    )


async def feed(client: AsyncClient, headers: dict[str, str]) -> list[dict[str, Any]]:
    response = await client.get("/v1/me/activity", headers=headers)
    assert response.status_code == 200, response.text
    return list(response.json()["items"])


async def shares_of(db: AsyncSession, who: Player) -> int:
    return (
        await db.scalar(
            select(func.count()).where(
                ActivityEvent.user_id == who.id, ActivityEvent.kind.like("shared_%")
            )
        )
        or 0
    )


# --- Results -----------------------------------------------------------------------------------


async def test_a_shared_win_reaches_friends_and_the_sharer(
    client: AsyncClient, matches: Matches
) -> None:
    asha, ravi, meera = [await player(client, name) for name in ("asha", "ravi", "meera")]
    await befriend(client, asha, ravi)
    match_id = a_match(matches, asha, opponent=meera)

    response = await post_share(client, asha, {"kind": "match_result", "match_id": str(match_id)})

    assert response.status_code == 201, response.text
    item = response.json()
    assert item["kind"] == "shared_result"
    assert item["user"]["id"] == asha.uid
    payload = item["payload"]
    assert payload["match_id"] == str(match_id)
    assert (payload["result"], payload["score"], payload["opponent_score"]) == ("win", 840, 610)
    assert payload["questions"] == ["correct", "correct", "wrong", "skipped", "correct"]
    assert (payload["rating_change"], payload["coins"], payload["xp"]) == (14, 50, 30)
    assert payload["opponent"]["id"] == meera.uid
    assert payload["opponent_name"] == "Meera"
    assert "opponent_id" not in payload
    friend_view = await feed(client, ravi.headers)
    assert [(i["kind"], i["id"]) for i in friend_view if i["kind"] == "shared_result"] == [
        ("shared_result", item["id"])
    ]
    own_view = await feed(client, asha.headers)
    assert item["id"] in [i["id"] for i in own_view]
    assert await feed(client, meera.headers) == []  # not Asha's friend


async def test_a_bot_opponent_keeps_its_name(client: AsyncClient, matches: Matches) -> None:
    asha = await player(client, "asha")
    match_id = a_match(matches, asha, result="loss", rating_change=None, coins=None, xp=None)

    item = (
        await post_share(client, asha, {"kind": "match_result", "match_id": str(match_id)})
    ).json()

    assert item["payload"]["opponent"] is None
    assert item["payload"]["opponent_name"] == "Robo Ravi"
    assert item["payload"]["rating_change"] is None


async def test_someone_elses_match_cannot_be_shared(
    client: AsyncClient, db_session: AsyncSession, matches: Matches
) -> None:
    asha, eve = await player(client, "asha"), await player(client, "eve")
    match_id = a_match(matches, asha)

    stolen = await post_share(client, eve, {"kind": "match_result", "match_id": str(match_id)})
    unknown = await post_share(client, eve, {"kind": "match_result", "match_id": str(uuid.uuid4())})

    for response in (stolen, unknown):
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "NOT_FOUND"
    assert await shares_of(db_session, eve) == 0


async def test_results_need_the_engines_source(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(shares, "_SOURCES", {})
    asha = await player(client, "asha")

    response = await post_share(
        client, asha, {"kind": "match_result", "match_id": str(uuid.uuid4())}
    )

    assert response.status_code == 404
    assert response.json()["error"]["message"] == "Battle results can't be shared yet."


async def test_a_match_is_shared_once_and_retries_replay(
    client: AsyncClient, db_session: AsyncSession, matches: Matches
) -> None:
    asha = await player(client, "asha")
    body = {"kind": "match_result", "match_id": str(a_match(matches, asha))}

    first = await post_share(client, asha, body, key="share-1")
    retry = await post_share(client, asha, body, key="share-1")
    again = await post_share(client, asha, body, key="share-2")

    assert first.status_code == retry.status_code == 201
    assert retry.headers["Idempotent-Replayed"] == "true"
    assert retry.json() == first.json()
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "ALREADY_SHARED"
    assert again.json()["error"]["details"] == {"activity_id": first.json()["id"]}
    assert await shares_of(db_session, asha) == 1


async def test_a_blocked_or_minor_opponent_is_not_named(
    client: AsyncClient, matches: Matches
) -> None:
    asha, ravi, meera = [await player(client, name) for name in ("asha", "ravi", "meera")]
    teen = await player(client, "teen", birth_year=MINOR)
    await befriend(client, asha, ravi)
    await client.post("/v1/blocks", json={"user_id": meera.uid}, headers=ravi.headers)
    for opponent in (meera, teen):
        match_id = a_match(matches, asha, opponent=opponent)
        response = await post_share(
            client, asha, {"kind": "match_result", "match_id": str(match_id)}
        )
        assert response.status_code == 201, response.text

    seen = [i["payload"] for i in await feed(client, ravi.headers) if i["kind"] == "shared_result"]

    assert len(seen) == 2
    for payload in seen:
        assert payload["opponent"] is None
        assert payload["opponent_name"] == HIDDEN_OPPONENT


async def test_a_shared_result_disappears_when_the_friendship_ends(
    client: AsyncClient, matches: Matches
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    await befriend(client, asha, ravi)
    match_id = a_match(matches, asha)
    await post_share(client, asha, {"kind": "match_result", "match_id": str(match_id)})

    await client.post("/v1/blocks", json={"user_id": asha.uid}, headers=ravi.headers)

    assert await feed(client, ravi.headers) == []


# --- Progress ----------------------------------------------------------------------------------


async def test_progress_is_built_from_real_numbers(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock, monkeypatch: pytest.MonkeyPatch
) -> None:
    asha = await player(client, "asha")
    physics = await db_session.scalar(select(Subject.id).where(Subject.slug == "physics"))
    today = clock().astimezone(IST).date()
    db_session.add(UserProgress(user_id=asha.id, xp=460))
    for back, attempts, correct in ((0, 30, 24), (1, 20, 12)):
        db_session.add(
            UserDailyStats(
                user_id=asha.id,
                day=today - timedelta(days=back),
                subject_id=physics,
                attempts=attempts,
                correct=correct,
                last_at=clock(),
            )
        )
    await db_session.commit()

    async def ratings(_db: AsyncSession, viewer: uuid.UUID, target: uuid.UUID) -> list[Any]:
        assert viewer == target == asha.id
        return [{"scope": "neet", "rating": 1523.6, "position": 12}, {"bad": True}]

    monkeypatch.setitem(profiles_module._SECTIONS, "ratings", ratings)

    response = await post_share(client, asha, {"kind": "progress"})

    assert response.status_code == 201, response.text
    item = response.json()
    assert item["kind"] == "shared_progress"
    assert item["payload"] == {
        "level": 4,  # level 4 starts at 450 XP, level 5 at 700
        "xp": 460,
        "xp_into_level": 10,
        "xp_for_level": 250,
        "streak": {"current": 2, "best": 2},
        "answered": 50,
        "correct": 36,
        "accuracy": 72,
        "ratings": [{"scope": "neet", "rating": 1524}],
    }


async def test_a_new_player_can_share_progress(client: AsyncClient) -> None:
    asha = await player(client, "asha")

    payload = (await post_share(client, asha, {"kind": "progress"})).json()["payload"]

    assert payload["level"] == 1
    assert (payload["answered"], payload["accuracy"]) == (0, None)
    assert payload["ratings"] == []


async def test_progress_can_be_shared_three_times_a_day(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    asha = await player(client, "asha")
    clock.now = clock.now.astimezone(IST).replace(hour=10)

    posted = [await post_share(client, asha, {"kind": "progress"}) for _ in range(3)]
    retry = await post_share(client, asha, {"kind": "progress"}, key="again")
    replay = await post_share(client, asha, {"kind": "progress"}, key="again")
    clock.advance(hours=15)  # 01:00 IST the next day
    headers = bearer(
        (await dev_login(client, "asha@example.com", install_id="install-asha"))["access_token"]
    )
    tomorrow = await client.post(
        "/v1/me/activity/shares",
        json={"kind": "progress"},
        headers={**headers, "Idempotency-Key": "tomorrow"},
    )

    assert [response.status_code for response in posted] == [201, 201, 201]
    assert retry.status_code == 409
    error = retry.json()["error"]
    assert (error["code"], error["details"]) == ("LIMIT_REACHED", {"limit": "daily", "max": 3})
    assert replay.status_code == 409  # a failure isn't stored: still over the limit
    assert tomorrow.status_code == 201, tomorrow.text
    assert await shares_of(db_session, asha) == 4


# --- The request ---------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "body",
    [
        {"kind": "progress", "text": "I am the best"},
        {"kind": "progress", "image": "data:image/png;base64,AAAA"},
        {"kind": "match_result", "match_id": str(uuid.uuid4()), "caption": "gg"},
        {"kind": "match_result"},
        {"kind": "message", "text": "hi"},
        {"kind": "progress", "payload": {"level": 99}},
    ],
)
async def test_nothing_but_what_to_share_is_accepted(
    client: AsyncClient, db_session: AsyncSession, matches: Matches, body: dict[str, Any]
) -> None:
    asha = await player(client, "asha")

    response = await post_share(client, asha, body)

    assert response.status_code == 422, response.text
    assert await shares_of(db_session, asha) == 0


async def test_sharing_needs_sign_in_and_an_idempotency_key(client: AsyncClient) -> None:
    asha = await player(client, "asha")

    anonymous = await client.post("/v1/me/activity/shares", json={"kind": "progress"})
    keyless = await client.post(
        "/v1/me/activity/shares", json={"kind": "progress"}, headers=asha.headers
    )

    assert anonymous.status_code == 401
    assert keyless.status_code == 400
    assert keyless.json()["error"]["code"] == "IDEMPOTENCY_KEY_MISSING"


def test_only_known_sources_register() -> None:
    async def source(_db: AsyncSession, _user: uuid.UUID, _ref: str) -> None:
        return None

    with pytest.raises(ValueError, match="unknown share source"):
        shares.register_share_source("tournament", source)
