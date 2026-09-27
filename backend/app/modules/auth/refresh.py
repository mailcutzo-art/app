"""Refresh-token material and the crash-grace cache.

Refresh tokens are 256-bit random strings; only their SHA-256 is stored. Each one is used once:
refreshing marks it used and issues a successor in the same family.
"""

import base64
import binascii
import hashlib
import os
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import orjson
import structlog
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from redis.asyncio import Redis

REFRESH_TOKEN_TTL = timedelta(days=30)  # sliding: every refresh starts a new 30 days
REFRESH_FAMILY_TTL = timedelta(days=90)  # hard cap from sign-in
REUSE_GRACE = timedelta(seconds=60)
_NONCE_BYTES = 12

log = structlog.stdlib.get_logger(__name__)


def new_refresh_token() -> str:
    return secrets.token_urlsafe(32)


def hash_refresh_token(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


@dataclass(frozen=True, slots=True)
class IssuedTokens:
    access_token: str
    access_expires_at: datetime
    refresh_token: str


class GraceCache:
    """The pair a rotation handed out, kept for ``REUSE_GRACE`` so that a client which crashed
    before saving it can present the old token again and receive the same pair.

    Entries are AES-256-GCM encrypted (bound to the old token's hash), so Redis never holds a
    usable refresh token in the clear.
    """

    def __init__(self, redis: Redis, key: bytes) -> None:
        self._redis = redis
        self._aead = AESGCM(key)

    async def put(self, used_token_hash: bytes, tokens: IssuedTokens) -> None:
        plaintext = orjson.dumps(
            {
                "access": tokens.access_token,
                "exp": int(tokens.access_expires_at.timestamp()),
                "refresh": tokens.refresh_token,
            }
        )
        nonce = os.urandom(_NONCE_BYTES)
        sealed = nonce + self._aead.encrypt(nonce, plaintext, used_token_hash)
        await self._redis.set(
            _key(used_token_hash),
            base64.b64encode(sealed).decode(),
            ex=int(REUSE_GRACE.total_seconds()),
        )

    async def get(self, used_token_hash: bytes) -> IssuedTokens | None:
        raw = await self._redis.get(_key(used_token_hash))
        if raw is None:
            return None
        try:
            sealed = base64.b64decode(raw)
            plaintext = self._aead.decrypt(
                sealed[:_NONCE_BYTES], sealed[_NONCE_BYTES:], used_token_hash
            )
            data = orjson.loads(plaintext)
            return IssuedTokens(
                access_token=data["access"],
                access_expires_at=datetime.fromtimestamp(data["exp"], UTC),
                refresh_token=data["refresh"],
            )
        except (InvalidTag, binascii.Error, orjson.JSONDecodeError, KeyError, TypeError):
            # A different APP_REFRESH_GRACE_KEY on another replica, or a corrupt entry.
            log.warning("auth.refresh_grace_unreadable")
            return None


def _key(token_hash: bytes) -> str:
    return f"auth:refresh_grace:{token_hash.hex()}"
