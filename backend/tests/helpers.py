"""Test helpers that are not fixtures."""

import base64
import functools
import json
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
import jwt
import pytest
from alembic.config import Config
from asgi_lifespan import LifespanManager
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.engine import Connection

from app.core.clock import utc_now
from app.core.config import Settings
from app.modules.auth.google import GOOGLE_CERTS_URL

BACKEND_DIR = Path(__file__).resolve().parents[1]
CONTENT_DIR = BACKEND_DIR.parent / "content"
TEST_DATABASE_URL = os.environ.get(
    "APP_DATABASE_URL", "postgresql+asyncpg://quiz:quiz@127.0.0.1:54329/quiz_test"
)
TEST_REDIS_URL = os.environ.get("APP_REDIS_URL", "redis://127.0.0.1:63790/15")
GOOGLE_CLIENT_ID = "1234-test.apps.googleusercontent.com"
GOOGLE_KEY_ID = "test-key-1"


def make_settings(**overrides: Any) -> Settings:
    """Test settings: never read ``.env``; point at the test database and Redis DB."""
    values: dict[str, Any] = {
        "env": "test",
        "database_url": TEST_DATABASE_URL,
        "redis_url": TEST_REDIS_URL,
        "google_client_ids": [GOOGLE_CLIENT_ID],
        "dev_login_enabled": True,
        **overrides,
    }
    return Settings(_env_file=None, **values)


class FakeClock:
    """A controllable ``Clock``: starts at the real time and moves only when told to."""

    def __init__(self, start: datetime | None = None) -> None:
        self.now = start or utc_now()

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **delta: float) -> None:
        self.now += timedelta(**delta)


@functools.cache
def google_signing_key(key_id: str) -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def google_jwks(*key_ids: str) -> dict[str, Any]:
    """A JWKS document with the public halves of the test signing keys."""
    keys = []
    for key_id in key_ids or (GOOGLE_KEY_ID,):
        jwk = json.loads(
            jwt.algorithms.RSAAlgorithm.to_jwk(google_signing_key(key_id).public_key())
        )
        keys.append({**jwk, "kid": key_id, "alg": "RS256", "use": "sig"})
    return {"keys": keys}


def google_id_token(
    *,
    now: datetime,
    subject: str = "google-sub-1",
    email: str | None = "asha@example.com",
    name: str | None = "Asha Verma",
    key_id: str = GOOGLE_KEY_ID,
    headers: dict[str, Any] | None = None,
    **claims: Any,
) -> str:
    """A Google-shaped ID token signed with a local test key; ``claims`` override defaults."""
    issued_at = int(now.timestamp())
    payload: dict[str, Any] = {
        "iss": "https://accounts.google.com",
        "aud": GOOGLE_CLIENT_ID,
        "sub": subject,
        "email": email,
        "email_verified": True,
        "name": name,
        "iat": issued_at,
        "exp": issued_at + 3600,
        "nonce": os.urandom(8).hex(),  # as the app requests; also makes each token unique
        **claims,
    }
    return jwt.encode(
        {k: v for k, v in payload.items() if v is not None},
        google_signing_key(key_id),
        algorithm="RS256",
        headers={"kid": key_id, **(headers or {})},
    )


def google_certs_transport(
    *key_ids: str, cache_control: str = "public, max-age=3600"
) -> httpx.MockTransport:
    """Serves the test JWKS at Google's certs URL, like the real endpoint."""

    def handle(request: httpx.Request) -> httpx.Response:
        assert str(request.url) == GOOGLE_CERTS_URL
        return httpx.Response(
            200, json=google_jwks(*key_ids), headers={"Cache-Control": cache_control}
        )

    return httpx.MockTransport(handle)


def device(install_id: str = "install-1", **overrides: Any) -> dict[str, Any]:
    return {
        "install_id": install_id,
        "platform": "android",
        "app_version": "1.0.0",
        "build": 7,
        **overrides,
    }


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def dev_login(
    client: AsyncClient, email: str = "asha@example.com", *, install_id: str = "install-1"
) -> dict[str, Any]:
    """Sign in through dev login and return the response body."""
    response = await client.post(
        "/v1/auth/dev-login", json={"email": email, "device": device(install_id)}
    )
    assert response.status_code == 200, response.text
    body: dict[str, Any] = response.json()
    return body


@asynccontextmanager
async def serve(app: FastAPI) -> AsyncIterator[AsyncClient]:
    """Run ``app``'s lifespan and yield an HTTP client talking to it in-process."""
    async with LifespanManager(app) as manager:
        transport = ASGITransport(app=manager.app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


def alembic_config(connection: Connection) -> Config:
    config = Config(BACKEND_DIR / "alembic.ini")
    config.attributes["connection"] = connection
    return config


def ed25519_pem_pair() -> tuple[str, str]:
    key = Ed25519PrivateKey.generate()
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    public_pem = (
        key.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )
    return private_pem, public_pem


def prod_secrets() -> dict[str, str]:
    """The settings prod requires beyond the test defaults (explicit URLs are set by tests)."""
    private_pem, public_pem = ed25519_pem_pair()
    return {
        "jwt_private_key": private_pem,
        "jwt_public_key": public_pem,
        "jwt_key_id": "k1",
        "refresh_grace_key": base64.b64encode(os.urandom(32)).decode(),
    }


def log_events(caplog: pytest.LogCaptureFixture, event: str) -> list[dict[str, Any]]:
    """Captured structlog events named ``event`` (stdlib records carry plain strings)."""
    return [
        record.msg
        for record in caplog.records
        if isinstance(record.msg, dict) and record.msg.get("event") == event
    ]
