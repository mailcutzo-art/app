"""Sign-in, sessions, token refresh and request authentication, through the HTTP API."""

import logging
import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

import pytest
from fastapi import APIRouter, Depends, FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import JwtKeys
from app.core.security import AuthContext, require_role
from app.core.tokens import issue_access_token
from app.main_api import create_app
from app.modules.auth.models import AuthIdentity, DeviceSession, RefreshToken
from app.modules.users.models import Role, User
from tests.helpers import (
    FakeClock,
    bearer,
    dev_login,
    device,
    ed25519_pem_pair,
    google_id_token,
    log_events,
    make_settings,
    serve,
)

router = APIRouter(prefix="/test")


@router.get("/admin", dependencies=[Depends(require_role(Role.ADMIN))])
async def admin_only() -> dict[str, bool]:
    return {"ok": True}


@router.get("/moderator")
async def moderator_only(
    auth: Annotated[AuthContext, Depends(require_role(Role.MODERATOR))],
) -> dict[str, str]:
    return {"user_id": str(auth.user_id)}


@pytest.fixture
def app(app: FastAPI) -> FastAPI:
    app.include_router(router)
    return app


async def google_sign_in(
    client: AsyncClient, clock: FakeClock, *, install_id: str = "install-1", **claims: Any
) -> Any:
    token = google_id_token(now=clock.now, **claims)
    return await client.post(
        "/v1/auth/google", json={"id_token": token, "device": device(install_id)}
    )


async def set_user(db: AsyncSession, redis: Redis, user_id: str, **values: Any) -> None:
    """Change the user as an admin tool would, including dropping the authz cache."""
    await db.execute(update(User).where(User.id == uuid.UUID(user_id)).values(**values))
    await redis.delete(f"authz:{user_id}")


# --- Google sign-in ----------------------------------------------------------------------


async def test_google_sign_in_creates_the_user_and_a_session(
    client: AsyncClient, clock: FakeClock
) -> None:
    response = await google_sign_in(client, clock)

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {
        "access_token", "access_expires_in", "refresh_token", "user", "is_new_user"
    }  # fmt: skip
    assert body["access_expires_in"] == 900
    assert body["is_new_user"] is True
    user = body["user"]
    assert user == {
        "id": user["id"],
        "handle": None,
        "display_name": "Asha Verma",
        "email": "asha@example.com",  # private to the player: "Signed in as ..."
        "avatar": {"tone": "lime", "symbol": "rocket"},
        "goal": None,
        "birth_year": None,
        "is_minor": False,
        "onboarding_completed": False,
        "roles": ["user"],
        "created_at": user["created_at"],
    }
    me = await client.get("/v1/me", headers=bearer(body["access_token"]))
    assert me.status_code == 200
    assert me.json() == user


async def test_returning_users_are_found_by_subject(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    first = (await google_sign_in(client, clock)).json()
    again = await google_sign_in(client, clock, install_id="install-2", email="asha@new.example")

    assert again.json()["is_new_user"] is False
    assert again.json()["user"]["id"] == first["user"]["id"]
    user = await db_session.get_one(User, uuid.UUID(first["user"]["id"]))
    assert user.email == "asha@new.example"  # the latest verified email is kept


async def test_users_are_never_matched_by_email(client: AsyncClient, clock: FakeClock) -> None:
    first = (await google_sign_in(client, clock, subject="sub-a")).json()
    second = (await google_sign_in(client, clock, subject="sub-b")).json()

    assert second["is_new_user"] is True
    assert second["user"]["id"] != first["user"]["id"]


async def test_google_tokens_are_single_use(client: AsyncClient, clock: FakeClock) -> None:
    token = google_id_token(now=clock.now)
    body = {"id_token": token, "device": device()}

    assert (await client.post("/v1/auth/google", json=body)).status_code == 200
    replay = await client.post("/v1/auth/google", json=body)

    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "TOKEN_REPLAYED"


@pytest.mark.parametrize(
    ("claims", "code"),
    [
        ({"aud": "another-app"}, "INVALID_ID_TOKEN"),
        ({"iss": "https://accounts.example"}, "INVALID_ID_TOKEN"),
        ({"key_id": "unknown-kid"}, "INVALID_ID_TOKEN"),
        ({"iat": 0, "exp": 3600}, "ID_TOKEN_EXPIRED"),
        ({"email_verified": False}, "EMAIL_NOT_VERIFIED"),
    ],
)
async def test_invalid_google_tokens_are_401(
    client: AsyncClient, clock: FakeClock, claims: dict[str, Any], code: str
) -> None:
    response = await google_sign_in(client, clock, **claims)

    assert response.status_code == 401
    assert response.json()["error"]["code"] == code


async def test_stale_google_token_is_401(client: AsyncClient, clock: FakeClock) -> None:
    token = google_id_token(now=clock.now)
    clock.advance(minutes=11)

    response = await client.post("/v1/auth/google", json={"id_token": token, "device": device()})

    assert response.json()["error"]["code"] == "ID_TOKEN_EXPIRED"


@pytest.mark.parametrize(
    ("claims", "display_name"),
    [
        ({"name": None, "email": "rahul.sharma+quiz@example.com"}, "Rahul Sharma"),
        ({"name": "fuck this", "email": "neha_k@example.com"}, "Neha K"),
        ({"name": "x", "email": "a@example.com"}, "Player"),
    ],
)
async def test_new_users_get_an_acceptable_display_name(
    client: AsyncClient, clock: FakeClock, claims: dict[str, Any], display_name: str
) -> None:
    body = (await google_sign_in(client, clock, **claims)).json()

    assert body["user"]["display_name"] == display_name


async def test_google_sign_in_is_503_without_client_ids(settings: Any) -> None:
    app = create_app(make_settings(google_client_ids=""))
    async with serve(app) as client:
        response = await client.post(
            "/v1/auth/google", json={"id_token": "x.y.z", "device": device()}
        )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "GOOGLE_SIGN_IN_UNAVAILABLE"


async def test_sign_in_is_rate_limited_per_ip(client: AsyncClient) -> None:
    body = {"id_token": "not-a-token", "device": device()}
    statuses = [(await client.post("/v1/auth/google", json=body)).status_code for _ in range(21)]

    assert statuses[:20] == [401] * 20
    assert statuses[20] == 429


# --- Dev login ---------------------------------------------------------------------------


async def test_dev_login_creates_then_reuses_the_account(client: AsyncClient) -> None:
    created = await client.post(
        "/v1/auth/dev-login",
        json={"email": "Bot.One@Example.com", "display_name": "Bot One", "device": device()},
    )
    again = await dev_login(client, "bot.one@example.com", install_id="install-2")

    assert created.json()["is_new_user"] is True
    assert created.json()["user"]["display_name"] == "Bot One"
    assert again["is_new_user"] is False
    assert again["user"]["id"] == created.json()["user"]["id"]


async def test_dev_login_blank_name_uses_the_email(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/auth/dev-login",
        json={"email": "priya.nair@example.com", "display_name": "  ", "device": device()},
    )

    assert response.json()["user"]["display_name"] == "Priya Nair"


async def test_dev_login_validates_its_fields(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/auth/dev-login",
        json={"email": "nope", "display_name": "visit www.spam.com", "device": {"build": -1}},
    )

    assert response.status_code == 422
    fields = response.json()["error"]["details"]["fields"]
    assert fields["email"] == "Enter a valid email address."
    assert fields["display_name"] == "Names can't include links."
    assert "device" in fields


async def test_dev_login_is_404_when_disabled() -> None:
    app = create_app(make_settings(dev_login_enabled=False))
    async with serve(app) as client:
        response = await client.post(
            "/v1/auth/dev-login", json={"email": "a@example.com", "device": device()}
        )

    assert response.status_code == 404


# --- Device sessions ---------------------------------------------------------------------


async def test_signing_in_again_on_an_install_ends_its_previous_session(
    client: AsyncClient,
) -> None:
    first = await dev_login(client)
    second = await dev_login(client)

    stale = await client.get("/v1/me", headers=bearer(first["access_token"]))
    refreshed = await client.post(
        "/v1/auth/refresh", json={"refresh_token": first["refresh_token"]}
    )
    sessions = await client.get("/v1/me/sessions", headers=bearer(second["access_token"]))

    assert stale.json()["error"]["code"] == "SESSION_REVOKED"
    assert stale.json()["error"]["details"] == {"reason": "replaced"}
    assert refreshed.json()["error"]["code"] == "INVALID_REFRESH_TOKEN"
    assert len(sessions.json()) == 1


async def test_at_most_five_sessions_the_least_recently_used_ends(
    client: AsyncClient, clock: FakeClock
) -> None:
    logins = []
    for index in range(6):
        logins.append(await dev_login(client, install_id=f"install-{index}"))
        clock.advance(minutes=1)

    oldest = await client.get("/v1/me", headers=bearer(logins[0]["access_token"]))
    newest = await client.get("/v1/me/sessions", headers=bearer(logins[5]["access_token"]))

    assert oldest.json()["error"]["code"] == "SESSION_REVOKED"
    assert oldest.json()["error"]["details"] == {"reason": "session_limit"}
    assert len(newest.json()) == 5


async def test_session_list_marks_the_current_session(
    client: AsyncClient, clock: FakeClock
) -> None:
    await dev_login(client, install_id="phone")
    clock.advance(minutes=1)
    tablet = await dev_login(client, install_id="tablet")

    response = await client.get("/v1/me/sessions", headers=bearer(tablet["access_token"]))

    sessions = response.json()
    assert [s["current"] for s in sessions] == [True, False]  # most recently active first
    assert set(sessions[0]) == {
        "id", "platform", "app_version", "created_at", "last_seen_at", "current"
    }  # fmt: skip
    assert sessions[0]["platform"] == "android"


async def test_ending_another_session(client: AsyncClient) -> None:
    phone = await dev_login(client, install_id="phone")
    tablet = await dev_login(client, install_id="tablet")
    sessions = (await client.get("/v1/me/sessions", headers=bearer(phone["access_token"]))).json()
    tablet_id = next(s["id"] for s in sessions if not s["current"])

    ended = await client.delete(
        f"/v1/me/sessions/{tablet_id}", headers=bearer(phone["access_token"])
    )
    again = await client.delete(
        f"/v1/me/sessions/{tablet_id}", headers=bearer(phone["access_token"])
    )

    assert ended.status_code == 204
    assert again.status_code == 404
    locked_out = await client.get("/v1/me", headers=bearer(tablet["access_token"]))
    assert locked_out.json()["error"]["code"] == "SESSION_REVOKED"
    assert locked_out.json()["error"]["details"] == {"reason": "signed_out"}


async def test_sessions_of_other_users_cannot_be_ended(client: AsyncClient) -> None:
    mine = await dev_login(client, "me@example.com")
    theirs = await dev_login(client, "them@example.com")
    their_session = (
        await client.get("/v1/me/sessions", headers=bearer(theirs["access_token"]))
    ).json()[0]["id"]

    response = await client.delete(
        f"/v1/me/sessions/{their_session}", headers=bearer(mine["access_token"])
    )

    assert response.status_code == 404
    assert (await client.get("/v1/me", headers=bearer(theirs["access_token"]))).status_code == 200


async def test_revoke_others_keeps_only_this_session(client: AsyncClient) -> None:
    phone = await dev_login(client, install_id="phone")
    tablet = await dev_login(client, install_id="tablet")

    response = await client.post(
        "/v1/me/sessions/revoke-others", headers=bearer(phone["access_token"])
    )

    assert response.status_code == 204
    assert (await client.get("/v1/me", headers=bearer(phone["access_token"]))).status_code == 200
    assert (await client.get("/v1/me", headers=bearer(tablet["access_token"]))).status_code == 401


async def test_logout_ends_the_session_immediately(client: AsyncClient) -> None:
    login = await dev_login(client)

    response = await client.post("/v1/auth/logout", headers=bearer(login["access_token"]))

    assert response.status_code == 204
    assert response.content == b""
    me = await client.get("/v1/me", headers=bearer(login["access_token"]))
    assert me.json()["error"]["code"] == "SESSION_REVOKED"
    assert me.json()["error"]["details"] == {"reason": "logout"}
    refreshed = await client.post(
        "/v1/auth/refresh", json={"refresh_token": login["refresh_token"]}
    )
    assert refreshed.json()["error"]["code"] == "INVALID_REFRESH_TOKEN"


# --- Refresh -----------------------------------------------------------------------------


async def refresh(client: AsyncClient, token: str) -> Any:
    return await client.post("/v1/auth/refresh", json={"refresh_token": token})


async def test_refresh_rotates_both_tokens(client: AsyncClient, clock: FakeClock) -> None:
    login = await dev_login(client)
    clock.advance(minutes=10)

    response = await refresh(client, login["refresh_token"])

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"access_token", "access_expires_in", "refresh_token"}
    assert body["access_expires_in"] == 900
    assert body["refresh_token"] != login["refresh_token"]
    assert body["access_token"] != login["access_token"]
    assert (await client.get("/v1/me", headers=bearer(body["access_token"]))).status_code == 200


async def test_a_retry_within_the_grace_period_gets_the_same_pair(
    client: AsyncClient, clock: FakeClock
) -> None:
    login = await dev_login(client)
    first = (await refresh(client, login["refresh_token"])).json()

    clock.advance(seconds=59)
    retry = await refresh(client, login["refresh_token"])

    assert retry.status_code == 200
    assert retry.json()["refresh_token"] == first["refresh_token"]
    assert retry.json()["access_token"] == first["access_token"]
    assert retry.json()["access_expires_in"] == 900 - 59
    assert (await refresh(client, first["refresh_token"])).status_code == 200


async def test_reuse_after_the_grace_period_ends_the_session(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession
) -> None:
    login = await dev_login(client)
    successor = (await refresh(client, login["refresh_token"])).json()
    clock.advance(seconds=61)

    reused = await refresh(client, login["refresh_token"])

    assert reused.status_code == 401
    assert reused.json()["error"]["code"] == "REFRESH_TOKEN_REUSED"
    # The thief's (or victim's) newer tokens die with the session.
    assert (await refresh(client, successor["refresh_token"])).json()["error"][
        "code"
    ] == "INVALID_REFRESH_TOKEN"
    me = await client.get("/v1/me", headers=bearer(successor["access_token"]))
    assert me.json()["error"]["code"] == "SESSION_REVOKED"
    assert me.json()["error"]["details"] == {"reason": "refresh_reuse"}
    reason = await db_session.scalar(select(DeviceSession.revoke_reason))
    assert reason == "refresh_reuse"


async def test_refresh_tokens_expire_after_30_idle_days(
    client: AsyncClient, clock: FakeClock
) -> None:
    login = await dev_login(client)
    clock.advance(days=29)
    kept_alive = (await refresh(client, login["refresh_token"])).json()  # slides 30 more days

    clock.advance(days=29)
    assert (await refresh(client, kept_alive["refresh_token"])).status_code == 200
    unused = (await dev_login(client, install_id="idle-device"))["refresh_token"]
    clock.advance(days=30, seconds=1)
    idle = await refresh(client, unused)

    assert idle.json()["error"]["code"] == "INVALID_REFRESH_TOKEN"


async def test_refresh_families_end_90_days_after_sign_in(
    client: AsyncClient, clock: FakeClock
) -> None:
    token = (await dev_login(client))["refresh_token"]
    for _ in range(3):  # days 29, 58 and 87
        clock.advance(days=29)
        token = (await refresh(client, token)).json()["refresh_token"]

    clock.advance(days=3)  # day 90: capped, although only 3 days idle
    response = await refresh(client, token)

    assert response.json()["error"]["code"] == "INVALID_REFRESH_TOKEN"


async def test_unknown_refresh_token_is_401(client: AsyncClient) -> None:
    response = await refresh(client, "definitely-not-issued")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "INVALID_REFRESH_TOKEN"


async def test_refresh_tokens_are_stored_hashed(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    login = await dev_login(client)

    stored = await db_session.scalar(select(RefreshToken.token_hash))

    assert stored is not None
    assert len(stored) == 32
    assert login["refresh_token"].encode() not in stored


async def test_grace_entries_are_encrypted(client: AsyncClient, redis: Redis) -> None:
    login = await dev_login(client)
    successor = (await refresh(client, login["refresh_token"])).json()

    [key] = await redis.keys("auth:refresh_grace:*")
    sealed = await redis.get(key)

    assert successor["refresh_token"] not in sealed
    assert successor["access_token"] not in sealed


# --- Authentication of requests ----------------------------------------------------------


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Bearer"},
        {"Authorization": "Basic abc"},
        {"Authorization": "Bearer x"},
    ],
)
async def test_requests_without_a_valid_token_are_401(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    response = await client.get("/v1/me", headers=headers)

    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"


async def test_access_tokens_expire_after_15_minutes(client: AsyncClient, clock: FakeClock) -> None:
    login = await dev_login(client)

    clock.advance(minutes=15, seconds=25)  # within the 30 s leeway
    assert (await client.get("/v1/me", headers=bearer(login["access_token"]))).status_code == 200
    clock.advance(seconds=10)
    expired = await client.get("/v1/me", headers=bearer(login["access_token"]))

    assert expired.json()["error"]["code"] == "ACCESS_TOKEN_EXPIRED"


async def test_tokens_signed_with_an_unknown_key_are_rejected(
    client: AsyncClient, clock: FakeClock
) -> None:
    login = await dev_login(client)
    private_pem, public_pem = ed25519_pem_pair()
    token, _ = issue_access_token(
        JwtKeys("attacker", private_pem, public_pem),
        user_id=uuid.UUID(login["user"]["id"]),
        session_id=uuid.uuid4(),
        roles=["admin"],
        token_version=0,
        now=clock.now,
    )

    response = await client.get("/v1/me", headers=bearer(token))

    assert response.json()["error"]["code"] == "INVALID_ACCESS_TOKEN"


async def test_bumping_the_token_version_invalidates_access_tokens(
    client: AsyncClient, db_session: AsyncSession, redis: Redis
) -> None:
    login = await dev_login(client)
    await set_user(db_session, redis, login["user"]["id"], token_version=User.token_version + 1)

    stale = await client.get("/v1/me", headers=bearer(login["access_token"]))
    refreshed = (await refresh(client, login["refresh_token"])).json()

    assert stale.json()["error"]["code"] == "INVALID_ACCESS_TOKEN"
    assert (
        await client.get("/v1/me", headers=bearer(refreshed["access_token"]))
    ).status_code == 200


async def test_banned_users_are_refused_everywhere(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession, redis: Redis
) -> None:
    login = (await google_sign_in(client, clock)).json()
    await set_user(db_session, redis, login["user"]["id"], status="banned", ban_reason="cheating")

    me = await client.get("/v1/me", headers=bearer(login["access_token"]))
    refreshed = await refresh(client, login["refresh_token"])
    signed_in = await google_sign_in(client, clock, install_id="install-2")

    for response in (me, refreshed, signed_in):
        assert response.status_code == 403
        error = response.json()["error"]
        assert error["code"] == "ACCOUNT_BANNED"
        # A permanent ban: the Suspended screen shows why and where to appeal.
        assert error["details"] == {
            "reason": "cheating",
            "until": None,
            "appeal": "support@example.com",
        }


async def test_a_temporary_ban_says_until_when(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession, redis: Redis
) -> None:
    login = (await google_sign_in(client, clock)).json()
    until = datetime(2031, 5, 4, 12, 30, tzinfo=UTC)
    await set_user(db_session, redis, login["user"]["id"], status="banned", banned_until=until)

    me = await client.get("/v1/me", headers=bearer(login["access_token"]))
    refreshed = await refresh(client, login["refresh_token"])
    signed_in = await google_sign_in(client, clock, install_id="install-2")

    for response in (me, refreshed, signed_in):
        assert response.status_code == 403
        assert response.json()["error"]["details"] == {
            "reason": None,
            "until": "2031-05-04T12:30:00Z",
            "appeal": "support@example.com",
        }


async def test_a_temporary_ban_lifts_by_itself(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession, redis: Redis
) -> None:
    login = (await google_sign_in(client, clock)).json()
    await set_user(
        db_session,
        redis,
        login["user"]["id"],
        status="banned",
        ban_reason="abuse",
        banned_until=clock() + timedelta(minutes=5),
    )
    headers = bearer(login["access_token"])
    assert (await client.get("/v1/me", headers=headers)).status_code == 403  # also cached now

    clock.advance(minutes=5, seconds=1)

    me = await client.get("/v1/me", headers=headers)
    refreshed = await refresh(client, login["refresh_token"])
    signed_in = await google_sign_in(client, clock, install_id="install-2")
    assert me.status_code == 200
    assert refreshed.status_code == 200
    assert signed_in.status_code == 200


async def test_closed_accounts_are_signed_out(
    client: AsyncClient, db_session: AsyncSession, redis: Redis
) -> None:
    login = await dev_login(client)
    await set_user(db_session, redis, login["user"]["id"], status="pending_deletion")

    me = await client.get("/v1/me", headers=bearer(login["access_token"]))
    refreshed = await refresh(client, login["refresh_token"])

    assert (me.status_code, me.json()["error"]["code"]) == (401, "ACCOUNT_CLOSED")
    assert refreshed.json()["error"]["code"] == "ACCOUNT_CLOSED"


async def test_authorization_facts_are_cached_for_a_minute(
    client: AsyncClient, db_session: AsyncSession, redis: Redis
) -> None:
    login = await dev_login(client)
    headers = bearer(login["access_token"])
    await client.get("/v1/me", headers=headers)  # caches status, version and roles
    await db_session.execute(
        update(User).where(User.id == uuid.UUID(login["user"]["id"])).values(status="banned")
    )

    cached = await client.get("/v1/me", headers=headers)
    ttl = await redis.ttl(f"authz:{login['user']['id']}")
    await redis.delete(f"authz:{login['user']['id']}")
    fresh = await client.get("/v1/me", headers=headers)

    assert cached.status_code == 200
    assert 0 < ttl <= 60
    assert fresh.status_code == 403


async def test_roles(client: AsyncClient, db_session: AsyncSession, redis: Redis) -> None:
    login = await dev_login(client)
    headers = bearer(login["access_token"])

    as_user = await client.get("/test/admin", headers=headers)
    await set_user(db_session, redis, login["user"]["id"], roles=["user", "admin"])
    as_admin = await client.get("/test/admin", headers=headers)
    admin_as_moderator = await client.get("/test/moderator", headers=headers)

    assert (as_user.status_code, as_user.json()["error"]["code"]) == (403, "ROLE_REQUIRED")
    assert as_admin.status_code == 200
    assert admin_as_moderator.json() == {"user_id": login["user"]["id"]}


async def test_activity_is_recorded_at_most_every_five_minutes(
    client: AsyncClient, clock: FakeClock, db_session: AsyncSession, redis: Redis
) -> None:
    login = await dev_login(client)
    headers = bearer(login["access_token"])
    session_id = await db_session.scalar(select(DeviceSession.id))

    async def last_seen() -> Any:
        return await db_session.scalar(
            select(DeviceSession.last_seen_at).where(DeviceSession.id == session_id)
        )

    signed_in_at = await last_seen()
    clock.advance(minutes=1)
    await client.get("/v1/me", headers=headers)
    first_request = await last_seen()
    clock.advance(minutes=1)
    await client.get("/v1/me", headers=headers)
    within_interval = await last_seen()
    await redis.delete(f"seen:{session_id}")  # the gate's five minutes are over
    clock.advance(minutes=1)
    await client.get("/v1/me", headers=headers)
    after_interval = await last_seen()

    assert first_request == signed_in_at + timedelta(minutes=1)
    assert within_interval == first_request
    assert after_interval == first_request + timedelta(minutes=2)
    user_seen = await db_session.scalar(select(User.last_seen_at))
    assert user_seen == after_interval


async def test_access_log_names_the_user(
    client: AsyncClient, caplog: pytest.LogCaptureFixture
) -> None:
    login = await dev_login(client)
    caplog.set_level(logging.INFO)

    await client.get("/v1/me", headers=bearer(login["access_token"]))

    [entry] = [e for e in log_events(caplog, "http.request") if e["path"] == "/v1/me"]
    assert entry["user_id"] == login["user"]["id"]


async def test_identities_are_unique_per_provider_subject(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    for install in ("a", "b", "c"):
        await dev_login(client, "same@example.com", install_id=install)

    identities = await db_session.scalar(select(func.count()).select_from(AuthIdentity))
    users = await db_session.scalar(select(func.count()).select_from(User))
    sessions = await db_session.scalar(
        text("SELECT count(*) FROM device_sessions WHERE revoked_at IS NULL")
    )

    assert (identities, users, sessions) == (1, 1, 3)
