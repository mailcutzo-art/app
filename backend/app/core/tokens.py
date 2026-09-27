"""Access tokens: short-lived EdDSA (Ed25519) JWTs naming the user, device session and roles.

Time checks use the caller's clock (``now``) rather than PyJWT's, so they follow ``ClockDep``.
"""

import functools
import secrets
import uuid
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from app.core.config import JwtKeys
from app.core.errors import Unauthorized

ACCESS_TOKEN_TTL = timedelta(minutes=15)
VERIFY_LEEWAY = timedelta(seconds=30)
_ALGORITHM = "EdDSA"
_REQUIRED_CLAIMS = ["sub", "sid", "roles", "ver", "iat", "exp", "jti"]


@dataclass(frozen=True, slots=True)
class AccessClaims:
    user_id: uuid.UUID
    session_id: uuid.UUID
    roles: frozenset[str]
    token_version: int
    expires_at: datetime


def issue_access_token(
    keys: JwtKeys,
    *,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    roles: Iterable[str],
    token_version: int,
    now: datetime,
) -> tuple[str, datetime]:
    """Sign a token valid for ``ACCESS_TOKEN_TTL``; returns it with its expiry time."""
    issued_at = int(now.timestamp())
    expires_at = issued_at + int(ACCESS_TOKEN_TTL.total_seconds())
    claims = {
        "sub": str(user_id),
        "sid": str(session_id),
        "roles": sorted(roles),
        "ver": token_version,
        "iat": issued_at,
        "exp": expires_at,
        "jti": secrets.token_urlsafe(12),
    }
    token = jwt.encode(
        claims, _private_key(keys.private_pem), algorithm=_ALGORITHM, headers={"kid": keys.key_id}
    )
    return token, datetime.fromtimestamp(expires_at, UTC)


def decode_access_token(keys: JwtKeys, token: str, *, now: datetime) -> AccessClaims:
    """Verify signature, key id and expiry (with leeway); raise ``Unauthorized`` otherwise."""
    try:
        key_id = jwt.get_unverified_header(token).get("kid")
    except jwt.InvalidTokenError as exc:
        raise _invalid() from exc
    # Key rotation adds the previous public keys to this map.
    verification_keys = {keys.key_id: keys.public_pem}
    if not isinstance(key_id, str) or key_id not in verification_keys:
        raise _invalid()
    public_pem = verification_keys[key_id]
    try:
        payload = jwt.decode(
            token,
            _public_key(public_pem),
            algorithms=[_ALGORITHM],
            options={
                "require": _REQUIRED_CLAIMS,
                "verify_exp": False,
                "verify_iat": False,
                "verify_nbf": False,
            },
        )
        claims = AccessClaims(
            user_id=uuid.UUID(payload["sub"]),
            session_id=uuid.UUID(payload["sid"]),
            roles=frozenset(_strings(payload["roles"])),
            token_version=_integer(payload["ver"]),
            expires_at=datetime.fromtimestamp(_integer(payload["exp"]), UTC),
        )
    except (jwt.InvalidTokenError, TypeError, ValueError, OverflowError) as exc:
        raise _invalid() from exc
    if now > claims.expires_at + VERIFY_LEEWAY:
        raise Unauthorized("Your session needs refreshing.", code="ACCESS_TOKEN_EXPIRED")
    return claims


def _invalid() -> Unauthorized:
    return Unauthorized("Your session is not valid.", code="INVALID_ACCESS_TOKEN")


def _integer(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError("expected an integer claim")
    return value


def _strings(value: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise TypeError("expected a list of strings")
    return value


@functools.lru_cache(maxsize=4)
def _private_key(pem: str) -> Ed25519PrivateKey:
    key = serialization.load_pem_private_key(pem.encode(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise TypeError("the JWT signing key must be Ed25519")
    return key


@functools.lru_cache(maxsize=8)
def _public_key(pem: str) -> Ed25519PublicKey:
    key = serialization.load_pem_public_key(pem.encode())
    if not isinstance(key, Ed25519PublicKey):
        raise TypeError("JWT verification keys must be Ed25519")
    return key
