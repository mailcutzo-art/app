from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi import FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from redis.asyncio.retry import Retry
from redis.backoff import NoBackoff
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.clock import get_clock
from app.core.db import get_sessionmaker
from app.core.redis import get_redis
from app.main_api import create_app
from app.modules.system.models import AppConfig
from tests.helpers import FakeClock, bearer, dev_login, device, make_settings, prod_secrets, serve


async def test_healthz(client: AsyncClient) -> None:
    response = await client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_when_dependencies_are_up(client: AsyncClient) -> None:
    response = await client.get("/readyz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "checks": {"database": "ok", "redis": "ok"}}


@pytest.fixture
async def unreachable_redis() -> AsyncIterator[Redis]:
    client = Redis(
        host="127.0.0.1", port=1, socket_connect_timeout=0.5, retry=Retry(NoBackoff(), retries=0)
    )
    yield client
    await client.aclose()


async def test_readyz_fails_when_redis_is_down(
    app: FastAPI, client: AsyncClient, unreachable_redis: Redis
) -> None:
    app.dependency_overrides[get_redis] = lambda: unreachable_redis

    response = await client.get("/readyz")

    assert response.status_code == 503
    error = response.json()["error"]
    assert error["code"] == "SERVICE_UNAVAILABLE"
    assert error["details"] == {"checks": {"database": "ok", "redis": "unavailable"}}
    assert error["request_id"] == response.headers["X-Request-ID"]


async def test_readyz_fails_when_database_is_down(app: FastAPI, client: AsyncClient) -> None:
    engine = create_async_engine("postgresql+asyncpg://quiz:quiz@127.0.0.1:1/quiz_test")
    app.dependency_overrides[get_sessionmaker] = lambda: async_sessionmaker(engine)
    try:
        response = await client.get("/readyz")
    finally:
        await engine.dispose()

    assert response.status_code == 503
    assert response.json()["error"]["details"] == {
        "checks": {"database": "unavailable", "redis": "ok"}
    }


async def test_client_config_reflects_settings() -> None:
    settings = make_settings(
        min_build=42,
        maintenance=True,
        maintenance_message="Back at 6 pm.",
        maintenance_until="2026-09-27T12:30:00Z",
        feature_flags={"arena": True},
    )
    app = create_app(settings)
    now = datetime(2026, 9, 27, 16, 0, 0, 250_000, tzinfo=UTC)
    app.dependency_overrides[get_clock] = lambda: FakeClock(now)
    async with serve(app) as client:
        response = await client.get("/v1/config")

    assert response.status_code == 200
    assert response.json() == {
        "min_build": 42,
        "maintenance": True,
        "maintenance_message": "Back at 6 pm.",
        "maintenance_until": "2026-09-27T12:30:00Z",
        "maintenance_at": None,
        "features": {"arena": True},
        "server_time": "2026-09-27T16:00:00.250000Z",
    }


async def test_client_config_defaults(client: AsyncClient) -> None:
    config = (await client.get("/v1/config")).json()

    assert config["maintenance"] is False
    assert config["maintenance_message"] is None
    assert datetime.fromisoformat(config["server_time"]).tzinfo is not None


async def test_api_docs_are_disabled_in_prod() -> None:
    settings = make_settings(env="prod", dev_login_enabled=False, **prod_secrets())

    async with serve(create_app(settings)) as client:
        docs = await client.get("/docs")
        schema = await client.get("/openapi.json")

    assert docs.status_code == 404
    assert schema.status_code == 404


async def test_cors_is_enabled_for_configured_origins() -> None:
    settings = make_settings(cors_origins="https://admin.example")

    async with serve(create_app(settings)) as client:
        preflight = await client.options(
            "/v1/config",
            headers={
                "Origin": "https://admin.example",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "Idempotency-Key",
            },
        )
        simple = await client.get("/v1/config", headers={"Origin": "https://admin.example"})
        foreign = await client.get("/v1/config", headers={"Origin": "https://evil.example"})

    assert preflight.status_code == 200
    assert preflight.headers["Access-Control-Allow-Origin"] == "https://admin.example"
    assert "Idempotency-Key" in preflight.headers["Access-Control-Allow-Headers"]
    assert "X-Request-ID" in simple.headers["Access-Control-Expose-Headers"]
    assert "Access-Control-Allow-Origin" not in foreign.headers


async def test_openapi_schema_is_served_outside_prod(client: AsyncClient) -> None:
    response = await client.get("/openapi.json")

    assert response.status_code == 200
    assert {"/healthz", "/readyz", "/v1/config"} <= set(response.json()["paths"])


async def set_runtime(db: AsyncSession, app: FastAPI, **values: Any) -> None:
    """Change runtime switches as an admin would (app_config rows), then drop the cache."""
    for key, value in values.items():
        await db.merge(AppConfig(key=key, value=value))
    await db.flush()
    app.state.runtime_config.clear()


async def test_config_is_read_from_the_database_first(
    app: FastAPI, client: AsyncClient, db_session: AsyncSession
) -> None:
    await set_runtime(
        db_session,
        app,
        min_build=12,
        maintenance_at="2026-10-01T20:00:00+05:30",
        maintenance_message=None,
        maintenance_until="not a time",  # invalid: the setting is used instead
    )

    config = (await client.get("/v1/config")).json()

    assert config["min_build"] == 12
    assert config["maintenance_at"] == "2026-10-01T14:30:00Z"
    assert config["maintenance_until"] is None
    assert config["maintenance"] is False


async def test_config_falls_back_to_settings_when_the_database_is_down(
    app: FastAPI, client: AsyncClient
) -> None:
    engine = create_async_engine("postgresql+asyncpg://quiz:quiz@127.0.0.1:1/quiz_test")
    app.dependency_overrides[get_sessionmaker] = lambda: async_sessionmaker(engine)
    try:
        response = await client.get("/v1/config")
    finally:
        await engine.dispose()

    assert response.status_code == 200
    assert response.json()["min_build"] == 1


async def test_old_app_builds_must_update(
    app: FastAPI, client: AsyncClient, db_session: AsyncSession
) -> None:
    await set_runtime(db_session, app, min_build=10)
    login = await dev_login(client)  # sign-in stays open to old builds
    old = {**bearer(login["access_token"]), "X-App-Build": "9"}

    blocked = await client.get("/v1/me", headers=old)
    current = await client.get("/v1/me", headers={**old, "X-App-Build": "10"})
    unknown = await client.get("/v1/me", headers=bearer(login["access_token"]))
    exempt = [
        await client.get("/v1/config", headers=old),
        await client.get("/healthz", headers=old),
        await client.post(
            "/v1/auth/refresh", json={"refresh_token": login["refresh_token"]}, headers=old
        ),
    ]

    assert blocked.status_code == 426
    assert blocked.json()["error"]["code"] == "UPDATE_REQUIRED"
    assert blocked.json()["error"]["details"] == {"min_build": 10}
    assert current.status_code == unknown.status_code == 200
    assert [response.status_code for response in exempt] == [200, 200, 200]


async def test_maintenance_closes_everything_but_config_and_sign_in(
    app: FastAPI, client: AsyncClient, db_session: AsyncSession, clock: FakeClock
) -> None:
    login = await dev_login(client)
    await set_runtime(
        db_session,
        app,
        maintenance=True,
        maintenance_message="New questions are on their way. Back at 6 pm.",
        maintenance_until=(clock() + timedelta(minutes=30)).isoformat(),
    )

    me = await client.get("/v1/me", headers=bearer(login["access_token"]))
    catalog = await client.get("/v1/catalog", headers=bearer(login["access_token"]))
    config = await client.get("/v1/config")
    signed_in = await client.post(
        "/v1/auth/dev-login", json={"email": "ravi@example.com", "device": device("install-9")}
    )

    for response in (me, catalog):
        assert response.status_code == 503
        error = response.json()["error"]
        assert error["code"] == "MAINTENANCE"
        assert error["message"] == "New questions are on their way. Back at 6 pm."
        assert 1790 <= int(response.headers["Retry-After"]) <= 1800
    assert config.status_code == 200
    assert config.json()["maintenance"] is True
    assert signed_in.status_code == 200
