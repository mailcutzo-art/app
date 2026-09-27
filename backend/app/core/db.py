"""Async SQLAlchemy: engine and session factories, the declarative base and column helpers."""

import uuid
from collections.abc import AsyncIterator, Iterable
from datetime import datetime
from typing import Annotated, Any

from fastapi import Depends
from sqlalchemy import DateTime, MetaData, Text, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from starlette.requests import HTTPConnection

from app.core.config import Settings
from app.core.ids import new_id

# Deterministic constraint names, so migrations can reference (and drop) them reliably.
NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """Declarative base: ``str`` maps to TEXT, ``datetime`` to TIMESTAMPTZ, dicts to JSONB.

    Server-generated values are fetched with RETURNING (``eager_defaults``) so they can be read
    without lazy IO, which AsyncSession forbids. Models that set their own ``__mapper_args__``
    should extend ``Base.__mapper_args__``.
    """

    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    type_annotation_map = {  # noqa: RUF012 - SQLAlchemy reads this mapping at class creation
        str: Text(),
        datetime: DateTime(timezone=True),
        dict[str, Any]: JSONB,
    }
    __mapper_args__ = {"eager_defaults": True}  # noqa: RUF012 - read by the mapper


# Primary key generated in the application as a UUIDv7: ``id: Mapped[UUIDv7Pk]``.
UUIDv7Pk = Annotated[uuid.UUID, mapped_column(primary_key=True, default=new_id)]


class TimestampMixin:
    """``created_at``/``updated_at`` (timestamptz) filled in by the database."""

    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())


def one_of(column: str, values: Iterable[str]) -> str:
    """SQL for a CHECK constraint that limits a text column to ``values``.

    NULL passes, as with any CHECK; declare the column NOT NULL where a value is required.
    """
    quoted = ", ".join("'" + value.replace("'", "''") + "'" for value in values)
    return f"{column} IN ({quoted})"


def violated_constraint(error: IntegrityError) -> str | None:
    """Name of the constraint an integrity error violated, as reported by asyncpg."""
    name = getattr(error.orig.__cause__, "constraint_name", None) if error.orig else None
    return name if isinstance(name, str) else None


def create_engine(settings: Settings, *, application_name: str) -> AsyncEngine:
    return create_async_engine(
        settings.database_url.get_secret_value(),
        pool_size=settings.database_pool_size,
        max_overflow=settings.database_max_overflow,
        pool_pre_ping=True,
        connect_args={"server_settings": {"application_name": application_name, "timezone": "UTC"}},
    )


def create_sessionmaker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False)


async def get_sessionmaker(conn: HTTPConnection) -> async_sessionmaker[AsyncSession]:
    """FastAPI dependency: the app's session factory (tests override this)."""
    sessionmaker: async_sessionmaker[AsyncSession] = conn.app.state.resources.sessionmaker
    return sessionmaker


async def get_session(
    sessionmaker: Annotated[async_sessionmaker[AsyncSession], Depends(get_sessionmaker)],
) -> AsyncIterator[AsyncSession]:
    """One session per request: committed when the endpoint returns, rolled back if it raises."""
    async with sessionmaker() as session:
        yield session
        await session.commit()


# Always depend on the session through this alias. ``scope="function"`` commits before the
# response is sent (a failed commit becomes an error response, not a silent loss), and FastAPI
# caches dependencies per scope, so mixing scopes would open a second session.
SessionDep = Annotated[AsyncSession, Depends(get_session, scope="function")]
