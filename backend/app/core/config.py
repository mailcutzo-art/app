"""Application settings, read from ``APP_*`` environment variables and an optional ``.env`` file."""

import base64
import binascii
import secrets
from dataclasses import dataclass
from enum import StrEnum
from functools import lru_cache
from typing import Annotated, Any, Self

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from fastapi import Depends
from pydantic import (
    AwareDatetime,
    Field,
    IPvAnyNetwork,
    SecretStr,
    field_validator,
    model_validator,
)
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict
from starlette.requests import HTTPConnection

DEV_DATABASE_URL = "postgresql+asyncpg://quiz:quiz@127.0.0.1:54329/quiz_dev"
DEV_REDIS_URL = "redis://127.0.0.1:63790/0"

_ASYNCPG_SCHEME = "postgresql+asyncpg://"
_POSTGRES_ALIASES = ("postgresql://", "postgres://")
_REDIS_SCHEMES = ("redis://", "rediss://", "unix://")
_GRACE_KEY_BYTES = 32


class Environment(StrEnum):
    DEV = "dev"
    TEST = "test"
    PROD = "prod"


@dataclass(frozen=True, slots=True)
class JwtKeys:
    key_id: str
    private_pem: str
    public_pem: str


class Settings(BaseSettings):
    """Process configuration shared by the ``api``, ``rt`` and ``worker`` processes.

    List settings accept a comma-separated string (``APP_CORS_ORIGINS=https://a,https://b``);
    ``feature_flags`` takes a JSON object (``APP_FEATURE_FLAGS='{"tournaments": true}'``).
    Empty values count as unset.
    """

    model_config = SettingsConfigDict(
        env_prefix="APP_",
        env_file=".env",
        env_file_encoding="utf-8",
        env_ignore_empty=True,
        extra="ignore",
    )

    env: Environment = Environment.DEV
    log_level: str = "INFO"

    database_url: SecretStr = SecretStr(DEV_DATABASE_URL)
    database_pool_size: int = Field(default=10, ge=1)
    database_max_overflow: int = Field(default=10, ge=0)
    redis_url: SecretStr = SecretStr(DEV_REDIS_URL)

    # Ed25519 key pair (PEM) used to sign access tokens, and the key id put in the JWT header.
    # dev/test generate an ephemeral pair when none is configured; prod requires all three.
    jwt_private_key: SecretStr | None = None
    jwt_public_key: str | None = None
    jwt_key_id: str | None = None
    # AES-256-GCM key (32 bytes, base64) encrypting the refresh-token pairs kept for crash
    # retries. Same value on every api replica; generated per process in dev/test.
    refresh_grace_key: SecretStr | None = None

    google_client_ids: Annotated[list[str], NoDecode] = []
    dev_login_enabled: bool = False
    cors_origins: Annotated[list[str], NoDecode] = []
    # Reverse proxies whose X-Forwarded-For header is trusted (IPs or CIDRs). Empty: trust none.
    trusted_proxies: Annotated[list[IPvAnyNetwork], NoDecode] = []

    min_build: int = Field(default=1, ge=0)
    maintenance: bool = False
    # Shown on the app's Maintenance screen while ``maintenance`` is on.
    maintenance_message: str | None = None
    # When maintenance should end, and when planned maintenance starts (ISO 8601 with offset).
    maintenance_until: AwareDatetime | None = None
    maintenance_at: AwareDatetime | None = None
    # Where suspended players can appeal (an email address or URL), shown on the Suspended screen.
    appeal_contact: str = "support@example.com"
    feature_flags: dict[str, bool] = {}

    # Question bank loaded by ``python -m app.modules.content.seed`` (relative to the working dir).
    content_dir: str = "../content"

    # Realtime (docs/protocol.md, docs/realtime-engine.md). Every live timing is a setting so
    # tests can run games in seconds; the defaults are the product rules.
    # This rt node's id in leases and ``rt:conn``; generated per process when unset.
    rt_node_id: str | None = None
    rt_ticket_ttl_s: int = Field(default=30, ge=1)
    # Heartbeat interval announced to clients (whole seconds) and the silence that ends a
    # connection, by state: idle, queued (or in a room) and in a match.
    rt_hb_idle_s: int = Field(default=30, ge=1)
    rt_hb_queue_s: int = Field(default=10, ge=1)
    rt_hb_match_s: int = Field(default=5, ge=1)
    rt_stale_idle_s: float = Field(default=70.0, gt=0)
    rt_stale_queue_s: float = Field(default=25.0, gt=0)
    rt_stale_match_s: float = Field(default=12.0, gt=0)
    # Owner leases, the failover scanner and the per-match timers.
    rt_lease_ms: int = Field(default=4000, ge=100)
    rt_lease_renew_s: float = Field(default=1.0, gt=0)
    rt_scan_interval_s: float = Field(default=0.25, gt=0)
    rt_overdue_ms: int = Field(default=1000, ge=0)
    # Quick Battle and Practice Bot games.
    match_questions: int = Field(default=7, ge=1, le=20)
    match_limit_ms: int = Field(default=15_000, gt=1000)
    match_reveal_ms: int = Field(default=3000, ge=0)
    match_countdown_ms: int = Field(default=3000, ge=0)
    match_ready_ms: int = Field(default=10_000, ge=100)
    match_show_lead_ms: int = Field(default=400, ge=0)
    match_answer_grace_ms: int = Field(default=250, ge=0)
    match_grace_ms: int = Field(default=30_000, ge=100)
    match_drain_grace_ms: int = Field(default=60_000, ge=0)
    match_void_window_ms: int = Field(default=5000, ge=0)
    match_rematch_window_ms: int = Field(default=15_000, ge=100)
    match_rematch_max: int = Field(default=3, ge=0)
    casual_fee: int = Field(default=5, ge=0)
    # Scales the Practice Bot's answer times (tests shorten games; the model's median is 6 s).
    match_bot_time_scale: float = Field(default=1.0, gt=0)
    # Matchmaking: offers, automatic cancels, queue ticks and abort cooldowns.
    mm_timeout_s: float = Field(default=45.0, gt=0)
    mm_first_timeout_s: float = Field(default=20.0, gt=0)
    mm_keep_s: float = Field(default=60.0, gt=0)
    mm_max_wait_s: float = Field(default=105.0, gt=0)
    mm_offline_s: float = Field(default=10.0, gt=0)
    mm_background_s: float = Field(default=10.0, gt=0)
    mm_tick_s: float = Field(default=0.5, gt=0)
    mm_cooldown_s: int = Field(default=300, ge=1)
    mm_abort_limit: int = Field(default=3, ge=1)
    mm_rated_pair_limit: int = Field(default=3, ge=1)
    # Settlement retries (worker) pick up matches waiting longer than this.
    settle_retry_after_s: float = Field(default=10.0, ge=0)

    @field_validator("google_client_ids", "cors_origins", "trusted_proxies", mode="before")
    @classmethod
    def _split_comma_separated(cls, value: Any) -> Any:
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    @field_validator("log_level")
    @classmethod
    def _normalize_log_level(cls, value: str) -> str:
        level = value.upper()
        if level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            raise ValueError("must be one of DEBUG, INFO, WARNING, ERROR, CRITICAL")
        return level

    @field_validator("database_url", mode="before")
    @classmethod
    def _normalize_database_url(cls, value: Any) -> Any:
        if not isinstance(value, str):
            return value
        for alias in _POSTGRES_ALIASES:
            if value.startswith(alias):
                return _ASYNCPG_SCHEME + value.removeprefix(alias)
        if not value.startswith(_ASYNCPG_SCHEME):
            raise ValueError(f"must be a {_ASYNCPG_SCHEME} URL")
        return value

    @field_validator("redis_url")
    @classmethod
    def _check_redis_url(cls, value: SecretStr) -> SecretStr:
        if not value.get_secret_value().startswith(_REDIS_SCHEMES):
            raise ValueError("must be a redis://, rediss:// or unix:// URL")
        return value

    @field_validator("refresh_grace_key")
    @classmethod
    def _check_refresh_grace_key(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None:
            _decode_grace_key(value.get_secret_value())
        return value

    @model_validator(mode="after")
    def _check_environment(self) -> Self:
        if self.env is Environment.PROD:
            self._check_production()
        self._resolve_signing_key()
        if self.refresh_grace_key is None:
            key = secrets.token_bytes(_GRACE_KEY_BYTES)
            self.refresh_grace_key = SecretStr(base64.b64encode(key).decode())
        return self

    @property
    def is_prod(self) -> bool:
        return self.env is Environment.PROD

    @property
    def jwt_keys(self) -> JwtKeys:
        """The access-token signing key (always set once validation has run)."""
        if self.jwt_private_key is None or self.jwt_public_key is None or not self.jwt_key_id:
            raise RuntimeError("JWT keys are resolved during validation")
        return JwtKeys(
            self.jwt_key_id, self.jwt_private_key.get_secret_value(), self.jwt_public_key
        )

    @property
    def refresh_grace_key_bytes(self) -> bytes:
        if self.refresh_grace_key is None:
            raise RuntimeError("the refresh grace key is resolved during validation")
        return _decode_grace_key(self.refresh_grace_key.get_secret_value())

    def _check_production(self) -> None:
        problems: list[str] = []
        if self.dev_login_enabled:
            problems.append("APP_DEV_LOGIN_ENABLED must be false in prod")
        if self.jwt_private_key is None or self.jwt_public_key is None or not self.jwt_key_id:
            problems.append(
                "APP_JWT_PRIVATE_KEY, APP_JWT_PUBLIC_KEY and APP_JWT_KEY_ID are required"
            )
        for name in ("database_url", "redis_url", "refresh_grace_key"):
            if name not in self.model_fields_set:
                problems.append(f"APP_{name.upper()} must be set explicitly")
        if problems:
            raise ValueError("invalid production settings: " + "; ".join(problems))

    def _resolve_signing_key(self) -> None:
        configured = (self.jwt_private_key, self.jwt_public_key, self.jwt_key_id)
        if all(item is None for item in configured):
            # Only reachable outside prod (prod requires the keys): use an ephemeral key pair.
            private_pem, public_pem = _generate_ed25519_pem()
            self.jwt_private_key = SecretStr(private_pem)
            self.jwt_public_key = public_pem
            self.jwt_key_id = f"dev-{secrets.token_hex(4)}"
            return
        if self.jwt_private_key is None or self.jwt_public_key is None or not self.jwt_key_id:
            raise ValueError(
                "APP_JWT_PRIVATE_KEY, APP_JWT_PUBLIC_KEY and APP_JWT_KEY_ID must be set together"
            )
        private_pem = _unescape_pem(self.jwt_private_key.get_secret_value())
        public_pem = _unescape_pem(self.jwt_public_key)
        _check_ed25519_pair(private_pem, public_pem)
        self.jwt_private_key = SecretStr(private_pem)
        self.jwt_public_key = public_pem


def _decode_grace_key(value: str) -> bytes:
    try:
        key = base64.b64decode(value.replace("-", "+").replace("_", "/") + "=" * (-len(value) % 4))
    except (binascii.Error, ValueError) as exc:
        raise ValueError("APP_REFRESH_GRACE_KEY must be base64") from exc
    if len(key) != _GRACE_KEY_BYTES:
        raise ValueError("APP_REFRESH_GRACE_KEY must decode to exactly 32 bytes")
    return key


def _unescape_pem(pem: str) -> str:
    """Allow PEMs written on one line with literal ``\\n`` separators (common in env files)."""
    return pem.replace("\\n", "\n").strip() + "\n"


def _generate_ed25519_pem() -> tuple[str, str]:
    key = Ed25519PrivateKey.generate()
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    public_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return private_pem.decode(), public_pem.decode()


def _check_ed25519_pair(private_pem: str, public_pem: str) -> None:
    # Messages deliberately never echo key material.
    try:
        private_key = serialization.load_pem_private_key(private_pem.encode(), password=None)
    except (ValueError, TypeError) as exc:
        raise ValueError("APP_JWT_PRIVATE_KEY is not a valid unencrypted PEM private key") from exc
    try:
        public_key = serialization.load_pem_public_key(public_pem.encode())
    except (ValueError, TypeError) as exc:
        raise ValueError("APP_JWT_PUBLIC_KEY is not a valid PEM public key") from exc
    if not isinstance(private_key, Ed25519PrivateKey) or not isinstance(
        public_key, Ed25519PublicKey
    ):
        raise ValueError("JWT signing keys must be Ed25519 (EdDSA)")
    raw = serialization.Encoding.Raw, serialization.PublicFormat.Raw
    if private_key.public_key().public_bytes(*raw) != public_key.public_bytes(*raw):
        raise ValueError("APP_JWT_PUBLIC_KEY does not match APP_JWT_PRIVATE_KEY")


@lru_cache
def get_settings() -> Settings:
    """Settings from the environment, loaded once per process."""
    return Settings()


async def get_app_settings(conn: HTTPConnection) -> Settings:
    """FastAPI dependency: the settings the running app was created with."""
    settings: Settings = conn.app.state.settings
    return settings


SettingsDep = Annotated[Settings, Depends(get_app_settings)]
