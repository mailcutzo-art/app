"""Races that need real concurrent transactions, so these tests commit (and clean up after)."""

import asyncio
from collections.abc import AsyncIterator

import httpx
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.core.clock import get_clock
from app.core.config import Settings
from app.main_api import create_app
from tests.helpers import FakeClock, dev_login, device, serve


@pytest.fixture
async def committed_client(
    settings: Settings, clock: FakeClock, engine: AsyncEngine, redis: Redis
) -> AsyncIterator[AsyncClient]:
    """A client whose requests run in their own committed transactions, like production."""
    app = create_app(settings)
    app.dependency_overrides[get_clock] = lambda: clock
    try:
        async with serve(app) as client:
            yield client
    finally:
        async with engine.begin() as connection:
            await connection.execute(text("TRUNCATE users CASCADE"))


async def count(engine: AsyncEngine, table: str) -> int:
    async with engine.connect() as connection:
        return int(await connection.scalar(text(f"SELECT count(*) FROM {table}")))  # noqa: S608


async def test_concurrent_refreshes_with_one_token_rotate_it_once(
    committed_client: AsyncClient, engine: AsyncEngine
) -> None:
    login = await dev_login(committed_client)

    responses = await asyncio.gather(
        *(
            committed_client.post(
                "/v1/auth/refresh", json={"refresh_token": login["refresh_token"]}
            )
            for _ in range(5)
        )
    )

    assert [response.status_code for response in responses] == [200] * 5
    pairs = {(r.json()["access_token"], r.json()["refresh_token"]) for r in responses}
    assert len(pairs) == 1  # the losers of the race got the winner's pair
    assert await count(engine, "refresh_tokens") == 2  # the original and one successor


async def test_concurrent_first_sign_ins_create_one_user(
    committed_client: AsyncClient, engine: AsyncEngine
) -> None:
    responses: list[httpx.Response] = await asyncio.gather(
        *(
            committed_client.post(
                "/v1/auth/dev-login", json={"email": "new@example.com", "device": device(name)}
            )
            for name in ("phone", "tablet")
        )
    )

    assert [response.status_code for response in responses] == [200, 200]
    assert len({response.json()["user"]["id"] for response in responses}) == 1
    assert await count(engine, "users") == 1
    assert await count(engine, "device_sessions") == 2
