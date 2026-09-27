"""Session lifecycle, ORM conventions and migrations."""

from typing import Any

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from fastapi import APIRouter, FastAPI
from httpx import AsyncClient
from sqlalchemy import Connection, func, select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncSession
from sqlalchemy.orm import DeclarativeBase, Mapped

from app.core.db import SessionDep, TimestampMixin, UUIDv7Pk
from app.core.errors import Conflict
from app.models import Base
from app.modules.system.models import AppConfig, AuditLog
from tests.helpers import alembic_config

router = APIRouter(prefix="/test")


@router.post("/config/{key}")
async def put_config(key: str, session: SessionDep) -> dict[str, str]:
    session.add(AppConfig(key=key, value={"on": True}))
    return {"key": key}


@router.post("/config/{key}/fail")
async def put_config_then_fail(key: str, session: SessionDep) -> None:
    session.add(AppConfig(key=key, value={"on": True}))
    await session.flush()
    raise Conflict()


@pytest.fixture
def app(app: FastAPI) -> FastAPI:
    app.include_router(router)
    return app


async def count(session: AsyncSession, key: str) -> int:
    return await session.scalar(select(func.count()).where(AppConfig.key == key)) or 0


async def test_session_commits_when_the_endpoint_succeeds(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    response = await client.post("/test/config/feature")

    assert response.status_code == 200
    assert await count(db_session, "feature") == 1


async def test_session_rolls_back_when_the_endpoint_raises(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    response = await client.post("/test/config/feature/fail")

    assert response.status_code == 409
    assert await count(db_session, "feature") == 0


async def test_commit_failure_becomes_an_error_response(client: AsyncClient) -> None:
    """The commit runs before the response is sent, so a failed commit is never a 200."""
    assert (await client.post("/test/config/feature")).status_code == 200

    duplicate = await client.post("/test/config/feature")  # primary key violation at commit

    assert duplicate.status_code == 500
    assert duplicate.json()["error"]["code"] == "INTERNAL_ERROR"


async def test_server_defaults_are_readable_after_flush(db_session: AsyncSession) -> None:
    entry = AuditLog(action="config.update", entity_type="app_config", entity_id="feature")
    config = AppConfig(key="feature", value=[1, 2])
    db_session.add_all([entry, config])
    await db_session.flush()

    # Loaded with RETURNING (eager defaults): no lazy IO, which AsyncSession would refuse.
    assert entry.id.version == 7
    assert entry.created_at.tzinfo is not None
    assert config.updated_at.tzinfo is not None
    config.value = [3]
    before = config.updated_at
    await db_session.flush()
    assert config.updated_at >= before


class _ScratchBase(DeclarativeBase):
    """Same conventions as ``Base``, separate metadata (so no migration is expected for it)."""

    type_annotation_map = Base.type_annotation_map
    __mapper_args__ = Base.__mapper_args__


class Widget(TimestampMixin, _ScratchBase):
    __tablename__ = "scratch_widget"

    id: Mapped[UUIDv7Pk]
    name: Mapped[str]


async def test_timestamp_mixin_and_uuid7_primary_key(
    db_connection: AsyncConnection, db_session: AsyncSession
) -> None:
    await db_connection.run_sync(_ScratchBase.metadata.create_all)  # rolled back after the test
    widget = Widget(name="first")
    db_session.add(widget)
    await db_session.flush()

    assert widget.id.version == 7
    assert widget.created_at.tzinfo is not None
    # now() is the transaction start time, so both stamps match within one transaction.
    assert widget.updated_at == widget.created_at
    widget.name = "renamed"
    await db_session.flush()
    # Refreshed via RETURNING on UPDATE as well; an expired attribute would need lazy IO here.
    assert widget.updated_at == widget.created_at


def test_constraint_names_follow_the_naming_convention() -> None:
    assert AuditLog.__table__.primary_key.name == "pk_audit_log"
    assert AppConfig.__table__.primary_key.name == "pk_app_config"


async def test_models_match_the_migrations(db_connection: AsyncConnection) -> None:
    def diff(connection: Connection) -> list[Any]:
        context = MigrationContext.configure(connection, opts={"compare_type": True})
        return compare_metadata(context, Base.metadata)

    assert await db_connection.run_sync(diff) == []


async def test_migrations_downgrade_and_upgrade_cleanly(db_connection: AsyncConnection) -> None:
    await db_connection.run_sync(lambda sync: command.downgrade(alembic_config(sync), "base"))
    tables = await db_connection.scalar(
        text("SELECT count(*) FROM pg_tables WHERE tablename IN ('app_config', 'audit_log')")
    )
    assert tables == 0

    await db_connection.run_sync(lambda sync: command.upgrade(alembic_config(sync), "head"))
    version = await db_connection.scalar(text("SELECT version_num FROM alembic_version"))
    assert version == "0001"


async def test_audit_log_is_append_only(db_session: AsyncSession) -> None:
    entry = AuditLog(
        action="user.ban",
        entity_type="user",
        entity_id="u1",
        before={"status": "active"},
        after={"status": "banned"},
    )
    db_session.add(entry)
    await db_session.flush()

    statements = [
        "UPDATE audit_log SET action = 'user.unban'",
        "DELETE FROM audit_log",
        "TRUNCATE audit_log",
    ]
    for statement in statements:
        with pytest.raises(DBAPIError, match="append-only"):
            async with db_session.begin_nested():
                await db_session.execute(text(statement))

    stored = await db_session.scalar(select(AuditLog.action).where(AuditLog.id == entry.id))
    assert stored == "user.ban"
