"""Platform tables: runtime configuration and the append-only audit log."""

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Index, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk


class AppConfig(Base):
    """Runtime-tunable configuration values (read by ``/v1/config``)."""

    __tablename__ = "app_config"

    key: Mapped[str] = mapped_column(primary_key=True)
    value: Mapped[Any] = mapped_column(JSONB, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())


class AuditLog(Base):
    """Who changed what. Append-only: a database trigger rejects UPDATE, DELETE and TRUNCATE."""

    __tablename__ = "audit_log"
    __table_args__ = (
        Index("ix_audit_log_entity", "entity_type", "entity_id"),
        Index("ix_audit_log_actor_id", "actor_id"),
    )

    id: Mapped[UUIDv7Pk]
    actor_id: Mapped[uuid.UUID | None]
    action: Mapped[str]
    entity_type: Mapped[str]
    entity_id: Mapped[str]
    before: Mapped[dict[str, Any] | None]
    after: Mapped[dict[str, Any] | None]
    ip: Mapped[str | None]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
