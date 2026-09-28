"""The inbox, live ``notify`` events, push (FCM) with preferences and quiet hours, push tokens
and notification settings."""

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, time, timedelta
from pathlib import Path

import httpx
import orjson
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import IST, utc_now
from app.core.config import Settings
from app.modules.notifications import fcm
from app.modules.notifications.models import Notification, PushToken
from app.modules.notifications.service import in_quiet_hours, notify, purge_notifications
from app.modules.outbox.models import OutboxMessage
from tests.helpers import bearer, dev_login, make_settings
from tests.platform_helpers import FakeFcm, deliver, onboarded, service_account_file, user_id

TOKEN_A = "fcm-token-aaaaaaaaaaaaaaaa"
TOKEN_B = "fcm-token-bbbbbbbbbbbbbbbb"


async def topics(db: AsyncSession, notification_id: uuid.UUID) -> list[str]:
    rows = await db.scalars(
        select(OutboxMessage.topic)
        .where(OutboxMessage.payload["notification_id"].astext == str(notification_id))
        .order_by(OutboxMessage.topic)
    )
    return list(rows)


async def send(db: AsyncSession, user: uuid.UUID, n: int = 1, **overrides: object) -> uuid.UUID:
    values: dict[str, object] = {
        "kind": "prize",
        "title": f"Prize {n}",
        "body": "You won coins.",
        "icon": "coins",
        "action": {"route": "/wallet", "params": {}},
        "key": f"prize:{n}",
        **overrides,
    }
    notification_id = await notify(db, user, **values)  # type: ignore[arg-type]
    assert notification_id is not None
    await db.commit()
    return notification_id


# --- Quiet hours ---------------------------------------------------------------------------


def ist(hour: int, minute: int = 0) -> datetime:
    return datetime(2026, 9, 28, hour, minute, tzinfo=IST)


@pytest.mark.parametrize(
    ("moment", "quiet"),
    [
        (ist(22, 29), False),
        (ist(22, 30), True),
        (ist(23, 59), True),
        (ist(3, 0), True),
        (ist(6, 59), True),
        (ist(7, 0), False),
        (ist(12, 0), False),
    ],
)
def test_quiet_hours_span_midnight_in_india(moment: datetime, quiet: bool) -> None:
    assert in_quiet_hours(moment.astimezone(UTC), time(22, 30), time(7, 0)) is quiet


def test_daytime_and_missing_quiet_hours() -> None:
    assert in_quiet_hours(ist(13, 0), time(12, 0), time(14, 0)) is True
    assert in_quiet_hours(ist(15, 0), time(12, 0), time(14, 0)) is False
    assert in_quiet_hours(ist(3, 0), None, None) is False
    assert in_quiet_hours(ist(3, 0), time(5, 0), time(5, 0)) is False


# --- notify() ------------------------------------------------------------------------------


async def test_notify_writes_the_item_and_its_deliveries_once(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    user = await user_id(client, await onboarded(client, "asha"))

    notification_id = await send(db_session, user)

    item = await db_session.get_one(Notification, notification_id)
    assert (item.kind, item.title, item.icon, item.read_at) == ("prize", "Prize 1", "coins", None)
    assert await topics(db_session, notification_id) == ["notify.live", "notify.push"]
    assert (
        await notify(db_session, user, kind="prize", title="Again", body="-", key="prize:1") is None
    )


async def test_inbox_only_kinds_and_push_false_skip_push(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    user = await user_id(client, await onboarded(client, "asha"))

    settled = await send(db_session, user, 1, kind="match_settled")
    quiet = await send(db_session, user, 2, push=False)
    forced = await send(db_session, user, 3, kind="match_settled", push=True)

    assert await topics(db_session, settled) == ["notify.live"]
    assert await topics(db_session, quiet) == ["notify.live"]
    assert await topics(db_session, forced) == ["notify.live", "notify.push"]
    with pytest.raises(ValueError, match="not a valid NotificationKind"):
        await notify(db_session, user, kind="party", title="-", body="-")


# --- The inbox endpoints ---------------------------------------------------------------------


async def test_inbox_lists_newest_first_and_marks_read(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)
    ids = [await send(db_session, user, n) for n in range(5)]
    other = await user_id(client, await onboarded(client, "bea"))
    theirs = await send(db_session, other, 99)

    first = (await client.get("/v1/me/notifications?limit=3", headers=headers)).json()
    rest = (
        await client.get(
            f"/v1/me/notifications?limit=3&cursor={first['next_cursor']}", headers=headers
        )
    ).json()

    assert [item["title"] for item in first["items"] + rest["items"]] == [
        f"Prize {n}" for n in (4, 3, 2, 1, 0)
    ]
    assert rest["next_cursor"] is None
    assert first["items"][0] == {
        "id": str(ids[4]),
        "kind": "prize",
        "title": "Prize 4",
        "body": "You won coins.",
        "icon": "coins",
        "action": {"route": "/wallet", "params": {}},
        "created_at": first["items"][0]["created_at"],
        "read": False,
    }
    unread = await client.get("/v1/me/notifications/unread-count", headers=headers)
    assert unread.json() == {"count": 5}

    # Someone else's id is ignored.
    response = await client.post(
        "/v1/me/notifications/read",
        headers=headers,
        json={"ids": [str(ids[0]), str(ids[1]), str(theirs)]},
    )
    assert response.status_code == 204
    counts = (await client.get("/v1/me/notifications/unread-count", headers=headers)).json()
    assert counts == {"count": 3}
    await db_session.refresh(await db_session.get_one(Notification, theirs))
    assert (await db_session.get_one(Notification, theirs)).read_at is None

    assert (
        await client.post("/v1/me/notifications/read", headers=headers, json={"all": True})
    ).status_code == 204
    assert (await client.get("/v1/me/notifications/unread-count", headers=headers)).json() == {
        "count": 0
    }
    listed = (await client.get("/v1/me/notifications", headers=headers)).json()
    assert all(item["read"] for item in listed["items"])


@pytest.mark.parametrize(
    "body",
    [{}, {"all": False}, {"ids": []}, {"ids": ["x"]}, {"ids": [str(uuid.uuid4())], "all": True}],
)
async def test_mark_read_needs_ids_or_all(client: AsyncClient, body: dict[str, object]) -> None:
    headers = await onboarded(client, "asha")

    response = await client.post("/v1/me/notifications/read", headers=headers, json=body)

    assert response.status_code == 422


async def test_old_notices_leave_the_inbox_after_90_days(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)
    await send(db_session, user)

    assert await purge_notifications(db_session, now=utc_now() + timedelta(days=89)) == 0
    assert await purge_notifications(db_session, now=utc_now() + timedelta(days=91)) == 1
    assert (await client.get("/v1/me/notifications", headers=headers)).json()["items"] == []


# --- Live delivery ---------------------------------------------------------------------------


async def test_live_delivery_publishes_a_notify_event_on_the_users_channel(
    client: AsyncClient,
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    settings: Settings,
) -> None:
    user = await user_id(client, await onboarded(client, "asha"))
    await send(db_session, user, 1)
    notification_id = await send(
        db_session, user, 2, action={"route": "/arena/t1", "params": {"a": 1}}
    )
    pubsub = redis.pubsub()
    await pubsub.subscribe(f"ev:u:{user}")
    await pubsub.get_message(timeout=1)  # the subscribe confirmation

    result = await deliver(session_factory, redis, settings)

    assert result.delivered == 4  # two live events, two pushes (off: nothing to send)
    events = []
    while (
        message := await pubsub.get_message(ignore_subscribe_messages=True, timeout=1)
    ) is not None:
        events.append(orjson.loads(message["data"]))
    await pubsub.aclose()
    assert [event["d"]["title"] for event in events] == ["Prize 1", "Prize 2"]
    last = events[-1]
    assert set(last) == {"v", "t", "ch", "ts", "d"}
    assert (last["v"], last["t"], last["ch"]) == (1, "notify", "u")
    assert isinstance(last["ts"], int)
    assert last["d"] == {
        "id": str(notification_id),
        "kind": "prize",
        "title": "Prize 2",
        "body": "You won coins.",
        "action": {"route": "/arena/t1", "params": {"a": 1}},
        "unread": 2,
    }


# --- Push ------------------------------------------------------------------------------------


@pytest.fixture
async def push(tmp_path: Path) -> AsyncIterator[tuple[Settings, FakeFcm, httpx.AsyncClient]]:
    """Settings with FCM configured, and a fake Google that records the pushes."""
    fake = FakeFcm()
    settings = make_settings(fcm_service_account_file=str(service_account_file(tmp_path)))
    fcm.forget_access_tokens()
    async with fake.client() as http:
        yield settings, fake, http


async def register_token(
    client: AsyncClient, headers: dict[str, str], token: str = TOKEN_A
) -> None:
    response = await client.put(
        "/v1/me/push-token", headers=headers, json={"token": token, "platform": "android"}
    )
    assert response.status_code == 204, response.text


async def no_quiet_hours(client: AsyncClient, headers: dict[str, str]) -> None:
    """Turn quiet hours off, so pushes go out whatever the time of day."""
    response = await client.put(
        "/v1/me/settings/notifications", headers=headers, json={"kinds": {}, "quiet_hours": None}
    )
    assert response.status_code == 200, response.text


async def test_push_goes_to_the_users_devices(
    client: AsyncClient,
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    push: tuple[Settings, FakeFcm, httpx.AsyncClient],
) -> None:
    settings, fake, http = push
    headers = await onboarded(client, "asha")
    await register_token(client, headers)
    await no_quiet_hours(client, headers)
    user = await user_id(client, headers)
    notification_id = await send(
        db_session,
        user,
        kind="tournament_round",
        action={"route": "/arena/t1", "params": {"round": 2}},
        time_critical=True,
    )

    await deliver(session_factory, redis, settings, http=http)

    assert fake.token_requests == 1
    [message] = fake.sent
    assert message == {
        "token": TOKEN_A,
        "notification": {"title": "Prize 1", "body": "You won coins."},
        "data": {
            "notification_id": str(notification_id),
            "kind": "tournament_round",
            "route": "/arena/t1",
            "params": '{"round":2}',
        },
        "android": {
            "priority": "HIGH",
            "notification": {"tag": str(notification_id), "channel_id": "tournaments"},
        },
        "apns": {"headers": {"apns-collapse-id": str(notification_id)}},
    }
    # The access token is reused for the next push.
    await send(db_session, user, 2)
    await deliver(session_factory, redis, settings, http=http)
    assert fake.token_requests == 1
    assert fake.sent[-1]["android"] == {
        "priority": "NORMAL",
        "notification": {"tag": fake.sent[-1]["data"]["notification_id"], "channel_id": "general"},
    }


async def test_push_respects_categories_quiet_hours_and_sign_out(
    client: AsyncClient,
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    push: tuple[Settings, FakeFcm, httpx.AsyncClient],
) -> None:
    settings, fake, http = push
    headers = await onboarded(client, "asha")
    await register_token(client, headers)
    user = await user_id(client, headers)
    now = utc_now()
    local = now.astimezone(IST)
    quiet = {
        "start": (local - timedelta(hours=1)).strftime("%H:%M"),
        "end": (local + timedelta(hours=1)).strftime("%H:%M"),
    }
    response = await client.put(
        "/v1/me/settings/notifications",
        headers=headers,
        json={"kinds": {"tournaments": False}, "quiet_hours": quiet},
    )
    assert response.status_code == 200, response.text

    await send(db_session, user, 1, kind="tournament_reminder")  # category off
    await send(db_session, user, 2, kind="friend_request")  # quiet hours
    await send(db_session, user, 3, kind="friend_request", time_critical=True)  # goes through
    result = await deliver(session_factory, redis, settings, http=http, now=now)

    assert result.delivered == 6
    assert [message["notification"]["title"] for message in fake.sent] == ["Prize 3"]

    # Signed out: the token is gone, and nothing more is pushed.
    assert (await client.post("/v1/auth/logout", headers=headers)).status_code == 204
    assert await db_session.scalar(select(func.count()).select_from(PushToken)) == 0
    await send(db_session, user, 4, kind="refund", time_critical=True)
    await deliver(session_factory, redis, settings, http=http, now=now)
    assert len(fake.sent) == 1


async def test_rejected_tokens_are_dropped_and_outages_retried(
    client: AsyncClient,
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    push: tuple[Settings, FakeFcm, httpx.AsyncClient],
) -> None:
    settings, fake, http = push
    headers = await onboarded(client, "asha")
    await register_token(client, headers, TOKEN_A)
    user = await user_id(client, headers)
    fake.responses[TOKEN_A] = lambda: httpx.Response(
        404,
        json={
            "error": {
                "status": "NOT_FOUND",
                "details": [{"errorCode": "UNREGISTERED"}],
            }
        },
    )
    await send(db_session, user, 1, time_critical=True)
    await deliver(session_factory, redis, settings, http=http)
    assert await db_session.scalar(select(func.count()).select_from(PushToken)) == 0

    await register_token(client, headers, TOKEN_B)
    fake.responses[TOKEN_B] = lambda: httpx.Response(503)
    notification_id = await send(db_session, user, 2, time_critical=True)
    result = await deliver(session_factory, redis, settings, http=http)

    assert result.retried == 1
    message = await db_session.scalar(
        select(OutboxMessage)
        .where(OutboxMessage.key == f"notify.push:{notification_id}")
        .execution_options(populate_existing=True)
    )
    assert message is not None
    assert message.delivered_at is None
    assert message.last_error == "PushError: send answered 503"
    assert await db_session.scalar(select(func.count()).select_from(PushToken)) == 1


async def test_push_is_off_without_a_service_account(
    client: AsyncClient,
    db_session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    settings: Settings,
) -> None:
    headers = await onboarded(client, "asha")
    await register_token(client, headers)
    await send(db_session, await user_id(client, headers))

    async def refuse(_request: httpx.Request) -> httpx.Response:
        raise AssertionError("no HTTP call expected")

    async with httpx.AsyncClient(transport=httpx.MockTransport(refuse)) as http:
        result = await deliver(session_factory, redis, settings, http=http)

    assert (result.delivered, result.retried) == (2, 0)
    config = (await client.get("/v1/config")).json()
    assert config["features"]["push"] is False


# --- Push tokens -----------------------------------------------------------------------------


async def test_a_device_has_one_token_and_a_token_one_owner(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    asha = await onboarded(client, "asha")
    await register_token(client, asha, TOKEN_A)
    await register_token(client, asha, TOKEN_B)  # the token rotated
    rows = (await db_session.execute(select(PushToken.token, PushToken.platform))).all()
    assert [tuple(row) for row in rows] == [(TOKEN_B, "android")]

    # Someone else signs in on the same phone.
    bea = await onboarded(client, "bea")
    await register_token(client, bea, TOKEN_B)
    owners = await db_session.scalars(select(PushToken.user_id))
    assert list(owners) == [await user_id(client, bea)]

    assert (await client.delete("/v1/me/push-token", headers=bea)).status_code == 204
    assert await db_session.scalar(select(func.count()).select_from(PushToken)) == 0


async def test_signing_in_again_on_the_device_drops_the_old_sessions_token(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    await register_token(client, headers)

    await dev_login(client, "asha@example.com", install_id="install-asha")

    assert await db_session.scalar(select(func.count()).select_from(PushToken)) == 0


@pytest.mark.parametrize(
    "body",
    [
        {"token": "short", "platform": "android"},
        {"token": TOKEN_A, "platform": "web"},
        {"token": "has spaces in it, sadly", "platform": "ios"},
    ],
)
async def test_push_token_validation(client: AsyncClient, body: dict[str, str]) -> None:
    login = await dev_login(client)
    response = await client.put(
        "/v1/me/push-token", headers=bearer(login["access_token"]), json=body
    )
    assert response.status_code == 422


# --- Settings --------------------------------------------------------------------------------


async def test_notification_settings_default_and_update(client: AsyncClient) -> None:
    headers = await onboarded(client, "asha")
    everything = {
        "invites": True,
        "tournaments": True,
        "friends": True,
        "missions": True,
        "streaks": True,
    }

    defaults = (await client.get("/v1/me/settings/notifications", headers=headers)).json()
    assert defaults == {"kinds": everything, "quiet_hours": {"start": "22:30", "end": "07:00"}}

    changed = await client.put(
        "/v1/me/settings/notifications",
        headers=headers,
        json={"kinds": {**everything, "streaks": False}},
    )
    assert changed.json() == {
        "kinds": {**everything, "streaks": False},
        "quiet_hours": {"start": "22:30", "end": "07:00"},  # left out: kept
    }
    off = await client.put(
        "/v1/me/settings/notifications",
        headers=headers,
        json={"kinds": everything, "quiet_hours": None},
    )
    assert off.json()["quiet_hours"] is None
    later = await client.put(
        "/v1/me/settings/notifications",
        headers=headers,
        json={"kinds": everything, "quiet_hours": {"start": "23:00", "end": "06:15"}},
    )
    assert later.json()["quiet_hours"] == {"start": "23:00", "end": "06:15"}
    assert (
        await client.get("/v1/me/settings/notifications", headers=headers)
    ).json() == later.json()


@pytest.mark.parametrize(
    "body",
    [
        {"kinds": {"party": True}},
        {"kinds": {}, "quiet_hours": {"start": "25:00", "end": "07:00"}},
        {"kinds": {}, "quiet_hours": {"start": "22:30"}},
        {"kinds": {"invites": "yes"}},
    ],
)
async def test_notification_settings_validation(
    client: AsyncClient, body: dict[str, object]
) -> None:
    headers = await onboarded(client, "asha")
    response = await client.put("/v1/me/settings/notifications", headers=headers, json=body)
    assert response.status_code == 422
