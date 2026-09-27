"""Idempotency-Key handling: replay, in-progress conflicts, key reuse and release on failure."""

import asyncio
import uuid
from dataclasses import dataclass, field

import pytest
from fastapi import APIRouter, FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.responses import Response

from app.core.db import SessionDep
from app.core.errors import ServiceUnavailable
from app.core.idempotency import IdempotencyDep
from app.core.schemas import ApiModel
from app.core.security import get_current_user_id
from app.modules.system.models import AppConfig

USER_A = uuid.UUID("01900000-0000-7000-8000-00000000000a")
USER_B = uuid.UUID("01900000-0000-7000-8000-00000000000b")


class ItemIn(ApiModel):
    key: str
    value: int


class ItemOut(ApiModel):
    key: str
    value: int


@dataclass
class Endpoint:
    """Observable, steerable state of the test endpoint."""

    user_id: uuid.UUID = USER_A
    calls: list[str] = field(default_factory=list)
    fail_once: set[str] = field(default_factory=set)
    entered: asyncio.Event = field(default_factory=asyncio.Event)
    release: asyncio.Event = field(default_factory=asyncio.Event)
    blocking: bool = False


@pytest.fixture
def endpoint() -> Endpoint:
    return Endpoint()


@pytest.fixture
def app(app: FastAPI, endpoint: Endpoint) -> FastAPI:
    router = APIRouter(prefix="/test")

    @router.post("/items", status_code=201, response_model=ItemOut)
    async def create_item(body: ItemIn, idem: IdempotencyDep, session: SessionDep) -> Response:
        endpoint.calls.append(body.key)
        session.add(AppConfig(key=body.key, value={"value": body.value}))
        if body.key in endpoint.fail_once:
            endpoint.fail_once.remove(body.key)
            raise ServiceUnavailable()
        if endpoint.blocking:
            endpoint.entered.set()
            await endpoint.release.wait()
        return await idem.complete(ItemOut(key=body.key, value=body.value), status_code=201)

    app.include_router(router)
    app.dependency_overrides[get_current_user_id] = lambda: endpoint.user_id
    return app


async def rows(session: AsyncSession, key: str) -> int:
    return await session.scalar(select(func.count()).where(AppConfig.key == key)) or 0


async def test_replays_the_stored_response(
    client: AsyncClient, endpoint: Endpoint, db_session: AsyncSession
) -> None:
    body = {"key": "k1", "value": 1}

    first = await client.post("/test/items", json=body, headers={"Idempotency-Key": "abc-1"})
    again = await client.post("/test/items", json=body, headers={"Idempotency-Key": "abc-1"})

    assert first.status_code == again.status_code == 201
    assert first.json() == again.json() == body
    assert "Idempotent-Replayed" not in first.headers
    assert again.headers["Idempotent-Replayed"] == "true"
    assert endpoint.calls == ["k1"]
    assert await rows(db_session, "k1") == 1


async def test_same_key_with_a_different_request_is_rejected(
    client: AsyncClient, endpoint: Endpoint
) -> None:
    headers = {"Idempotency-Key": "abc-1"}
    await client.post("/test/items", json={"key": "k1", "value": 1}, headers=headers)

    response = await client.post("/test/items", json={"key": "k1", "value": 2}, headers=headers)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "IDEMPOTENCY_KEY_REUSED"
    assert endpoint.calls == ["k1"]


async def test_duplicate_while_in_progress_is_409(
    client: AsyncClient, endpoint: Endpoint, redis: Redis
) -> None:
    body = {"key": "k1", "value": 1}
    headers = {"Idempotency-Key": "abc-1"}
    record = f"idem:{USER_A}:POST:/test/items:abc-1"
    endpoint.blocking = True

    first = asyncio.create_task(client.post("/test/items", json=body, headers=headers))
    await asyncio.wait_for(endpoint.entered.wait(), timeout=5)
    in_progress_ttl = await redis.pttl(record)
    duplicate = await client.post("/test/items", json=body, headers=headers)
    endpoint.release.set()
    completed = await first
    replay = await client.post("/test/items", json=body, headers=headers)

    assert duplicate.status_code == 409
    assert duplicate.json()["error"]["code"] == "IDEMPOTENCY_IN_PROGRESS"
    assert completed.status_code == 201
    assert replay.headers["Idempotent-Replayed"] == "true"
    assert endpoint.calls == ["k1"]
    assert 0 < in_progress_ttl <= 60_000
    assert 60_000 < await redis.pttl(record) <= 24 * 3600 * 1000


async def test_failure_releases_the_key_for_a_retry(
    client: AsyncClient, endpoint: Endpoint, db_session: AsyncSession
) -> None:
    body = {"key": "k1", "value": 1}
    headers = {"Idempotency-Key": "abc-1"}
    endpoint.fail_once.add("k1")

    failed = await client.post("/test/items", json=body, headers=headers)
    retried = await client.post("/test/items", json=body, headers=headers)

    assert failed.status_code == 503
    assert retried.status_code == 201
    assert "Idempotent-Replayed" not in retried.headers
    assert endpoint.calls == ["k1", "k1"]
    assert await rows(db_session, "k1") == 1  # the failed attempt was rolled back


async def test_keys_are_scoped_per_user(client: AsyncClient, endpoint: Endpoint) -> None:
    headers = {"Idempotency-Key": "shared-key"}

    as_a = await client.post("/test/items", json={"key": "k1", "value": 1}, headers=headers)
    endpoint.user_id = USER_B
    as_b = await client.post("/test/items", json={"key": "k2", "value": 2}, headers=headers)

    assert (as_a.status_code, as_b.status_code) == (201, 201)
    assert "Idempotent-Replayed" not in as_b.headers
    assert endpoint.calls == ["k1", "k2"]


@pytest.mark.parametrize(
    ("headers", "code"),
    [
        ({}, "IDEMPOTENCY_KEY_MISSING"),
        ({"Idempotency-Key": ""}, "IDEMPOTENCY_KEY_INVALID"),
        ({"Idempotency-Key": "has space"}, "IDEMPOTENCY_KEY_INVALID"),
        ({"Idempotency-Key": "k" * 65}, "IDEMPOTENCY_KEY_INVALID"),
    ],
)
async def test_missing_or_malformed_key_is_400(
    client: AsyncClient, endpoint: Endpoint, headers: dict[str, str], code: str
) -> None:
    response = await client.post("/test/items", json={"key": "k1", "value": 1}, headers=headers)

    assert response.status_code == 400
    assert response.json()["error"]["code"] == code
    assert endpoint.calls == []


async def test_requires_authentication(app: FastAPI, client: AsyncClient) -> None:
    del app.dependency_overrides[get_current_user_id]

    response = await client.post(
        "/test/items", json={"key": "k1", "value": 1}, headers={"Idempotency-Key": "abc-1"}
    )

    assert response.status_code == 401
