"""The inbox and the devices push notifications go to."""

import uuid
from datetime import datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import CheckConstraint, ForeignKey, Index, UniqueConstraint, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of
from app.modules.notifications.kinds import NotificationKind


class PushPlatform(StrEnum):
    ANDROID = "android"
    IOS = "ios"


class Notification(Base):
    """One inbox item. ``key`` makes creating the same notice twice a no-op (per user)."""

    __tablename__ = "notifications"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in NotificationKind]), name="kind"),
        UniqueConstraint("user_id", "key"),
        Index("ix_notifications_user_created", "user_id", "created_at", "id"),
        Index("ix_notifications_unread", "user_id", postgresql_where=text("read_at IS NULL")),
        Index("ix_notifications_created_at", "created_at"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str]
    title: Mapped[str]
    body: Mapped[str]
    icon: Mapped[str | None]
    # Where tapping it goes: {"route": "/arena/…", "params": {...}}.
    action: Mapped[dict[str, Any] | None]
    key: Mapped[str]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    read_at: Mapped[datetime | None]


class PushToken(Base):
    """The FCM registration token of one signed-in installation (at most one per session).

    It goes when the session ends (sign-out, replaced, revoked), and moves to whoever signs in
    on that phone next, since a token is unique.
    """

    __tablename__ = "push_tokens"
    __table_args__ = (
        CheckConstraint(
            one_of("platform", [platform.value for platform in PushPlatform]), name="platform"
        ),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("device_sessions.id", ondelete="CASCADE"), unique=True
    )
    token: Mapped[str] = mapped_column(unique=True)
    platform: Mapped[str]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())
