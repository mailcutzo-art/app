"""Access tokens: EdDSA JWTs with a key id, verified against the injected clock."""

import base64
import hashlib
import hmac
import json
import uuid
from datetime import timedelta

import jwt
import pytest

from app.core.clock import utc_now
from app.core.config import JwtKeys
from app.core.errors import Unauthorized
from app.core.tokens import ACCESS_TOKEN_TTL, decode_access_token, issue_access_token
from tests.helpers import ed25519_pem_pair

USER_ID = uuid.uuid4()
SESSION_ID = uuid.uuid4()


@pytest.fixture(scope="module")
def keys() -> JwtKeys:
    private_pem, public_pem = ed25519_pem_pair()
    return JwtKeys(key_id="k1", private_pem=private_pem, public_pem=public_pem)


def issue(keys: JwtKeys, **overrides: object) -> str:
    now = overrides.pop("now", utc_now())
    token, _ = issue_access_token(
        keys,
        user_id=USER_ID,
        session_id=SESSION_ID,
        roles=["user"],
        token_version=3,
        now=now,  # type: ignore[arg-type]
    )
    return token


def test_round_trip(keys: JwtKeys) -> None:
    now = utc_now()
    token, expires_at = issue_access_token(
        keys,
        user_id=USER_ID,
        session_id=SESSION_ID,
        roles=["user", "admin"],
        token_version=3,
        now=now,
    )

    claims = decode_access_token(keys, token, now=now)

    assert jwt.get_unverified_header(token) == {"alg": "EdDSA", "kid": "k1", "typ": "JWT"}
    payload = jwt.decode(token, options={"verify_signature": False})
    assert set(payload) == {"sub", "sid", "roles", "ver", "iat", "exp", "jti"}
    assert (claims.user_id, claims.session_id) == (USER_ID, SESSION_ID)
    assert claims.roles == {"user", "admin"}
    assert claims.token_version == 3
    assert claims.expires_at == expires_at
    assert timedelta(minutes=14) < expires_at - now <= ACCESS_TOKEN_TTL


def test_expiry_allows_30_seconds_of_leeway(keys: JwtKeys) -> None:
    now = utc_now()
    token = issue(keys, now=now)

    decode_access_token(keys, token, now=now + ACCESS_TOKEN_TTL + timedelta(seconds=29))
    with pytest.raises(Unauthorized) as raised:
        decode_access_token(keys, token, now=now + ACCESS_TOKEN_TTL + timedelta(seconds=31))

    assert raised.value.code == "ACCESS_TOKEN_EXPIRED"


def test_unknown_key_id_is_rejected(keys: JwtKeys) -> None:
    rotated = JwtKeys(key_id="k2", private_pem=keys.private_pem, public_pem=keys.public_pem)

    with pytest.raises(Unauthorized) as raised:
        decode_access_token(keys, issue(rotated), now=utc_now())

    assert raised.value.code == "INVALID_ACCESS_TOKEN"


def test_signature_from_another_key_is_rejected(keys: JwtKeys) -> None:
    other_private, _ = ed25519_pem_pair()
    forged = JwtKeys(key_id="k1", private_pem=other_private, public_pem=keys.public_pem)

    with pytest.raises(Unauthorized, match="not valid"):
        decode_access_token(keys, issue(forged), now=utc_now())


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def test_algorithm_confusion_is_rejected(keys: JwtKeys) -> None:
    payload = jwt.decode(issue(keys), options={"verify_signature": False})
    # HMAC-"signed" with the public key (the classic confusion attack), built by hand because
    # PyJWT refuses to; and a token with no signature at all.
    signing_input = ".".join(
        _b64(json.dumps(part).encode())
        for part in ({"alg": "HS256", "kid": "k1", "typ": "JWT"}, payload)
    )
    mac = hmac.new(keys.public_pem.encode(), signing_input.encode(), hashlib.sha256).digest()
    hs256 = f"{signing_input}.{_b64(mac)}"
    unsigned = jwt.encode(payload, None, algorithm="none", headers={"kid": "k1"})

    for token in (hs256, unsigned):
        with pytest.raises(Unauthorized):
            decode_access_token(keys, token, now=utc_now())


@pytest.mark.parametrize(
    "claims",
    [
        {"ver": True},
        {"ver": "3"},
        {"sub": "not-a-uuid"},
        {"roles": "admin"},
        {"sid": None},
    ],
)
def test_malformed_claims_are_rejected(keys: JwtKeys, claims: dict[str, object]) -> None:
    payload = jwt.decode(issue(keys), options={"verify_signature": False}) | claims
    token = jwt.encode(
        {k: v for k, v in payload.items() if v is not None},
        keys.private_pem,
        algorithm="EdDSA",
        headers={"kid": "k1"},
    )

    with pytest.raises(Unauthorized):
        decode_access_token(keys, token, now=utc_now())


@pytest.mark.parametrize("token", ["", "garbage", "a.b.c", "eyJhbGciOiJFZERTQSJ9.e30."])
def test_garbage_is_rejected(keys: JwtKeys, token: str) -> None:
    with pytest.raises(Unauthorized):
        decode_access_token(keys, token, now=utc_now())
