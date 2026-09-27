"""Sign-in identities, device sessions and refresh tokens."""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    LargeBinary,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import CITEXT
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk


class Provider(StrEnum):
    GOOGLE = "google"
    DEV = "dev"


class AuthIdentity(Base):
    """An external account (Google ``sub``, or a dev-login email) linked to a user."""

    __tablename__ = "auth_identities"
    __table_args__ = (
        UniqueConstraint("provider", "subject"),
        CheckConstraint("provider IN ('google', 'dev')", name="provider"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    provider: Mapped[str]
    subject: Mapped[str]
    email: Mapped[str | None] = mapped_column(CITEXT)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class DeviceSession(Base):
    """One signed-in app installation. Revoking it ends its refresh-token family."""

    __tablename__ = "device_sessions"
    __table_args__ = (
        # At most one active session per installation; also serves "active sessions of a user".
        Index(
            "uq_device_sessions_active_install",
            "user_id",
            "install_id",
            unique=True,
            postgresql_where=text("revoked_at IS NULL"),
        ),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    install_id: Mapped[str]
    platform: Mapped[str]
    app_version: Mapped[str]
    build: Mapped[int]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(server_default=func.now())
    revoked_at: Mapped[datetime | None]
    revoke_reason: Mapped[str | None]


class RefreshToken(Base):
    """A single-use refresh token; each use creates its successor in the same family."""

    __tablename__ = "refresh_tokens"

    id: Mapped[UUIDv7Pk]
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("device_sessions.id", ondelete="CASCADE"), index=True
    )
    family_id: Mapped[uuid.UUID]
    # SHA-256 of the token; the token itself is never stored.
    token_hash: Mapped[bytes] = mapped_column(LargeBinary, unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    expires_at: Mapped[datetime]
    family_expires_at: Mapped[datetime]
    used_at: Mapped[datetime | None]
    successor_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("refresh_tokens.id", ondelete="SET NULL")
    )
