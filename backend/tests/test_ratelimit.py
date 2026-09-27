"""Token-bucket rate limiting: bucket semantics, the FastAPI dependency and client IPs."""

import asyncio
import uuid
from ipaddress import IPv4Network, IPv6Network, ip_network

import pytest
from fastapi import APIRouter, Depends, FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from starlette.requests import Request

from app.core.ratelimit import consume, rate_limit
from app.core.security import client_ip, get_current_user_id
from app.main_api import create_app
from tests.helpers import make_settings, serve

router = APIRouter(prefix="/test")


@router.get("/ip", dependencies=[Depends(rate_limit("t.ip", capacity=2, refill_per_sec=0.1))])
async def ip_limited() -> dict[str, bool]:
    return {"ok": True}


@router.get(
    "/user",
    dependencies=[
        Depends(rate_limit("t.user", capacity=1, refill_per_sec=0.1, scope="user")),
    ],
)
async def user_limited() -> dict[str, bool]:
    return {"ok": True}


@pytest.fixture
def app(app: FastAPI) -> FastAPI:
    app.include_router(router)
    return app


async def test_bucket_allows_capacity_then_denies(redis: Redis) -> None:
    results = [await consume(redis, "b", capacity=3, refill_per_sec=1) for _ in range(4)]

    assert [r.allowed for r in results] == [True, True, True, False]
    assert [r.remaining for r in results] == [2, 1, 0, 0]
    # One token short at one token per second (minus whatever refilled between the calls).
    assert 500 < results[-1].retry_after_ms <= 1000


async def test_bucket_refills_over_time_up_to_capacity(redis: Redis) -> None:
    for _ in range(2):
        assert (await consume(redis, "b", capacity=2, refill_per_sec=50)).allowed
    assert not (await consume(redis, "b", capacity=2, refill_per_sec=50)).allowed

    await asyncio.sleep(0.2)  # 10 tokens' worth of refill, capped at the capacity of 2

    results = [await consume(redis, "b", capacity=2, refill_per_sec=50) for _ in range(3)]
    assert [r.allowed for r in results] == [True, True, False]


async def test_bucket_cost_and_expiry(redis: Redis) -> None:
    first = await consume(redis, "b", capacity=5, refill_per_sec=1, cost=3)
    second = await consume(redis, "b", capacity=5, refill_per_sec=1, cost=3)

    assert (first.allowed, first.remaining) == (True, 2)
    assert (second.allowed, second.remaining) == (False, 2)
    assert 500 < second.retry_after_ms <= 1000
    # The key disappears once the bucket would be full again (5 s) plus a margin.
    assert 5000 < await redis.pttl("b") <= 6000


@pytest.mark.parametrize(
    ("capacity", "refill_per_sec", "cost"), [(0, 1, 1), (1, 0, 1), (2, 1, 3), (2, 1, 0)]
)
def test_rejects_impossible_buckets(capacity: int, refill_per_sec: float, cost: int) -> None:
    with pytest.raises(ValueError, match="capacity"):
        rate_limit("x", capacity=capacity, refill_per_sec=refill_per_sec, cost=cost)


async def test_dependency_returns_429_with_retry_after(client: AsyncClient) -> None:
    statuses = [(await client.get("/test/ip")).status_code for _ in range(2)]
    limited = await client.get("/test/ip")

    assert statuses == [200, 200]
    assert limited.status_code == 429
    # One token short at 0.1 token/s: retry in 10 s.
    assert limited.headers["Retry-After"] == "10"
    error = limited.json()["error"]
    assert error["code"] == "RATE_LIMITED"
    assert error["details"] == {"retry_after": 10}


async def test_forwarded_for_is_ignored_without_trusted_proxies(client: AsyncClient) -> None:
    for spoofed in ("203.0.113.1", "203.0.113.2"):
        assert (await client.get("/test/ip", headers={"X-Forwarded-For": spoofed})).is_success

    response = await client.get("/test/ip", headers={"X-Forwarded-For": "203.0.113.3"})

    assert response.status_code == 429


async def test_ip_scope_uses_forwarded_for_behind_trusted_proxy(redis: Redis) -> None:
    """``redis`` flushes the test database this separately configured app uses."""
    app = create_app(make_settings(trusted_proxies="127.0.0.1"))
    app.include_router(router)
    first_client = {"X-Forwarded-For": "203.0.113.1"}
    async with serve(app) as client:
        allowed = [await client.get("/test/ip", headers=first_client) for _ in range(2)]
        blocked = await client.get("/test/ip", headers=first_client)
        other_client = await client.get("/test/ip", headers={"X-Forwarded-For": "203.0.113.2"})

    assert [response.status_code for response in allowed] == [200, 200]
    assert blocked.status_code == 429
    assert other_client.status_code == 200


async def test_user_scope_limits_each_user_separately(app: FastAPI, client: AsyncClient) -> None:
    current_user = uuid.uuid4()
    app.dependency_overrides[get_current_user_id] = lambda: current_user

    first = await client.get("/test/user")
    second = await client.get("/test/user")
    current_user = uuid.uuid4()
    other_user = await client.get("/test/user")

    assert (first.status_code, second.status_code, other_user.status_code) == (200, 429, 200)


async def test_user_scope_requires_authentication(client: AsyncClient) -> None:
    response = await client.get("/test/user")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


def make_request(peer: str, forwarded_for: list[str] | None = None) -> Request:
    headers = [(b"x-forwarded-for", value.encode()) for value in forwarded_for or []]
    return Request({"type": "http", "client": (peer, 1234), "headers": headers})


TRUSTED = [ip_network("10.0.0.0/8"), ip_network("127.0.0.1/32")]


@pytest.mark.parametrize(
    ("peer", "forwarded_for", "trusted", "expected"),
    [
        ("198.51.100.7", ["203.0.113.9"], [], "198.51.100.7"),  # no trusted proxies configured
        ("198.51.100.7", ["203.0.113.9"], TRUSTED, "198.51.100.7"),  # peer is not a proxy
        ("10.0.0.2", ["203.0.113.9"], TRUSTED, "203.0.113.9"),
        # Left-most hops are client-controlled: take the right-most untrusted one.
        ("10.0.0.2", ["1.1.1.1, 203.0.113.9, 10.0.0.5"], TRUSTED, "203.0.113.9"),
        ("10.0.0.2", ["1.1.1.1", "203.0.113.9"], TRUSTED, "203.0.113.9"),  # repeated headers
        ("10.0.0.2", ["not-an-ip"], TRUSTED, "10.0.0.2"),
        ("10.0.0.2", [], TRUSTED, "10.0.0.2"),
        ("10.0.0.2", ["2001:db8::1"], TRUSTED, "2001:db8::1"),
    ],
)
def test_client_ip(
    peer: str,
    forwarded_for: list[str],
    trusted: list[IPv4Network | IPv6Network],
    expected: str,
) -> None:
    assert client_ip(make_request(peer, forwarded_for), trusted) == expected
