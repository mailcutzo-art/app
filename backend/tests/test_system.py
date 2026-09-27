from collections.abc import AsyncIterator

import pytest
from fastapi import FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from redis.asyncio.retry import Retry
from redis.backoff import NoBackoff
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.core.db import get_sessionmaker
from app.core.redis import get_redis
from app.main_api import create_app
from tests.helpers import make_settings, prod_secrets, serve


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
    settings = make_settings(min_build=42, maintenance=True, feature_flags={"arena": True})
    async with serve(create_app(settings)) as client:
        response = await client.get("/v1/config")

    assert response.status_code == 200
    assert response.json() == {"min_build": 42, "maintenance": True, "features": {"arena": True}}


async def test_api_docs_are_disabled_in_prod() -> None:
    settings = make_settings(env="prod", **prod_secrets())

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
