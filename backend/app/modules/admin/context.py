"""What admin code needs from the api app it is mounted on.

SQLAdmin is a Starlette sub-app with its own routing, so FastAPI dependencies don't reach it.
The panel reads the parent app's resources (and the dependency overrides tests install for the
database session and the clock) through ``AdminContext``.
"""

import uuid
from collections.abc import Mapping
from datetime import datetime
from typing import Any

import httpx
from redis.asyncio import Redis
from sqlalchemy import inspect
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from starlette.applications import Starlette
from starlette.requests import HTTPConnection, Request

from app.core.clock import get_clock, utc_now
from app.core.config import Settings
from app.core.db import get_sessionmaker
from app.core.security import client_ip
from app.modules.system.models import AuditLog


class AdminContext:
    def __init__(self, app: Starlette, settings: Settings) -> None:
        self.app = app
        self.settings = settings

    def _override(self, dependency: Any) -> Any:
        overrides: Mapping[Any, Any] = getattr(self.app, "dependency_overrides", {})
        override = overrides.get(dependency)
        return override() if override is not None else None

    @property
    def sessionmaker(self) -> async_sessionmaker[AsyncSession]:
        override = self._override(get_sessionmaker)
        if override is not None:
            factory: async_sessionmaker[AsyncSession] = override
            return factory
        resources_factory: async_sessionmaker[AsyncSession] = self.app.state.resources.sessionmaker
        return resources_factory

    @property
    def redis(self) -> Redis:
        redis: Redis = self.app.state.resources.redis
        return redis

    @property
    def http(self) -> httpx.AsyncClient:
        """For Google's token endpoint and keys (tests put a mock client in ``admin_http``)."""
        override = getattr(self.app.state, "admin_http", None)
        client: httpx.AsyncClient = override or self.app.state.resources.http
        return client

    def now(self) -> datetime:
        clock = self._override(get_clock)
        moment: datetime = clock() if clock is not None else utc_now()
        return moment

    def client_ip(self, conn: HTTPConnection) -> str:
        return client_ip(conn, self.settings.trusted_proxies)


class DeferredSessionmaker:
    """Stands in for the api app's session factory, which exists only once its lifespan has
    started (and which tests replace); SQLAdmin gets it when the panel is mounted."""

    class_ = AsyncSession

    def __init__(self, context: AdminContext) -> None:
        self._context = context

    def configure(self, **_kwargs: Any) -> None:
        """SQLAdmin turns autoflush off here; the app's factory keeps its own settings."""

    def __call__(self, **kwargs: Any) -> AsyncSession:
        return self._context.sessionmaker(**kwargs)


def json_value(value: Any) -> Any:
    """A column value as JSON for the audit log."""
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, list | tuple):
        return [json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    return value


def snapshot(row: object) -> dict[str, Any]:
    """Every column of an ORM row as JSON."""
    mapper = inspect(row.__class__, raiseerr=True)
    return {column.key: json_value(getattr(row, column.key)) for column in mapper.column_attrs}


def audit_entry(
    request: Request,
    *,
    action: str,
    entity_type: str,
    entity_id: str,
    before: dict[str, Any] | None,
    after: dict[str, Any] | None,
) -> AuditLog:
    """An audit-log row for a write made by the signed-in admin."""
    context: AdminContext = request.state.admin_context
    return AuditLog(
        actor_id=admin_id(request),
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        before=before,
        after=after,
        ip=context.client_ip(request),
    )


def admin_id(request: Request) -> uuid.UUID | None:
    value = getattr(request.state, "admin_id", None)
    return value if isinstance(value, uuid.UUID) else None
