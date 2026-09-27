"""Test helpers that are not fixtures."""

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import pytest
from alembic.config import Config
from asgi_lifespan import LifespanManager
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.engine import Connection

from app.core.config import Settings

BACKEND_DIR = Path(__file__).resolve().parents[1]
TEST_DATABASE_URL = os.environ.get(
    "APP_DATABASE_URL", "postgresql+asyncpg://quiz:quiz@127.0.0.1:54329/quiz_test"
)
TEST_REDIS_URL = os.environ.get("APP_REDIS_URL", "redis://127.0.0.1:63790/15")


def make_settings(**overrides: Any) -> Settings:
    """Test settings: never read ``.env``; point at the test database and Redis DB."""
    values: dict[str, Any] = {
        "env": "test",
        "database_url": TEST_DATABASE_URL,
        "redis_url": TEST_REDIS_URL,
        **overrides,
    }
    return Settings(_env_file=None, **values)


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
    return {"jwt_private_key": private_pem, "jwt_public_key": public_pem, "jwt_key_id": "k1"}


def log_events(caplog: pytest.LogCaptureFixture, event: str) -> list[dict[str, Any]]:
    """Captured structlog events named ``event`` (stdlib records carry plain strings)."""
    return [
        record.msg
        for record in caplog.records
        if isinstance(record.msg, dict) and record.msg.get("event") == event
    ]
