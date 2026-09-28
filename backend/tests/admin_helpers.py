"""Helpers for the admin panel tests: an app with the panel mounted, and signed-in admins."""

import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import get_clock
from app.core.config import Settings
from app.core.db import get_sessionmaker
from app.main_api import create_app
from app.modules.admin.auth import GOOGLE_TOKEN_URL
from app.modules.auth.google import GOOGLE_CERTS_URL
from app.modules.auth.models import AuthIdentity
from app.modules.system.models import AuditLog
from app.modules.users.models import User
from tests.helpers import FakeClock, dev_login, google_id_token, google_jwks, make_settings, serve

ADMIN_CLIENT_ID = "9876-admin.apps.googleusercontent.com"
ADMIN_CLIENT_SECRET = "admin-client-secret"
ORIGIN = {"Origin": "http://test"}


def admin_settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "admin_enabled": True,
        "admin_google_client_id": ADMIN_CLIENT_ID,
        "admin_google_client_secret": ADMIN_CLIENT_SECRET,
        **overrides,
    }
    return make_settings(**values)


class FakeGoogle:
    """Google's token endpoint and keys: the next code exchange returns ``id_token_claims``."""

    def __init__(self, clock: FakeClock) -> None:
        self.clock = clock
        self.subject = "google-admin-1"
        self.nonce: str | None = None
        self.claims: dict[str, Any] = {}
        self.token_requests: list[dict[str, list[str]]] = []
        self.fail = False

    def handle(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) == GOOGLE_CERTS_URL:
            return httpx.Response(200, json=google_jwks())
        assert str(request.url) == GOOGLE_TOKEN_URL
        self.token_requests.append(parse_qs(request.content.decode()))
        if self.fail:
            return httpx.Response(400, json={"error": "invalid_grant"})
        claims = {"aud": ADMIN_CLIENT_ID, "nonce": self.nonce, **self.claims}
        token = google_id_token(now=self.clock.now, subject=self.subject, **claims)
        return httpx.Response(200, json={"id_token": token, "access_token": "x"})


@asynccontextmanager
async def admin_client(
    settings: Settings,
    session_factory: async_sessionmaker[AsyncSession],
    clock: FakeClock,
    google: FakeGoogle | None = None,
) -> AsyncIterator[AsyncClient]:
    app = create_app(settings)
    app.dependency_overrides[get_sessionmaker] = lambda: session_factory
    app.dependency_overrides[get_clock] = lambda: clock
    google = google or FakeGoogle(clock)
    async with httpx.AsyncClient(transport=httpx.MockTransport(google.handle)) as http:
        app.state.admin_http = http
        async with serve(app) as client:
            yield client


async def make_user(
    client: AsyncClient,
    db: AsyncSession,
    email: str,
    *,
    roles: tuple[str, ...] = ("user", "admin"),
) -> dict[str, Any]:
    """A user (through dev login) with ``roles``; returns the login body."""
    login = await dev_login(client, email, install_id="install-" + email.split("@")[0])
    await db.execute(
        update(User).where(User.id == uuid.UUID(login["user"]["id"])).values(roles=list(roles))
    )
    await db.commit()
    return login


async def admin_sign_in(client: AsyncClient, email: str) -> httpx.Response:
    return await client.post("/admin/login", data={"email": email}, headers=ORIGIN)


async def signed_in_admin(client: AsyncClient, db: AsyncSession, email: str) -> uuid.UUID:
    login = await make_user(client, db, email)
    response = await admin_sign_in(client, email)
    assert response.status_code == 302, response.text
    assert response.headers["location"].endswith("/admin/")
    return uuid.UUID(login["user"]["id"])


async def link_google(db: AsyncSession, user_id: uuid.UUID, subject: str) -> None:
    db.add(AuthIdentity(user_id=user_id, provider="google", subject=subject))
    await db.commit()


def redirect_params(response: httpx.Response) -> dict[str, str]:
    query = parse_qs(urlsplit(response.headers["location"]).query)
    return {name: values[0] for name, values in query.items()}


async def drop_authz(redis: Redis, user_id: uuid.UUID) -> None:
    await redis.delete(f"authz:{user_id}")


async def user_row(db: AsyncSession, user_id: uuid.UUID) -> User:
    return await db.get_one(User, user_id, populate_existing=True)


async def audit_rows(db: AsyncSession, **filters: Any) -> list[Any]:
    stmt = (
        select(AuditLog)
        .order_by(AuditLog.created_at, AuditLog.id)
        .execution_options(populate_existing=True)
    )
    for name, value in filters.items():
        stmt = stmt.where(getattr(AuditLog, name) == value)
    return list(await db.scalars(stmt))
