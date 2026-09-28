"""Player accounts."""

import uuid
from datetime import datetime, time
from enum import StrEnum
from typing import Any

from sqlalchemy import CheckConstraint, ForeignKey, Index, Text, false, func, text, true
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


class BanReason(StrEnum):
    CHEATING = "cheating"
    ABUSE = "abuse"
    OFFENSIVE_NAME = "offensive_name"
    OTHER = "other"


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
        CheckConstraint(
            "ban_reason IN ('cheating', 'abuse', 'offensive_name', 'other')", name="ban_reason"
        ),
        # Handle search by prefix (``handle::text LIKE 'abc%'``); handles are stored lowercase.
        Index("ix_users_handle_prefix", "handle", postgresql_ops={"handle": "text_pattern_ops"}),
        Index(
            "ix_users_pending_deletion",
            "deletion_requested_at",
            postgresql_where=text("status = 'pending_deletion'"),
        ),
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
    # While status is "banned": why, and until when (NULL: permanently). A ban that has run out
    # no longer counts, even before anyone resets the status (see ``ban_in_force``).
    ban_reason: Mapped[str | None]
    banned_until: Mapped[datetime | None]
    # The last handle change after onboarding (a handle can change once every 30 days).
    handle_changed_at: Mapped[datetime | None]
    # While status is "pending_deletion": when the player asked, and the end of the restore
    # window. Erasure happens 30 days after the request (see ``app.modules.users.deletion``).
    deletion_requested_at: Mapped[datetime | None]
    restore_until: Mapped[datetime | None]

    def ban_in_force(self, now: datetime) -> bool:
        return ban_in_force(self.status, self.banned_until, now)

    def restorable(self, now: datetime) -> bool:
        return restorable(self.status, self.restore_until, now)


def ban_in_force(status: str, banned_until: datetime | None, now: datetime) -> bool:
    """Whether a ban applies now: status "banned", and permanent or not yet over."""
    return status == UserStatus.BANNED and (banned_until is None or banned_until > now)


def restorable(status: str, restore_until: datetime | None, now: datetime) -> bool:
    """Whether a deleted account is still inside its restore window (7 days)."""
    return (
        status == UserStatus.PENDING_DELETION and restore_until is not None and restore_until > now
    )


# Accounts nobody else may see: not in search, friends lists, requests, activity or profiles.
HIDDEN_STATUSES = frozenset({UserStatus.PENDING_DELETION.value, UserStatus.DELETED.value})


class UserSettings(Base):
    """Per-user preferences: one row per user, created on first change.

    A missing row means every default. Later features add their own columns here (privacy,
    sound, theme); read and write through ``app.modules.users.settings``.
    """

    __tablename__ = "user_settings"
    __table_args__ = (
        CheckConstraint("(quiet_start IS NULL) = (quiet_end IS NULL)", name="quiet_hours"),
        CheckConstraint(
            "friend_requests IN ('everyone', 'played_with', 'nobody')", name="friend_requests"
        ),
        CheckConstraint("challenges IN ('friends', 'everyone', 'nobody')", name="challenges"),
        CheckConstraint("presence IN ('friends', 'nobody')", name="presence"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    # Product analytics (docs/user-flows.md §15). Off: nothing is recorded for the user.
    analytics_enabled: Mapped[bool] = mapped_column(server_default=true())
    # Push on or off per notification category (``invites``, ``tournaments``, ...); a category
    # missing from the object is on.
    notification_kinds: Mapped[dict[str, Any]] = mapped_column(server_default=text("'{}'"))
    # Push is held back between these IST wall-clock times (both NULL: no quiet hours).
    quiet_start: Mapped[time | None] = mapped_column(server_default=text("'22:30'"))
    quiet_end: Mapped[time | None] = mapped_column(server_default=text("'07:00'"))
    # Privacy (docs/api-play.md, "Social"). NULL means the default, which depends on whether
    # the player is a minor today; see ``app.modules.social.privacy``.
    friend_requests: Mapped[str | None]
    challenges: Mapped[str | None]
    presence: Mapped[str | None]
    public_boards: Mapped[bool | None]
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())
