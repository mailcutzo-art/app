"""The admin panel's gate: mounting, sign-in (Google and dev), sessions, IP allowlist, CSRF."""

import uuid

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import Settings
from app.modules.users.models import User
from tests.admin_helpers import (
    ADMIN_CLIENT_ID,
    ADMIN_CLIENT_SECRET,
    ORIGIN,
    FakeGoogle,
    admin_client,
    admin_settings,
    admin_sign_in,
    audit_rows,
    link_google,
    make_user,
    redirect_params,
    signed_in_admin,
)
from tests.helpers import FakeClock, make_settings, prod_secrets


@pytest.fixture(autouse=True)
async def _fresh_redis(redis: Redis) -> None:
    """Every test starts with a flushed Redis (sign-in rate limits, authz cache)."""


async def test_the_panel_is_only_mounted_when_enabled(client: AsyncClient) -> None:
    response = await client.get("/admin/")

    assert response.status_code == 404


def test_prod_needs_a_session_secret_and_a_google_client_for_the_panel() -> None:
    with pytest.raises(ValueError, match="APP_ADMIN_SESSION_SECRET") as error:
        make_settings(
            env="prod",
            dev_login_enabled=False,
            admin_enabled=True,
            database_url="postgresql://quiz@db/quiz",
            redis_url="redis://:pw@redis:6379/0",
            **prod_secrets(),
        )
    assert "APP_ADMIN_GOOGLE_CLIENT_ID" in str(error.value)


def test_the_session_secret_must_be_long() -> None:
    with pytest.raises(ValueError, match="at least 32 characters"):
        make_settings(admin_session_secret="short")


async def test_signed_out_visitors_are_sent_to_the_sign_in_page(
    session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        index = await client.get("/admin/")
        users = await client.get("/admin/user/list")
        login = await client.get("/admin/login")

    assert index.status_code == 302
    assert index.headers["location"].endswith("/admin/login")
    assert users.status_code == 302
    assert login.status_code == 200
    assert "Sign in with Google" in login.text
    assert "Dev login" in login.text
    assert login.headers["X-Frame-Options"] == "DENY"
    assert login.headers["Cache-Control"] == "no-store"


async def test_dev_login_signs_in_an_admin(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        admin_id = await signed_in_admin(client, db_session, "root@example.com")
        index = await client.get("/admin/")
        users = await client.get("/admin/user/list")

    assert index.status_code == 200
    assert users.status_code == 200
    assert "root@example.com" in users.text
    cookie = next(c for c in client.cookies.jar if c.name == "quiz_admin")
    assert cookie.path == "/admin"
    [entry] = await audit_rows(db_session, action="admin.signed_in")
    assert entry.actor_id == admin_id
    assert entry.after == {"method": "dev"}


async def test_players_and_unknown_emails_cannot_sign_in(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        await make_user(client, db_session, "player@example.com", roles=("user",))
        await make_user(client, db_session, "mod@example.com", roles=("user", "moderator"))
        player = await admin_sign_in(client, "player@example.com")
        moderator = await admin_sign_in(client, "mod@example.com")
        unknown = await admin_sign_in(client, "nobody@example.com")
        index = await client.get("/admin/")

    assert player.status_code == moderator.status_code == unknown.status_code == 400
    assert "Invalid credentials" in player.text
    assert index.status_code == 302


async def test_dev_login_is_off_unless_enabled(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as setup:
        await make_user(setup, db_session, "root@example.com")
    settings = admin_settings(dev_login_enabled=False)
    async with admin_client(settings, session_factory, clock) as client:
        page = await client.get("/admin/login")
        response = await admin_sign_in(client, "root@example.com")

    assert "Dev login" not in page.text
    assert response.status_code == 400


async def test_a_banned_or_demoted_admin_loses_the_session_at_once(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        admin_id = await signed_in_admin(client, db_session, "root@example.com")
        await db_session.execute(update(User).where(User.id == admin_id).values(roles=["user"]))
        await db_session.commit()
        demoted = await client.get("/admin/")
        # Signing in again is refused too.
        again = await admin_sign_in(client, "root@example.com")

    assert demoted.status_code == 302
    assert again.status_code == 400


async def test_a_token_version_bump_ends_the_admin_session(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        admin_id = await signed_in_admin(client, db_session, "root@example.com")
        await db_session.execute(
            update(User).where(User.id == admin_id).values(token_version=User.token_version + 1)
        )
        await db_session.commit()
        response = await client.get("/admin/")
        after = await client.get("/admin/")

    assert response.status_code == 302
    assert after.status_code == 302


async def test_logout_ends_the_session(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        await signed_in_admin(client, db_session, "root@example.com")
        logout = await client.get("/admin/logout")
        response = await client.get("/admin/")

    assert logout.status_code == 302
    assert response.status_code == 302


async def test_a_forged_session_cookie_is_ignored(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        await signed_in_admin(client, db_session, "root@example.com")
        # Same cookie, signed with another secret: the panel refuses it.
        cookie = client.cookies.get("quiz_admin", path="/admin")
        assert cookie
    other = admin_settings(admin_session_secret="x" * 40)
    async with admin_client(other, session_factory, clock) as client:
        client.cookies.set("quiz_admin", cookie, domain="test", path="/admin")
        response = await client.get("/admin/")

    assert response.status_code == 302


# --- Same-origin writes and the IP allowlist -----------------------------------------------


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Origin": "https://evil.example"},
        {"Origin": "null"},
        {"Referer": "https://evil.example/page"},
        {"Origin": "http://test", "Sec-Fetch-Site": "cross-site"},
    ],
)
async def test_writes_from_other_origins_are_refused(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
    headers: dict[str, str],
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        await make_user(client, db_session, "root@example.com")
        response = await client.post(
            "/admin/login", data={"email": "root@example.com"}, headers=headers
        )

    assert response.status_code == 403
    assert not await audit_rows(db_session, action="admin.signed_in")


async def test_a_same_origin_referer_is_enough(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    async with admin_client(admin_settings(), session_factory, clock) as client:
        await make_user(client, db_session, "root@example.com")
        response = await client.post(
            "/admin/login",
            data={"email": "root@example.com"},
            headers={"Referer": "http://test/admin/login", "Sec-Fetch-Site": "same-origin"},
        )

    assert response.status_code == 302


@pytest.mark.parametrize(
    ("allowlist", "status"),
    [("10.0.0.0/8", 403), ("10.0.0.0/8, 127.0.0.1/32", 200), ("", 200)],
)
async def test_the_ip_allowlist_guards_every_page(
    session_factory: async_sessionmaker[AsyncSession],
    clock: FakeClock,
    allowlist: str,
    status: int,
) -> None:
    settings = admin_settings(admin_ip_allowlist=allowlist)
    async with admin_client(settings, session_factory, clock) as client:
        login = await client.get("/admin/login")
        statics = await client.get("/admin/statics/css/main.css")

    assert login.status_code == status
    assert statics.status_code == status


async def test_the_allowlist_uses_forwarded_ips_only_from_trusted_proxies(
    session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    settings = admin_settings(admin_ip_allowlist="203.0.113.7/32", trusted_proxies="127.0.0.1/32")
    async with admin_client(settings, session_factory, clock) as client:
        allowed = await client.get("/admin/login", headers={"X-Forwarded-For": "203.0.113.7"})
        refused = await client.get("/admin/login", headers={"X-Forwarded-For": "198.51.100.1"})

    assert allowed.status_code == 200
    assert refused.status_code == 403


# --- Google sign-in --------------------------------------------------------------------------


async def _start_google(client: AsyncClient, google: FakeGoogle) -> dict[str, str]:
    start = await client.get("/admin/auth/google")
    assert start.status_code == 302
    assert start.headers["location"].startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    params = redirect_params(start)
    google.nonce = params["nonce"]
    return params


async def test_google_sign_in_with_an_admin_account(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    google = FakeGoogle(clock)
    async with admin_client(admin_settings(), session_factory, clock, google) as client:
        login = await make_user(client, db_session, "root@example.com")
        await link_google(db_session, uuid.UUID(login["user"]["id"]), google.subject)
        params = await _start_google(client, google)
        callback = await client.get(
            "/admin/auth/callback", params={"code": "one-time-code", "state": params["state"]}
        )
        index = await client.get("/admin/")

    assert params["client_id"] == ADMIN_CLIENT_ID
    assert params["redirect_uri"] == "http://test/admin/auth/callback"
    assert params["scope"] == "openid email profile"
    assert callback.status_code == 302
    assert callback.headers["location"].endswith("/admin/")
    assert index.status_code == 200
    [exchange] = google.token_requests
    assert exchange["code"] == ["one-time-code"]
    assert exchange["client_secret"] == [ADMIN_CLIENT_SECRET]
    assert exchange["grant_type"] == ["authorization_code"]
    [entry] = await audit_rows(db_session, action="admin.signed_in")
    assert entry.after == {"method": "google"}


async def test_a_configured_redirect_url_is_sent_to_google(
    session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    settings = admin_settings(admin_oauth_redirect_url="https://quiz.example/admin/auth/callback")
    async with admin_client(settings, session_factory, clock) as client:
        start = await client.get("/admin/auth/google")

    assert redirect_params(start)["redirect_uri"] == "https://quiz.example/admin/auth/callback"


@pytest.mark.parametrize(
    "problem",
    ["wrong_state", "no_session", "cancelled", "token_error", "wrong_nonce", "wrong_audience"],
)
async def test_google_sign_in_problems_go_back_to_the_sign_in_page(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
    problem: str,
) -> None:
    google = FakeGoogle(clock)
    async with admin_client(admin_settings(), session_factory, clock, google) as client:
        login = await make_user(client, db_session, "root@example.com")
        await link_google(db_session, uuid.UUID(login["user"]["id"]), google.subject)
        params = await _start_google(client, google)
        query = {"code": "c", "state": params["state"]}
        if problem == "wrong_state":
            query["state"] = "forged"
        elif problem == "no_session":
            client.cookies.clear()
        elif problem == "cancelled":
            query = {"error": "access_denied", "state": params["state"]}
        elif problem == "token_error":
            google.fail = True
        elif problem == "wrong_nonce":
            google.nonce = "replayed"
        elif problem == "wrong_audience":
            google.claims = {"aud": "someone-else.apps.googleusercontent.com"}
        callback = await client.get("/admin/auth/callback", params=query)
        index = await client.get("/admin/")

    assert callback.status_code == 302
    assert "/admin/login?error=" in callback.headers["location"]
    assert index.status_code == 302


async def test_google_accounts_without_the_admin_role_are_refused(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
) -> None:
    google = FakeGoogle(clock)
    async with admin_client(admin_settings(), session_factory, clock, google) as client:
        login = await make_user(client, db_session, "player@example.com", roles=("user",))
        await link_google(db_session, uuid.UUID(login["user"]["id"]), google.subject)
        params = await _start_google(client, google)
        callback = await client.get(
            "/admin/auth/callback", params={"code": "c", "state": params["state"]}
        )
        # An account nobody linked is refused the same way.
        google.subject = "unknown-subject"
        params = await _start_google(client, google)
        unknown = await client.get(
            "/admin/auth/callback", params={"code": "c", "state": params["state"]}
        )

    assert "isn%27t+an+admin" in callback.headers["location"]
    assert "isn%27t+an+admin" in unknown.headers["location"]


async def test_google_sign_in_says_when_it_is_not_configured(
    session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    settings: Settings = admin_settings(admin_google_client_id=None)
    async with admin_client(settings, session_factory, clock) as client:
        page = await client.get("/admin/login")
        start = await client.get("/admin/auth/google")

    assert "isn't set up" in page.text
    assert "/admin/login?error=" in start.headers["location"]


async def test_admin_pages_skip_the_app_gates(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
    redis: Redis,
) -> None:
    """Maintenance mode must not lock admins out of the panel that turns it off."""
    async with admin_client(admin_settings(maintenance=True), session_factory, clock) as client:
        await signed_in_admin(client, db_session, "root@example.com")
        index = await client.get("/admin/", headers=ORIGIN)

    assert index.status_code == 200
