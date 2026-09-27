"""Switches that change without a redeploy: forced updates and maintenance.

Each value is read from the ``app_config`` table (the key is the setting's name, e.g.
``maintenance``) and falls back to the environment setting of the same name
(``APP_MAINTENANCE``). A process re-reads them at most every ``CACHE_TTL_S`` seconds.
"""

import contextlib
import math
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Annotated, Any

import structlog
from fastapi import Depends
from pydantic import AwareDatetime, NonNegativeInt, TypeAdapter, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import HTTPConnection

from app.core.clock import ClockDep, iso_utc
from app.core.config import Settings, SettingsDep
from app.core.db import SessionDep
from app.core.errors import DEPENDENCY_ERRORS, ServiceUnavailable, UpdateRequired
from app.modules.system.models import AppConfig

CACHE_TTL_S = 5.0
APP_BUILD_HEADER = "X-App-Build"

log = structlog.stdlib.get_logger(__name__)

_ADAPTERS: dict[str, TypeAdapter[Any]] = {
    "min_build": TypeAdapter(NonNegativeInt),
    "maintenance": TypeAdapter(bool),
    "maintenance_message": TypeAdapter(str | None),
    "maintenance_until": TypeAdapter(AwareDatetime | None),
    "maintenance_at": TypeAdapter(AwareDatetime | None),
}


@dataclass(frozen=True, slots=True)
class RuntimeConfig:
    min_build: int
    maintenance: bool
    maintenance_message: str | None
    maintenance_until: datetime | None  # when maintenance is expected to end
    maintenance_at: datetime | None  # when planned maintenance starts


async def load_runtime_config(db: AsyncSession, settings: Settings) -> RuntimeConfig:
    rows = await db.execute(
        select(AppConfig.key, AppConfig.value).where(AppConfig.key.in_(list(_ADAPTERS)))
    )
    stored: dict[str, Any] = dict(rows.all())
    values: dict[str, Any] = {}
    for key, adapter in _ADAPTERS.items():
        values[key] = getattr(settings, key)
        if key in stored:
            try:
                values[key] = adapter.validate_python(stored[key])
            except ValidationError:
                log.warning("runtime_config.invalid_value", key=key)
    return _config(values)


def _config(values: dict[str, Any]) -> RuntimeConfig:
    """API times are UTC, whatever offset the value was written with."""
    for key in ("maintenance_until", "maintenance_at"):
        if isinstance(values[key], datetime):
            values[key] = values[key].astimezone(UTC)
    return RuntimeConfig(**values)


def _from_settings(settings: Settings) -> RuntimeConfig:
    return _config({key: getattr(settings, key) for key in _ADAPTERS})


class RuntimeConfigCache:
    """The last loaded values, reused for ``CACHE_TTL_S`` seconds."""

    def __init__(self, ttl_s: float = CACHE_TTL_S) -> None:
        self.ttl_s = ttl_s
        self._value: RuntimeConfig | None = None
        self._loaded_at = 0.0

    async def get(self, db: AsyncSession, settings: Settings) -> RuntimeConfig:
        """Cached values; if the database can't be read, the last ones (or the settings), so
        ``/v1/config`` keeps answering during an outage."""
        now = time.monotonic()
        if self._value is None or now - self._loaded_at > self.ttl_s:
            try:
                self._value = await load_runtime_config(db, settings)
            except DEPENDENCY_ERRORS:
                log.warning("runtime_config.unavailable")
                with contextlib.suppress(*DEPENDENCY_ERRORS):
                    await db.rollback()
                return self._value or _from_settings(settings)
            self._loaded_at = now
        return self._value

    def clear(self) -> None:
        self._value = None


async def get_runtime_config(
    conn: HTTPConnection, db: SessionDep, settings: SettingsDep
) -> RuntimeConfig:
    cache: RuntimeConfigCache = conn.app.state.runtime_config
    return await cache.get(db, settings)


RuntimeConfigDep = Annotated[RuntimeConfig, Depends(get_runtime_config)]


def _app_build(value: str | None) -> int | None:
    return int(value) if value is not None and value.isdigit() and len(value) < 10 else None


async def enforce_client_gates(
    conn: HTTPConnection, config: RuntimeConfigDep, clock: ClockDep
) -> None:
    """426 ``UPDATE_REQUIRED`` for app builds below ``min_build`` (sent as ``X-App-Build``),
    and 503 ``MAINTENANCE`` while maintenance is on.

    Routes the app needs to find out about either (``/v1/config``, sign-in and refresh, the
    probes) and live matches, which must be able to finish, are included without this gate.
    """
    build = _app_build(conn.headers.get(APP_BUILD_HEADER))
    if build is not None and build < config.min_build:
        raise UpdateRequired(details={"min_build": config.min_build})
    if config.maintenance:
        until = config.maintenance_until
        retry_after = None
        if until is not None and until > clock():
            retry_after = math.ceil((until - clock()).total_seconds())
        raise ServiceUnavailable(
            config.maintenance_message or "We're making the game better. Back soon!",
            code="MAINTENANCE",
            retry_after=retry_after,
            details={"until": iso_utc(until)},
        )


ClientGates = Depends(enforce_client_gates)
