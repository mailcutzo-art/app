"""Settings parsing and validation."""

import os
from ipaddress import ip_network
from typing import Any

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pydantic import ValidationError

from app.core.config import DEV_DATABASE_URL, Environment, Settings
from tests.helpers import ed25519_pem_pair, prod_secrets

PROD_URLS = {
    "database_url": "postgresql+asyncpg://quiz:pw@db:5432/quiz",
    "redis_url": "redis://:pw@redis:6379/0",
}


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Only what a test passes explicitly may influence the settings."""
    for name in [name for name in os.environ if name.startswith("APP_")]:
        monkeypatch.delenv(name)


def settings(**values: Any) -> Settings:
    return Settings(_env_file=None, **values)


def test_defaults_target_local_dev_services_with_ephemeral_keys() -> None:
    config = settings()

    assert config.env is Environment.DEV
    assert config.database_url.get_secret_value() == DEV_DATABASE_URL
    assert config.dev_login_enabled is False
    assert config.jwt_key_id is not None
    assert config.jwt_key_id.startswith("dev-")
    assert config.jwt_private_key is not None
    assert config.jwt_public_key is not None
    # The generated pair is a valid, matching Ed25519 pair.
    settings(
        jwt_private_key=config.jwt_private_key.get_secret_value(),
        jwt_public_key=config.jwt_public_key,
        jwt_key_id="copy",
    )


def test_empty_environment_values_count_as_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("APP_JWT_PRIVATE_KEY", "APP_JWT_PUBLIC_KEY", "APP_JWT_KEY_ID", "APP_CORS_ORIGINS"):
        monkeypatch.setenv(name, "")

    config = settings()

    assert config.jwt_key_id is not None
    assert config.jwt_key_id.startswith("dev-")
    assert config.cors_origins == []


def test_every_process_gets_a_different_ephemeral_key() -> None:
    assert settings().jwt_key_id != settings().jwt_key_id


def test_valid_production_settings() -> None:
    config = settings(env="prod", **PROD_URLS, **prod_secrets())

    assert config.is_prod
    assert config.jwt_key_id == "k1"


def test_production_rejects_dev_login() -> None:
    with pytest.raises(ValidationError, match="APP_DEV_LOGIN_ENABLED must be false"):
        settings(env="prod", dev_login_enabled=True, **PROD_URLS, **prod_secrets())


def test_production_requires_signing_keys() -> None:
    with pytest.raises(ValidationError, match="APP_JWT_PRIVATE_KEY, APP_JWT_PUBLIC_KEY"):
        settings(env="prod", **PROD_URLS)


def test_production_requires_explicit_database_and_redis_urls() -> None:
    with pytest.raises(ValidationError) as raised:
        settings(env="prod", **prod_secrets())

    message = str(raised.value)
    assert "APP_DATABASE_URL must be set explicitly" in message
    assert "APP_REDIS_URL must be set explicitly" in message


def test_signing_keys_must_be_configured_together() -> None:
    private_pem, _ = ed25519_pem_pair()

    with pytest.raises(ValidationError, match="must be set together"):
        settings(jwt_private_key=private_pem)


def test_mismatched_signing_keys_are_rejected() -> None:
    private_pem, _ = ed25519_pem_pair()
    _, other_public_pem = ed25519_pem_pair()

    with pytest.raises(ValidationError, match="does not match") as raised:
        settings(jwt_private_key=private_pem, jwt_public_key=other_public_pem, jwt_key_id="k")

    assert "PRIVATE KEY-----" not in str(raised.value)


def test_non_ed25519_keys_are_rejected() -> None:
    key = ec.generate_private_key(ec.SECP256R1())
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    public_pem = (
        key.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )

    with pytest.raises(ValidationError, match="must be Ed25519"):
        settings(jwt_private_key=private_pem, jwt_public_key=public_pem, jwt_key_id="k")


def test_garbage_key_is_rejected_without_echoing_it() -> None:
    _, public_pem = ed25519_pem_pair()

    with pytest.raises(ValidationError, match="not a valid unencrypted PEM") as raised:
        settings(jwt_private_key="sekrit-not-a-pem", jwt_public_key=public_pem, jwt_key_id="k")

    assert "sekrit-not-a-pem" not in str(raised.value)


def test_single_line_pems_with_escaped_newlines_are_accepted() -> None:
    private_pem, public_pem = ed25519_pem_pair()

    config = settings(
        jwt_private_key=private_pem.replace("\n", "\\n"),
        jwt_public_key=public_pem.replace("\n", "\\n"),
        jwt_key_id="k",
    )

    assert config.jwt_public_key == public_pem


def test_lists_are_read_from_comma_separated_environment_values(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("APP_CORS_ORIGINS", "https://a.example, https://b.example")
    monkeypatch.setenv("APP_GOOGLE_CLIENT_IDS", "web.apps.googleusercontent.com")
    monkeypatch.setenv("APP_TRUSTED_PROXIES", "10.0.0.0/8, 127.0.0.1")
    monkeypatch.setenv("APP_FEATURE_FLAGS", '{"arena": true}')

    config = settings()

    assert config.cors_origins == ["https://a.example", "https://b.example"]
    assert config.google_client_ids == ["web.apps.googleusercontent.com"]
    assert config.trusted_proxies == [ip_network("10.0.0.0/8"), ip_network("127.0.0.1/32")]
    assert config.feature_flags == {"arena": True}


@pytest.mark.parametrize(
    "url",
    [
        "postgresql://quiz:pw@db/quiz",
        "postgres://quiz:pw@db/quiz",
        "postgresql+asyncpg://quiz:pw@db/quiz",
    ],
)
def test_database_urls_use_asyncpg(url: str) -> None:
    config = settings(database_url=url)

    assert config.database_url.get_secret_value() == "postgresql+asyncpg://quiz:pw@db/quiz"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("database_url", "mysql://db/quiz"),
        ("redis_url", "http://redis:6379"),
        ("log_level", "LOUD"),
        ("trusted_proxies", "not-an-ip"),
        ("min_build", -1),
    ],
)
def test_invalid_values_are_rejected(field: str, value: object) -> None:
    with pytest.raises(ValidationError):
        settings(**{field: value})


def test_secrets_are_hidden_from_repr() -> None:
    config = settings(database_url="postgresql://quiz:db-password@db/quiz")

    assert "db-password" not in repr(config)
    assert "PRIVATE KEY" not in repr(config)
