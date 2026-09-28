"""Helpers for the platform tests: outbox delivery, users, and a fake FCM."""

import json
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import utc_now
from app.core.config import Settings
from app.modules.outbox.service import DispatchResult, dispatch_due
from app.modules.users.models import User
from tests.helpers import bearer, dev_login


async def deliver(
    session_factory: async_sessionmaker[AsyncSession],
    redis: Redis,
    settings: Settings,
    *,
    http: httpx.AsyncClient | None = None,
    now: datetime | None = None,
) -> DispatchResult:
    """Run one dispatcher pass inside the test transaction."""
    async with session_factory() as db:
        if http is not None:
            return await dispatch_due(
                db, redis=redis, http=http, settings=settings, now=now or utc_now()
            )
        async with httpx.AsyncClient() as client:
            return await dispatch_due(
                db, redis=redis, http=client, settings=settings, now=now or utc_now()
            )


async def onboarded(
    client: AsyncClient, name: str = "asha", *, birth_year: int = 2000
) -> dict[str, str]:
    """A signed-in, onboarded player (any birth year); returns the auth headers."""
    login = await dev_login(client, f"{name}@example.com", install_id=f"install-{name}")
    headers = bearer(login["access_token"])
    response = await client.post(
        "/v1/me/onboarding",
        headers=headers,
        json={
            "display_name": name.title(),
            "handle": f"{name}_{uuid.uuid4().hex[:6]}",
            "avatar": {"tone": "mint", "symbol": "dna"},
            "goal": "neet",
            "birth_year": birth_year,
        },
    )
    assert response.status_code == 200, response.text
    return headers


async def user_id(client: AsyncClient, headers: dict[str, str]) -> uuid.UUID:
    response = await client.get("/v1/me", headers=headers)
    assert response.status_code == 200, response.text
    return uuid.UUID(response.json()["id"])


async def bare_user(db: AsyncSession, name: str = "bea") -> uuid.UUID:
    """A user row without sign-in (for service-level tests)."""
    user = User(display_name=name.title(), email=f"{name}-{uuid.uuid4().hex[:6]}@example.com")
    db.add(user)
    await db.flush()
    return user.id


@dataclass
class FakeFcm:
    """Google's token endpoint and FCM's send endpoint, recording what was sent."""

    project: str = "quiz-test"
    sent: list[dict[str, Any]] = field(default_factory=list)
    token_requests: int = 0
    # token -> response for sends to it (default 200)
    responses: dict[str, Callable[[], httpx.Response]] = field(default_factory=dict)

    def handle(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/token":
            self.token_requests += 1
            return httpx.Response(200, json={"access_token": "ya29.test", "expires_in": 3600})
        assert request.url.path == f"/v1/projects/{self.project}/messages:send"
        assert request.headers["authorization"] == "Bearer ya29.test"
        message = json.loads(request.content)["message"]
        respond = self.responses.get(message["token"])
        if respond is not None:
            return respond()
        self.sent.append(message)
        return httpx.Response(200, json={"name": "projects/quiz-test/messages/1"})

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self.handle))


def service_account_file(directory: Path, project: str = "quiz-test") -> Path:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    path = directory / "fcm.json"
    path.write_text(
        json.dumps(
            {
                "type": "service_account",
                "project_id": project,
                "client_email": f"push-{uuid.uuid4().hex[:6]}@{project}.iam.gserviceaccount.com",
                "private_key": pem,
                "token_uri": "https://oauth2.googleapis.com/token",
            }
        )
    )
    return path
