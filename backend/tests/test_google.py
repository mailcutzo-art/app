"""Google ID-token verification and the JWKS cache (no network: keys are served locally)."""

import asyncio
from collections.abc import AsyncIterator, Callable
from datetime import timedelta
from typing import Any

import httpx
import pytest
from redis.asyncio import Redis

from app.core.clock import utc_now
from app.core.errors import AppError, ServiceUnavailable, Unauthorized
from app.modules.auth.google import (
    GOOGLE_CERTS_URL,
    GoogleIdTokenVerifier,
    JwksCache,
    claim_single_use,
)
from tests.helpers import GOOGLE_CLIENT_ID, GOOGLE_KEY_ID, google_id_token, google_jwks


class Monotonic:
    def __init__(self) -> None:
        self.value = 1000.0

    def __call__(self) -> float:
        return self.value


class CertsServer:
    """A stand-in for Google's certs endpoint that counts requests."""

    def __init__(self) -> None:
        self.key_ids = [GOOGLE_KEY_ID]
        self.cache_control = "public, max-age=3600"
        self.fail = False
        self.requests = 0

    def handle(self, request: httpx.Request) -> httpx.Response:
        assert str(request.url) == GOOGLE_CERTS_URL
        self.requests += 1
        if self.fail:
            return httpx.Response(503)
        return httpx.Response(
            200,
            json=google_jwks(*self.key_ids),
            headers={"Cache-Control": self.cache_control},
        )


@pytest.fixture
def certs() -> CertsServer:
    return CertsServer()


@pytest.fixture
async def http(certs: CertsServer) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(transport=httpx.MockTransport(certs.handle)) as client:
        yield client


@pytest.fixture
def monotonic() -> Monotonic:
    return Monotonic()


@pytest.fixture
def jwks(monotonic: Monotonic) -> JwksCache:
    return JwksCache(monotonic=monotonic)


@pytest.fixture
def verifier(jwks: JwksCache, http: httpx.AsyncClient) -> GoogleIdTokenVerifier:
    return GoogleIdTokenVerifier(client_ids=[GOOGLE_CLIENT_ID], jwks=jwks, http=http)


async def test_keys_are_cached_for_max_age(
    jwks: JwksCache, http: httpx.AsyncClient, certs: CertsServer, monotonic: Monotonic
) -> None:
    assert await jwks.get(http, GOOGLE_KEY_ID) is not None
    monotonic.value += 3599
    assert await jwks.get(http, GOOGLE_KEY_ID) is not None
    assert certs.requests == 1

    monotonic.value += 2
    await jwks.get(http, GOOGLE_KEY_ID)
    assert certs.requests == 2


@pytest.mark.parametrize(
    ("cache_control", "fresh_for"),
    [
        ("public, max-age=10", 300),  # clamped up to 5 minutes
        ("max-age=999999", 86400),  # clamped down to 24 hours
        ("no-cache", 300),  # no max-age: the minimum
    ],
)
async def test_max_age_is_clamped(
    jwks: JwksCache,
    http: httpx.AsyncClient,
    certs: CertsServer,
    monotonic: Monotonic,
    cache_control: str,
    fresh_for: int,
) -> None:
    certs.cache_control = cache_control
    await jwks.get(http, GOOGLE_KEY_ID)

    monotonic.value += fresh_for - 1
    await jwks.get(http, GOOGLE_KEY_ID)
    assert certs.requests == 1
    monotonic.value += 2
    await jwks.get(http, GOOGLE_KEY_ID)
    assert certs.requests == 2


async def test_unknown_key_id_refetches_once_per_interval(
    jwks: JwksCache, http: httpx.AsyncClient, certs: CertsServer, monotonic: Monotonic
) -> None:
    await jwks.get(http, GOOGLE_KEY_ID)
    monotonic.value += 31
    certs.key_ids = [GOOGLE_KEY_ID, "rotated-in"]

    assert await jwks.get(http, "rotated-in") is not None  # published since the last fetch
    assert certs.requests == 2
    assert await jwks.get(http, "forged-1") is None
    assert await jwks.get(http, "forged-2") is None
    assert certs.requests == 2  # forged key ids cannot make us refetch in a loop

    monotonic.value += 31
    assert await jwks.get(http, "forged-3") is None
    assert certs.requests == 3


async def test_stale_keys_are_used_while_google_is_unreachable(
    jwks: JwksCache, http: httpx.AsyncClient, certs: CertsServer, monotonic: Monotonic
) -> None:
    await jwks.get(http, GOOGLE_KEY_ID)
    certs.fail = True
    monotonic.value += 3601

    assert await jwks.get(http, GOOGLE_KEY_ID) is not None
    assert await jwks.get(http, GOOGLE_KEY_ID) is not None
    assert certs.requests == 2  # retried after the minimum interval, not on every request


async def test_no_keys_and_google_unreachable_is_503(
    jwks: JwksCache, http: httpx.AsyncClient, certs: CertsServer
) -> None:
    certs.fail = True

    with pytest.raises(ServiceUnavailable) as raised:
        await jwks.get(http, GOOGLE_KEY_ID)

    assert raised.value.code == "GOOGLE_UNAVAILABLE"


async def test_concurrent_requests_share_one_fetch(
    jwks: JwksCache, http: httpx.AsyncClient, certs: CertsServer
) -> None:
    keys = await asyncio.gather(*(jwks.get(http, GOOGLE_KEY_ID) for _ in range(5)))

    assert all(key is not None for key in keys)
    assert certs.requests == 1


async def test_valid_token(verifier: GoogleIdTokenVerifier) -> None:
    now = utc_now()

    identity = await verifier.verify(google_id_token(now=now), now=now)

    assert identity.subject == "google-sub-1"
    assert identity.email == "asha@example.com"
    assert identity.name == "Asha Verma"
    assert identity.expires_at - now <= timedelta(hours=1)


async def test_email_verified_as_string_is_accepted(verifier: GoogleIdTokenVerifier) -> None:
    now = utc_now()

    identity = await verifier.verify(google_id_token(now=now, email_verified="true"), now=now)

    assert identity.subject == "google-sub-1"


def _other_key_same_kid(now: Any) -> str:
    return google_id_token(now=now, key_id="attacker-key", headers={"kid": GOOGLE_KEY_ID})


@pytest.mark.parametrize(
    ("make_token", "code"),
    [
        (lambda now: google_id_token(now=now, aud="someone-else"), "INVALID_ID_TOKEN"),
        (lambda now: google_id_token(now=now, iss="https://evil.example"), "INVALID_ID_TOKEN"),
        (lambda now: google_id_token(now=now, sub=""), "INVALID_ID_TOKEN"),
        (lambda now: google_id_token(now=now, key_id="unknown-kid"), "INVALID_ID_TOKEN"),
        (_other_key_same_kid, "INVALID_ID_TOKEN"),
        (lambda now: google_id_token(now=now, headers={"alg": "RS512"}), "INVALID_ID_TOKEN"),
        (lambda now: "not.a.jwt", "INVALID_ID_TOKEN"),
        (lambda now: google_id_token(now=now - timedelta(hours=2)), "ID_TOKEN_EXPIRED"),
        (lambda now: google_id_token(now=now - timedelta(minutes=11)), "ID_TOKEN_EXPIRED"),
        (lambda now: google_id_token(now=now + timedelta(minutes=2)), "ID_TOKEN_EXPIRED"),
        (lambda now: google_id_token(now=now, email_verified=False), "EMAIL_NOT_VERIFIED"),
        (
            lambda now: google_id_token(now=now, email=None, email_verified=None),
            "EMAIL_NOT_VERIFIED",
        ),
    ],
)
async def test_rejected_tokens(
    verifier: GoogleIdTokenVerifier, make_token: Callable[[Any], str], code: str
) -> None:
    now = utc_now()

    with pytest.raises(Unauthorized) as raised:
        await verifier.verify(make_token(now), now=now)

    assert raised.value.code == code


async def test_tokens_up_to_ten_minutes_old_or_a_minute_ahead_are_accepted(
    verifier: GoogleIdTokenVerifier,
) -> None:
    now = utc_now()

    for issued in (now - timedelta(minutes=9, seconds=50), now + timedelta(seconds=50)):
        await verifier.verify(google_id_token(now=issued), now=now)


async def test_unconfigured_client_ids_is_503(jwks: JwksCache, http: httpx.AsyncClient) -> None:
    verifier = GoogleIdTokenVerifier(client_ids=[], jwks=jwks, http=http)

    with pytest.raises(AppError) as raised:
        await verifier.verify(google_id_token(now=utc_now()), now=utc_now())

    assert (raised.value.http_status, raised.value.code) == (503, "GOOGLE_SIGN_IN_UNAVAILABLE")


async def test_each_token_is_accepted_once(redis: Redis) -> None:
    now = utc_now()
    token = google_id_token(now=now)
    expires_at = now + timedelta(hours=1)

    await claim_single_use(redis, token, expires_at=expires_at, now=now)
    with pytest.raises(Unauthorized) as raised:
        await claim_single_use(redis, token, expires_at=expires_at, now=now)

    assert raised.value.code == "TOKEN_REPLAYED"
    [key] = await redis.keys("auth:gtoken:*")
    assert token not in key  # only a hash is stored
    assert 3590 < await redis.ttl(key) <= 3600
