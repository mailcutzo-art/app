"""Google ID-token verification, with Google's signing keys cached in process.

The app signs in through Credential Manager and sends the resulting ID token. It is accepted
only if it is signed by Google (RS256, key from the JWKS endpoint), issued for one of our OAuth
client ids by Google, unexpired, recent (``iat`` within 10 minutes) and for a verified email.
``claim_single_use`` then makes each token usable once.
"""

import asyncio
import hashlib
import math
import re
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

import httpx
import jwt
import structlog
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
from fastapi import Depends
from redis.asyncio import Redis
from starlette.requests import HTTPConnection

from app.core.config import SettingsDep
from app.core.errors import ServiceUnavailable, Unauthorized

GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
MAX_TOKEN_AGE = timedelta(minutes=10)
MAX_CLOCK_SKEW = timedelta(seconds=60)
_ALGORITHM = "RS256"
_MIN_REPLAY_GUARD = timedelta(seconds=60)
_MAX_AGE = re.compile(r"max-age=(\d+)")

log = structlog.stdlib.get_logger(__name__)


@dataclass(frozen=True, slots=True)
class GoogleIdentity:
    subject: str
    email: str | None
    name: str | None
    expires_at: datetime


class JwksCache:
    """Google's public keys, kept for the response's ``max-age`` (clamped to [min_ttl, max_ttl]).

    An unknown key id triggers one early refetch (Google publishes new keys before using them),
    at most once per ``refetch_interval`` so forged key ids cannot make us hammer Google. If a
    refresh fails, the previous keys keep working until Google answers again.
    """

    def __init__(
        self,
        url: str = GOOGLE_CERTS_URL,
        *,
        min_ttl: timedelta = timedelta(minutes=5),
        max_ttl: timedelta = timedelta(hours=24),
        refetch_interval: timedelta = timedelta(seconds=30),
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._url = url
        self._min_ttl = min_ttl.total_seconds()
        self._max_ttl = max_ttl.total_seconds()
        self._refetch_interval = refetch_interval.total_seconds()
        self._monotonic = monotonic
        self._keys: dict[str, RSAPublicKey] = {}
        self._fresh_until = -math.inf
        self._fetched_at = -math.inf
        self._lock = asyncio.Lock()

    async def get(self, http: httpx.AsyncClient, key_id: str) -> RSAPublicKey | None:
        if self._monotonic() >= self._fresh_until:
            await self._refresh(http, force=False)
        key = self._keys.get(key_id)
        if key is None and self._monotonic() - self._fetched_at >= self._refetch_interval:
            await self._refresh(http, force=True)
            key = self._keys.get(key_id)
        return key

    async def _refresh(self, http: httpx.AsyncClient, *, force: bool) -> None:
        async with self._lock:
            now = self._monotonic()
            # Another request may have refreshed while this one waited for the lock.
            if force and now - self._fetched_at < self._refetch_interval:
                return
            if not force and now < self._fresh_until:
                return
            self._fetched_at = now
            try:
                response = await http.get(self._url)
                response.raise_for_status()
                keys = _parse_jwks(response.json())
            except (httpx.HTTPError, ValueError) as exc:
                if not self._keys:
                    raise ServiceUnavailable(
                        "Google sign-in is temporarily unavailable.", code="GOOGLE_UNAVAILABLE"
                    ) from exc
                log.warning("google.jwks_refresh_failed", error_type=type(exc).__name__)
                self._fresh_until = now + self._min_ttl
                return
            self._keys = keys
            self._fresh_until = now + self._ttl(response.headers.get("cache-control", ""))

    def _ttl(self, cache_control: str) -> float:
        match = _MAX_AGE.search(cache_control)
        max_age = float(match.group(1)) if match else self._min_ttl
        return min(max(max_age, self._min_ttl), self._max_ttl)


def _parse_jwks(document: Any) -> dict[str, RSAPublicKey]:
    """RSA signing keys by key id; raises ``ValueError`` if there are none."""
    keys: dict[str, RSAPublicKey] = {}
    entries = document.get("keys") if isinstance(document, dict) else None
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict) or entry.get("kty") != "RSA":
            continue
        key_id = entry.get("kid")
        try:
            key = jwt.PyJWK(entry, algorithm=_ALGORITHM).key
        except (jwt.PyJWKError, jwt.InvalidKeyError):
            continue
        if isinstance(key_id, str) and isinstance(key, RSAPublicKey):
            keys[key_id] = key
    if not keys:
        raise ValueError("no usable RSA keys in the JWKS document")
    return keys


class GoogleIdTokenVerifier:
    def __init__(
        self, *, client_ids: Sequence[str], jwks: JwksCache, http: httpx.AsyncClient
    ) -> None:
        self._client_ids = list(client_ids)
        self._jwks = jwks
        self._http = http

    async def verify(self, token: str, *, now: datetime) -> GoogleIdentity:
        """Verify ``token``; raise ``Unauthorized`` (401) with a specific code if it fails."""
        if not self._client_ids:
            raise ServiceUnavailable(
                "Google sign-in isn't set up on this server.", code="GOOGLE_SIGN_IN_UNAVAILABLE"
            )
        try:
            header = jwt.get_unverified_header(token)
        except jwt.InvalidTokenError as exc:
            raise _invalid() from exc
        key_id = header.get("kid")
        if header.get("alg") != _ALGORITHM or not isinstance(key_id, str):
            raise _invalid()
        key = await self._jwks.get(self._http, key_id)
        if key is None:
            raise _invalid()
        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=[_ALGORITHM],
                audience=self._client_ids,
                issuer=GOOGLE_ISSUERS,
                options={
                    "require": ["iss", "aud", "sub", "iat", "exp"],
                    # Time is checked below against the injected clock.
                    "verify_exp": False,
                    "verify_iat": False,
                    "verify_nbf": False,
                },
            )
            subject, issued_at, expires_at = _identity_claims(claims)
        except (jwt.InvalidTokenError, TypeError, ValueError, OverflowError) as exc:
            raise _invalid() from exc
        if now >= expires_at or not now - MAX_TOKEN_AGE <= issued_at <= now + MAX_CLOCK_SKEW:
            raise Unauthorized(
                "That sign-in has expired. Please try again.", code="ID_TOKEN_EXPIRED"
            )
        if claims.get("email_verified") not in (True, "true"):
            raise Unauthorized(
                "Your Google email address isn't verified.", code="EMAIL_NOT_VERIFIED"
            )
        email, name = claims.get("email"), claims.get("name")
        return GoogleIdentity(
            subject=subject,
            email=email if isinstance(email, str) else None,
            name=name if isinstance(name, str) else None,
            expires_at=expires_at,
        )


def _identity_claims(claims: dict[str, Any]) -> tuple[str, datetime, datetime]:
    subject, issued_at, expires_at = claims["sub"], claims["iat"], claims["exp"]
    if not isinstance(subject, str) or not subject:
        raise ValueError("sub must be a non-empty string")
    for value in (issued_at, expires_at):
        if isinstance(value, bool) or not isinstance(value, int | float):
            raise TypeError("iat and exp must be numbers")
    return subject, datetime.fromtimestamp(issued_at, UTC), datetime.fromtimestamp(expires_at, UTC)


def _invalid() -> Unauthorized:
    return Unauthorized("That Google sign-in could not be verified.", code="INVALID_ID_TOKEN")


async def claim_single_use(
    redis: Redis, token: str, *, expires_at: datetime, now: datetime
) -> None:
    """Accept each ID token once: a replay (even of a valid token) gets 401 ``TOKEN_REPLAYED``.

    The marker lives until the token expires (at least a minute), after which the token is
    rejected as expired anyway.
    """
    ttl = max(expires_at - now, _MIN_REPLAY_GUARD)
    key = f"auth:gtoken:{hashlib.sha256(token.encode()).hexdigest()}"
    if not await redis.set(key, "1", nx=True, ex=math.ceil(ttl.total_seconds())):
        raise Unauthorized(
            "That sign-in was already used. Please try again.", code="TOKEN_REPLAYED"
        )


async def get_google_verifier(conn: HTTPConnection, settings: SettingsDep) -> GoogleIdTokenVerifier:
    """FastAPI dependency (tests override it with a verifier using a local key set)."""
    jwks: JwksCache = conn.app.state.google_jwks
    http: httpx.AsyncClient = conn.app.state.resources.http
    return GoogleIdTokenVerifier(client_ids=settings.google_client_ids, jwks=jwks, http=http)


GoogleVerifierDep = Annotated[GoogleIdTokenVerifier, Depends(get_google_verifier)]
