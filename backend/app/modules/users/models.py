"""Player accounts."""

from datetime import datetime
from enum import StrEnum

from sqlalchemy import CheckConstraint, Text, false, text
from sqlalchemy.dialects.postgresql import ARRAY, CITEXT
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, TimestampMixin, UUIDv7Pk


class UserStatus(StrEnum):
    ACTIVE = "active"
    RESTRICTED = "restricted"
    BANNED = "banned"
    PENDING_DELETION = "pending_deletion"
    DELETED = "deleted"


class Goal(StrEnum):
    NEET = "neet"
    JEE = "jee"


class Role(StrEnum):
    USER = "user"
    MODERATOR = "moderator"
    ADMIN = "admin"


class User(TimestampMixin, Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint("goal IN ('neet', 'jee')", name="goal"),
        CheckConstraint(
            "status IN ('active', 'restricted', 'banned', 'pending_deletion', 'deleted')",
            name="status",
        ),
        CheckConstraint("roles <@ ARRAY['user', 'moderator', 'admin']::text[]", name="roles"),
    )

    id: Mapped[UUIDv7Pk]
    # Unique case-insensitively; null until onboarding picks one.
    handle: Mapped[str | None] = mapped_column(CITEXT, unique=True)
    display_name: Mapped[str]
    email: Mapped[str | None] = mapped_column(CITEXT)
    avatar_tone: Mapped[str] = mapped_column(server_default="lime")
    avatar_symbol: Mapped[str] = mapped_column(server_default="rocket")
    goal: Mapped[str | None]
    birth_year: Mapped[int | None]
    is_minor: Mapped[bool] = mapped_column(server_default=false())
    status: Mapped[str] = mapped_column(server_default=UserStatus.ACTIVE.value)
    roles: Mapped[list[str]] = mapped_column(ARRAY(Text), server_default=text("'{user}'"))
    # Bumping it invalidates every access token already issued to the user.
    token_version: Mapped[int] = mapped_column(server_default=text("0"))
    onboarding_completed_at: Mapped[datetime | None]
    timezone: Mapped[str] = mapped_column(server_default="Asia/Kolkata")
    last_seen_at: Mapped[datetime | None]
