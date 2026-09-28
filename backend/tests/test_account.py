"""The account lifecycle: handle changes, deleting and restoring, erasure, reports and the
moderation ladder."""

import uuid
from datetime import timedelta
from typing import Any

import orjson
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from redis.asyncio.client import PubSub
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import iso_utc
from app.core.config import get_app_settings
from app.modules.analytics.models import AnalyticsEvent
from app.modules.auth.models import AuthIdentity, DeviceSession
from app.modules.economy.models import LedgerEntry
from app.modules.moderation.models import ModerationAction, UserReport
from app.modules.moderation.service import apply_moderation, in_shadow_pool, lift_expired
from app.modules.notifications.models import Notification
from app.modules.social.models import Friendship
from app.modules.users import deletion
from app.modules.users.models import User, UserSettings
from tests.helpers import FakeClock, bearer, dev_login, device, google_id_token
from tests.social_helpers import Player, befriend, friend_ids, player


async def next_message(pubsub: PubSub) -> dict[str, Any] | None:
    """The first published message (skipping the subscription notice), then unsubscribe."""
    try:
        for _ in range(20):
            message = await pubsub.get_message(ignore_subscribe_messages=True, timeout=0.1)
            if message is not None:
                return message
        return None
    finally:
        await pubsub.aclose()


# --- Handle changes ------------------------------------------------------------------------------


async def test_the_handle_changes_once_every_30_days(client: AsyncClient, clock: FakeClock) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    changed = await client.patch("/v1/me", json={"handle": "Asha_New"}, headers=asha.headers)
    same = await client.patch("/v1/me", json={"handle": "asha_new"}, headers=asha.headers)
    too_soon = await client.patch("/v1/me", json={"handle": "asha_2"}, headers=asha.headers)
    taken = await client.patch("/v1/me", json={"handle": "asha_new"}, headers=ravi.headers)
    reserved = await client.patch("/v1/me", json={"handle": "admin"}, headers=ravi.headers)

    assert changed.status_code == 200
    assert changed.json()["handle"] == "asha_new"
    next_change = clock() + timedelta(days=30)
    assert changed.json()["next_handle_change_at"] == iso_utc(next_change)
    assert same.status_code == 200  # unchanged: not a change
    assert too_soon.status_code == 409
    assert too_soon.json()["error"]["code"] == "HANDLE_CHANGE_TOO_SOON"
    assert too_soon.json()["error"]["details"] == {"next_change_at": iso_utc(next_change)}
    assert (taken.status_code, taken.json()["error"]["code"]) == (409, "HANDLE_TAKEN")
    assert reserved.status_code == 422

    clock.advance(days=30)
    headers = bearer((await dev_login(client, "asha@example.com", install_id="x"))["access_token"])
    later = await client.patch("/v1/me", json={"handle": "asha_2"}, headers=headers)
    assert later.json()["handle"] == "asha_2"


async def test_the_handle_is_chosen_at_onboarding_first(client: AsyncClient) -> None:
    headers = bearer((await dev_login(client, "new@example.com"))["access_token"])

    response = await client.patch("/v1/me", json={"handle": "brand_new"}, headers=headers)

    assert (response.status_code, response.json()["error"]["code"]) == (
        409,
        "ONBOARDING_REQUIRED",
    )


# --- Deleting and restoring --------------------------------------------------------------------


async def delete_account(client: AsyncClient, who: Player, **proof: Any) -> Any:
    return await client.post(
        "/v1/me/delete",
        json={"confirm": "DELETE", "proof": proof or {"provider": "dev"}},
        headers=who.headers,
    )


async def test_deleting_hides_the_account_and_ends_every_session(
    client: AsyncClient, db_session: AsyncSession, redis: Redis, clock: FakeClock
) -> None:
    asha, ravi, meera = [await player(client, name) for name in ("asha", "ravi", "meera")]
    await befriend(client, asha, ravi)
    pending = await client.post(
        "/v1/friend-requests", json={"user_id": asha.uid}, headers=meera.headers
    )
    hooked: list[uuid.UUID] = []

    async def hook(_db: object, user_id: uuid.UUID, _now: object) -> None:
        hooked.append(user_id)

    deletion.on_account_deleted(hook)
    pubsub = redis.pubsub()
    await pubsub.subscribe(f"ctl:u:{asha.uid}")
    try:
        response = await delete_account(client, asha)
    finally:
        deletion._DELETED_HOOKS.remove(hook)
    message = await next_message(pubsub)

    assert response.status_code == 202
    assert response.json() == {
        "status": "pending_deletion",
        "restore_until": iso_utc(clock() + timedelta(days=7)),
    }
    assert hooked == [asha.id]
    assert message is not None
    assert orjson.loads(message["data"]) == {"type": "revoke", "reason": "account_deleted"}
    signed_out = await client.get("/v1/me", headers=asha.headers)
    assert signed_out.status_code == 401
    assert signed_out.json()["error"]["details"] == {"reason": "account_deleted"}
    # Hidden from everyone, but the friendship is kept for a restore.
    assert await friend_ids(client, ravi) == []
    assert (await client.get(f"/v1/users/{asha.handle}", headers=ravi.headers)).status_code == 404
    search = await client.get(f"/v1/users/search?q={asha.handle}", headers=ravi.headers)
    assert search.json()["items"] == []
    assert await db_session.scalar(select(func.count()).select_from(Friendship)) == 1
    withdrawn = await client.get("/v1/me/friend-requests", headers=meera.headers)
    assert withdrawn.json()["outgoing"] == []
    assert pending.status_code == 201


async def test_a_restricted_session_can_only_restore_or_sign_out(
    client: AsyncClient, clock: FakeClock
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    await befriend(client, asha, ravi)
    await delete_account(client, asha)

    login = await dev_login(client, "asha@example.com", install_id="install-asha")
    headers = bearer(login["access_token"])
    me = await client.get("/v1/me", headers=headers)
    blocked = await client.get("/v1/me/friends", headers=headers)
    refreshed = await client.post(
        "/v1/auth/refresh", json={"refresh_token": login["refresh_token"]}
    )

    assert login["user"]["status"] == "pending_deletion"
    assert login["user"]["restore_until"] == iso_utc(clock() + timedelta(days=7))
    assert me.status_code == 200
    assert me.json()["status"] == "pending_deletion"
    assert (blocked.status_code, blocked.json()["error"]["code"]) == (401, "ACCOUNT_CLOSED")
    assert refreshed.status_code == 200  # the restricted session lives on

    restored = await client.post("/v1/me/restore", headers=headers)
    assert restored.status_code == 200
    assert restored.json()["status"] == "active"
    assert restored.json()["restore_until"] is None
    # Everything comes back exactly: the same session now works everywhere, friends included.
    assert await friend_ids(client, Player(asha.id, asha.handle, headers, login)) == [ravi.uid]
    assert await friend_ids(client, ravi) == [asha.uid]
    assert (await client.get(f"/v1/users/{asha.handle}", headers=ravi.headers)).status_code == 200


async def test_the_restricted_session_can_sign_out(client: AsyncClient) -> None:
    asha = await player(client, "asha")
    await delete_account(client, asha)
    headers = bearer((await dev_login(client, "asha@example.com"))["access_token"])

    response = await client.post("/v1/auth/logout", headers=headers)

    assert response.status_code == 204


async def test_after_seven_days_there_is_no_way_back(
    client: AsyncClient, db_session: AsyncSession, redis: Redis, clock: FakeClock
) -> None:
    asha = await player(client, "asha")
    await delete_account(client, asha)
    login = await dev_login(client, "asha@example.com")
    # The window closes while the restricted session is still signed in.
    user = await db_session.get_one(User, asha.id)
    user.restore_until = clock() + timedelta(minutes=1)
    await db_session.commit()
    await redis.delete(f"authz:{asha.uid}")
    clock.advance(minutes=2)

    me = await client.get("/v1/me", headers=bearer(login["access_token"]))
    sign_in = await client.post(
        "/v1/auth/dev-login", json={"email": "asha@example.com", "device": device()}
    )

    assert (me.status_code, me.json()["error"]["code"]) == (401, "ACCOUNT_CLOSED")
    assert (sign_in.status_code, sign_in.json()["error"]["code"]) == (403, "ACCOUNT_CLOSED")


async def test_restore_is_refused_once_the_window_closes(
    db_session: AsyncSession, redis: Redis, client: AsyncClient, clock: FakeClock
) -> None:
    asha = await player(client, "asha")
    await delete_account(client, asha)

    with pytest.raises(Exception, match="too late") as raised:
        await deletion.restore_account(db_session, redis, asha.id, now=clock() + timedelta(days=8))

    assert getattr(raised.value, "code", None) == "RESTORE_EXPIRED"


async def test_google_proof_must_be_fresh_and_for_this_account(
    client: AsyncClient, clock: FakeClock
) -> None:
    signed_in = await client.post(
        "/v1/auth/google",
        json={"id_token": google_id_token(now=clock(), subject="sub-asha"), "device": device()},
    )
    headers = bearer(signed_in.json()["access_token"])
    asha = Player(uuid.UUID(signed_in.json()["user"]["id"]), "", headers, signed_in.json())

    stale = await delete_account(
        client,
        asha,
        provider="google",
        id_token=google_id_token(now=clock() - timedelta(minutes=30), subject="sub-asha"),
    )
    other = await delete_account(
        client,
        asha,
        provider="google",
        id_token=google_id_token(now=clock(), subject="sub-someone-else"),
    )
    missing = await delete_account(client, asha, provider="google")
    token = google_id_token(now=clock(), subject="sub-asha")
    good = await delete_account(client, asha, provider="google", id_token=token)

    for response, reason in (
        (stale, "ID_TOKEN_EXPIRED"),
        (other, "WRONG_ACCOUNT"),
        (missing, "PROOF_NOT_ACCEPTED"),
    ):
        assert response.status_code == 403
        assert response.json()["error"]["code"] == "REAUTH_REQUIRED"
        assert response.json()["error"]["details"] == {"reason": reason}
    assert good.status_code == 202


async def test_deleting_needs_the_confirmation_word(client: AsyncClient) -> None:
    asha = await player(client, "asha")

    response = await client.post(
        "/v1/me/delete",
        json={"confirm": "delete", "proof": {"provider": "dev"}},
        headers=asha.headers,
    )

    assert response.status_code == 422


async def test_dev_proof_needs_dev_login(client: AsyncClient, app: Any, settings: Any) -> None:
    asha = await player(client, "asha")
    settings_without_dev = settings.model_copy(update={"dev_login_enabled": False})
    app.dependency_overrides[get_app_settings] = lambda: settings_without_dev
    try:
        response = await delete_account(client, asha)
    finally:
        del app.dependency_overrides[get_app_settings]

    assert response.json()["error"]["details"] == {"reason": "PROOF_NOT_ACCEPTED"}


async def test_erasure_after_30_days(
    client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    await befriend(client, asha, ravi)
    await client.put(
        "/v1/me/settings/privacy",
        json={
            "friend_requests": "nobody",
            "challenges": "nobody",
            "presence": "nobody",
            "public_boards": False,
        },
        headers=asha.headers,
    )
    ledger_before = await db_session.scalar(
        select(func.count()).where(LedgerEntry.user_id == asha.id)
    )
    await delete_account(client, asha)

    assert await deletion.erase_due(db_session, now=clock() + timedelta(days=29)) == 0
    assert await deletion.erase_due(db_session, now=clock() + timedelta(days=30)) == 1

    user = await db_session.get_one(User, asha.id, populate_existing=True)
    assert (user.status, user.handle, user.email, user.birth_year) == (
        "deleted",
        None,
        None,
        None,
    )
    assert user.display_name == deletion.ERASED_NAME
    for model, column in (
        (AuthIdentity, AuthIdentity.user_id),
        (DeviceSession, DeviceSession.user_id),
        (UserSettings, UserSettings.user_id),
        (Notification, Notification.user_id),
        (AnalyticsEvent, AnalyticsEvent.user_id),
    ):
        count = await db_session.scalar(select(func.count()).where(column == asha.id))
        assert count == 0, model.__name__
    assert await db_session.scalar(select(func.count()).select_from(Friendship)) == 0
    # Coin ledger rows stay, under the tombstone id.
    assert ledger_before
    assert (
        await db_session.scalar(select(func.count()).where(LedgerEntry.user_id == asha.id))
        == ledger_before
    )
    # The same account can sign up again, as a new player.
    clock.advance(days=30)
    again = await dev_login(client, "asha@example.com")
    assert again["is_new_user"] is True
    assert again["user"]["id"] != asha.uid


# --- Reports and moderation --------------------------------------------------------------------


async def test_reports_are_queued_once(client: AsyncClient, db_session: AsyncSession) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")
    body = {"user_id": ravi.uid, "reason": "offensive_name", "note": "  rude name  "}

    first = await client.post("/v1/reports", json=body, headers=asha.headers)
    again = await client.post("/v1/reports", json=body, headers=asha.headers)
    in_match = await client.post(
        "/v1/reports",
        json={"user_id": ravi.uid, "reason": "cheating", "match_id": str(uuid.uuid4())},
        headers=asha.headers,
    )
    own = await client.post(
        "/v1/reports", json={"user_id": asha.uid, "reason": "other"}, headers=asha.headers
    )
    bad = await client.post(
        "/v1/reports", json={"user_id": ravi.uid, "reason": "spam"}, headers=asha.headers
    )

    assert (first.status_code, again.status_code, in_match.status_code) == (202, 202, 202)
    reports = list(await db_session.scalars(select(UserReport).order_by(UserReport.created_at)))
    assert [(r.reporter_id, r.reported_id, r.reason, r.note) for r in reports] == [
        (asha.id, ravi.id, "offensive_name", "rude name"),
        (asha.id, ravi.id, "cheating", None),
    ]
    assert own.status_code == 422
    assert bad.status_code == 422


async def test_reports_are_rate_limited(client: AsyncClient) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    statuses = [
        (
            await client.post(
                "/v1/reports",
                json={"user_id": ravi.uid, "reason": "cheating", "match_id": str(uuid.uuid4())},
                headers=asha.headers,
            )
        ).status_code
        for _ in range(11)
    ]

    assert statuses == [202] * 10 + [429]


async def test_a_ban_ends_everything_at_once(
    client: AsyncClient, db_session: AsyncSession, redis: Redis, clock: FakeClock
) -> None:
    asha, mod = await player(client, "asha"), await player(client, "kiran")
    pubsub = redis.pubsub()
    await pubsub.subscribe(f"ctl:u:{asha.uid}")

    until = clock() + timedelta(days=3)
    await apply_moderation(
        db_session, redis, asha.id, "temp_ban", reason="cheating", until=until, by=mod.id,
        now=clock(),
    )  # fmt: skip
    message = await next_message(pubsub)

    me = await client.get("/v1/me", headers=asha.headers)
    refreshed = await client.post(
        "/v1/auth/refresh", json={"refresh_token": asha.login["refresh_token"]}
    )
    assert (me.status_code, me.json()["error"]["code"]) == (403, "ACCOUNT_BANNED")
    assert me.json()["error"]["details"]["until"] == iso_utc(until)
    assert refreshed.json()["error"]["code"] == "ACCOUNT_BANNED"
    assert message is not None
    assert orjson.loads(message["data"]) == {"type": "ban", "reason": "cheating"}
    sessions = await db_session.scalars(
        select(DeviceSession.revoke_reason).where(DeviceSession.user_id == asha.id)
    )
    assert set(sessions) == {"banned"}
    assert await db_session.scalar(select(func.count()).where(Notification.user_id == asha.id)) == 0

    # When the time is up the job lifts it; signing in works again.
    assert await lift_expired(db_session, redis, now=until + timedelta(seconds=1)) == 1
    clock.advance(days=3, seconds=2)
    assert (await dev_login(client, "asha@example.com"))["user"]["id"] == asha.uid


async def test_restrictions_warnings_and_name_resets(
    client: AsyncClient, db_session: AsyncSession, redis: Redis, clock: FakeClock
) -> None:
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    await apply_moderation(db_session, redis, asha.id, "warn", reason="abuse", now=clock())
    await apply_moderation(
        db_session, redis, asha.id, "restrict_social", reason="abuse",
        until=clock() + timedelta(days=1), now=clock(),
    )  # fmt: skip
    await apply_moderation(
        db_session, redis, asha.id, "reset_name", reason="offensive_name", now=clock()
    )
    await apply_moderation(
        db_session, redis, asha.id, "shadow_pool", reason="cheating", now=clock()
    )

    me = (await client.get("/v1/me", headers=asha.headers)).json()
    ask = await client.post("/v1/friend-requests", json={"user_id": ravi.uid}, headers=asha.headers)
    inbox = list(
        await db_session.scalars(select(Notification.title).where(Notification.user_id == asha.id))
    )

    assert me["status"] == "restricted"
    assert me["display_name"] == "Player"
    assert me["handle"].startswith("player_")
    assert me["next_handle_change_at"] is None
    assert (ask.status_code, ask.json()["error"]["details"]) == (403, {"reason": "restricted"})
    assert inbox == [
        "A warning about your account",
        "Friend features are paused",
        "Your name was reset",
    ]  # the shadow pool is silent
    assert await in_shadow_pool(db_session, asha.id, now=clock())
    assert not await in_shadow_pool(db_session, ravi.id, now=clock())
    actions = await db_session.scalar(
        select(func.count()).where(ModerationAction.user_id == asha.id)
    )
    assert actions == 4

    assert await lift_expired(db_session, redis, now=clock() + timedelta(days=2)) == 1
    assert (await db_session.get_one(User, asha.id, populate_existing=True)).status == "active"


async def test_moderation_rejects_bad_durations(
    client: AsyncClient, db_session: AsyncSession, redis: Redis, clock: FakeClock
) -> None:
    asha = await player(client, "asha")

    with pytest.raises(ValueError, match="temporary ban"):
        await apply_moderation(db_session, redis, asha.id, "temp_ban", reason="other", now=clock())
    with pytest.raises(ValueError, match="permanent ban"):
        await apply_moderation(
            db_session, redis, asha.id, "perm_ban", reason="other",
            until=clock() + timedelta(days=1), now=clock(),
        )  # fmt: skip


async def test_account_endpoints_are_the_callers_own(client: AsyncClient) -> None:
    """Nothing in the account API names another player: deleting or restoring always acts on
    the signed-in account."""
    asha, ravi = await player(client, "asha"), await player(client, "ravi")

    await delete_account(client, asha)
    restore_by_ravi = await client.post("/v1/me/restore", headers=ravi.headers)

    assert restore_by_ravi.json()["id"] == ravi.uid  # a no-op on Ravi's active account
    assert restore_by_ravi.json()["status"] == "active"
    asha_login = await dev_login(client, "asha@example.com")
    assert asha_login["user"]["status"] == "pending_deletion"
