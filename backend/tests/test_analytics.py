"""Analytics: the app's allowlisted events, server-side ``track``, minors, the opt-out and
retention; and the feedback form."""

import uuid
from datetime import timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST, utc_now
from app.modules.analytics.events import CLIENT_EVENTS, SERVER_EVENTS
from app.modules.analytics.models import AnalyticsEvent
from app.modules.analytics.service import SALT_PREFIX, clean_props, purge_analytics, track
from app.modules.feedback.models import Feedback
from app.modules.system.models import AppConfig
from tests.helpers import FakeClock
from tests.platform_helpers import onboarded, user_id


def event(name: str = "leaderboard_viewed", **overrides: Any) -> dict[str, Any]:
    return {"name": name, "props": {"board": "weekly_xp"}, "at": utc_now().isoformat(), **overrides}


async def stored(db: AsyncSession, **where: Any) -> list[AnalyticsEvent]:
    statement = select(AnalyticsEvent).order_by(AnalyticsEvent.at, AnalyticsEvent.id)
    for column, value in where.items():
        statement = statement.where(getattr(AnalyticsEvent, column) == value)
    return list(await db.scalars(statement))


def test_allowlists_cover_the_tracking_plan() -> None:
    assert {"leaderboard_viewed", "review_opened", "notification_opened"} <= CLIENT_EVENTS
    assert {"sign_in", "onboarding_done", "match_finished", "t_registered"} <= SERVER_EVENTS
    assert not CLIENT_EVENTS & SERVER_EVENTS


def test_props_keep_small_scalars_only() -> None:
    props = {"a": "x" * 100, "b": 1, "c": 1.5, "d": True, "e": None, "f": {"nested": 1}, "g": [1]}
    assert clean_props(props) == {"a": "x" * 64, "b": 1, "c": 1.5, "d": True, "e": None}
    assert clean_props({"nan": float("nan")}) == {}
    assert len(clean_props({f"k{n}": n for n in range(30)})) == 10


async def test_the_app_posts_allowlisted_events(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)
    now = utc_now()

    response = await client.post(
        "/v1/events",
        headers=headers,
        json={
            "events": [
                event(),
                event("notification_opened", props={"kind": "prize", "source": "push"}),
                event("made_up_event"),  # not allowlisted: dropped
                event(at=(now - timedelta(days=8)).isoformat()),  # too old: dropped
                event(at=(now + timedelta(hours=1)).isoformat()),  # in the future: dropped
            ]
        },
    )

    assert response.status_code == 202
    assert response.json() == {"accepted": 2}
    rows = await stored(db_session, source="client")
    assert [(row.name, row.user_id, row.is_minor) for row in rows] == [
        ("leaderboard_viewed", user, False),
        ("notification_opened", user, False),
    ]
    assert rows[1].props == {"kind": "prize", "source": "push"}
    assert rows[0].ist_day == rows[0].at.astimezone(IST).date()
    assert rows[0].session_key is not None
    assert len(rows[0].session_key) == 24
    assert rows[0].session_key == rows[1].session_key


@pytest.mark.parametrize(
    "body",
    [
        {"events": []},
        {"events": [event()] * 21},
        {"events": [event(name="Bad Name")]},
        {"events": [event(props={"nested": {"a": 1}})]},
        {"events": [event(props={"list": [1]})]},
        {"events": [event(props={"long": "x" * 65})]},
        {"events": [event(props={f"k{n}": n for n in range(11)})]},
        {"events": [event(props={"Bad-Key": 1})]},
        {"events": [event(at="2026-09-28T10:00:00")]},
    ],
)
async def test_event_batches_are_validated(client: AsyncClient, body: dict[str, Any]) -> None:
    headers = await onboarded(client, "asha")
    response = await client.post("/v1/events", headers=headers, json=body)
    assert response.status_code == 422, response.text


async def test_minors_are_stored_without_a_user_id(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    this_year = clock().astimezone(IST).year
    headers = await onboarded(client, "kid", birth_year=this_year - 16)
    user = await user_id(client, headers)

    response = await client.post("/v1/events", headers=headers, json={"events": [event()]})

    assert response.json() == {"accepted": 1}
    [row] = await stored(db_session, source="client")
    assert (row.user_id, row.is_minor) == (None, True)
    assert row.session_key is not None
    # Server events too, including onboarding_done.
    [done] = await stored(db_session, name="onboarding_done")
    assert (done.user_id, done.is_minor, done.session_key) == (None, True, None)
    assert await track(db_session, "level_up", user, {"level": 3}, now=utc_now()) is True
    [level] = await stored(db_session, name="level_up")
    assert (level.user_id, level.props) == (None, {"level": 3})


async def test_session_keys_change_daily_and_salts_expire(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    now = utc_now()
    await client.post(
        "/v1/events",
        headers=headers,
        json={"events": [event(), event(at=(now - timedelta(days=2)).isoformat())]},
    )
    rows = await stored(db_session, source="client")
    assert rows[0].session_key != rows[1].session_key

    await purge_analytics(db_session, now=now)
    salts = await db_session.scalars(
        select(AppConfig.key).where(AppConfig.key.startswith(SALT_PREFIX))
    )
    assert list(salts) == [f"{SALT_PREFIX}{now.astimezone(IST).date().isoformat()}"]


async def test_opting_out_stops_all_recording(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)
    assert (await client.get("/v1/me/settings/app", headers=headers)).json() == {"analytics": True}

    response = await client.put("/v1/me/settings/app", headers=headers, json={"analytics": False})

    assert response.json() == {"analytics": False}
    assert (await client.get("/v1/me/settings/app", headers=headers)).json() == {"analytics": False}
    posted = await client.post("/v1/events", headers=headers, json={"events": [event()]})
    assert posted.json() == {"accepted": 0}
    assert await track(db_session, "level_up", user, now=utc_now()) is False
    assert await stored(db_session, source="client") == []
    assert await stored(db_session, name="level_up") == []


async def test_server_events_record_adults_with_their_id(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)

    [done] = await stored(db_session, name="onboarding_done")
    assert (done.user_id, done.props, done.source) == (user, {"goal": "neet"}, "server")
    assert await track(db_session, "match_finished", None, {"result": "win"}, now=utc_now())
    with pytest.raises(ValueError, match="unknown analytics event"):
        await track(db_session, "leaderboard_viewed", user, now=utc_now())


async def test_events_are_kept_for_180_days(client: AsyncClient, db_session: AsyncSession) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)
    await track(db_session, "level_up", user, now=utc_now() - timedelta(days=181))
    count = select(func.count()).select_from(AnalyticsEvent)
    before = await db_session.scalar(count)

    assert await purge_analytics(db_session, now=utc_now()) == 1
    assert await db_session.scalar(count) == (before or 0) - 1


# --- Feedback --------------------------------------------------------------------------------


async def test_feedback_is_stored(client: AsyncClient, db_session: AsyncSession) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)

    response = await client.post(
        "/v1/feedback",
        headers={**headers, "X-App-Build": "42"},
        json={
            "kind": "coins",
            "message": "  My prize didn't arrive.  ",
            "request_id": "req-12345678",
        },
    )

    assert response.status_code == 202
    [row] = await db_session.scalars(select(Feedback))
    assert (row.user_id, row.kind, row.message, row.request_id, row.app_build, row.status) == (
        user,
        "coins",
        "My prize didn't arrive.",
        "req-12345678",
        42,
        "open",
    )


@pytest.mark.parametrize(
    "body",
    [
        {"kind": "praise", "message": "hi"},
        {"kind": "idea", "message": "   "},
        {"kind": "idea", "message": "x" * 2001},
        {"kind": "problem", "message": "broken", "request_id": "bad id!"},
        {"kind": "problem"},
    ],
)
async def test_feedback_validation(client: AsyncClient, body: dict[str, Any]) -> None:
    headers = await onboarded(client, "asha")
    response = await client.post("/v1/feedback", headers=headers, json=body)
    assert response.status_code == 422


async def test_feedback_is_rate_limited(client: AsyncClient) -> None:
    headers = await onboarded(client, "asha")
    body = {"kind": "idea", "message": "More chemistry please", "request_id": None}
    statuses = [
        (await client.post("/v1/feedback", headers=headers, json=body)).status_code
        for _ in range(6)
    ]
    assert statuses == [202] * 5 + [429]
    assert (await client.post("/v1/feedback", json=body)).status_code == 401


async def test_feedback_ids_are_uuid7(client: AsyncClient, db_session: AsyncSession) -> None:
    headers = await onboarded(client, "asha")
    await client.post("/v1/feedback", headers=headers, json={"kind": "idea", "message": "Hi"})
    row = await db_session.scalar(select(Feedback))
    assert row is not None
    assert isinstance(row.id, uuid.UUID)
    assert row.id.version == 7
