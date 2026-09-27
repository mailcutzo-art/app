"""Alembic environment: async engine, URL from app settings.

Callers that already hold a connection (the test suite) pass it as
``config.attributes["connection"]``; migrations then run on it inside the caller's transaction.
"""

import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import create_async_engine

from app.core.config import get_settings
from app.models import Base

config = context.config
target_metadata = Base.metadata
shared_connection: Connection | None = config.attributes.get("connection")

if config.config_file_name is not None and shared_connection is None:
    fileConfig(config.config_file_name, disable_existing_loggers=False)


def _database_url() -> str:
    return get_settings().database_url.get_secret_value()


def _configure(**kwargs: object) -> None:
    context.configure(target_metadata=target_metadata, compare_type=True, **kwargs)


def run_migrations_offline() -> None:
    """Emit SQL to stdout instead of executing it (``alembic upgrade head --sql``)."""
    _configure(url=_database_url(), literal_binds=True, dialect_opts={"paramstyle": "named"})
    with context.begin_transaction():
        context.run_migrations()


def _run_on(connection: Connection) -> None:
    _configure(connection=connection)
    with context.begin_transaction():
        context.run_migrations()


async def _run_async() -> None:
    engine = create_async_engine(_database_url(), poolclass=pool.NullPool)
    try:
        async with engine.connect() as connection:
            await connection.run_sync(_run_on)
    finally:
        await engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
elif shared_connection is not None:
    _run_on(shared_connection)
else:
    asyncio.run(_run_async())
