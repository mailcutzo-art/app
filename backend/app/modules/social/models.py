"""Friends, friend requests, blocks and the friends' activity feed."""

import uuid
from datetime import datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import CheckConstraint, ForeignKey, Index, UniqueConstraint, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of


class RequestStatus(StrEnum):
    PENDING = "pending"
    ACCEPTED = "accepted"
    DECLINED = "declined"
    CANCELLED = "cancelled"  # withdrawn by the sender, or ended by a block or account deletion


class ActivityKind(StrEnum):
    ACHIEVEMENT = "achievement"
    PODIUM = "podium"
    LEVEL_UP = "level_up"
    STREAK = "streak"
    FRIEND = "friend"


def _user_fk(column: str = "users.id") -> ForeignKey:
    return ForeignKey(column, ondelete="CASCADE")


class Friendship(Base):
    """One row per pair of friends, stored once: ``lo`` is the smaller user id."""

    __tablename__ = "friendships"
    __table_args__ = (
        CheckConstraint("lo < hi", name="ordered"),
        # "Friends of X" looks X up on either side.
        Index("ix_friendships_hi", "hi"),
    )

    lo: Mapped[uuid.UUID] = mapped_column(_user_fk(), primary_key=True)
    hi: Mapped[uuid.UUID] = mapped_column(_user_fk(), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class FriendRequest(Base):
    __tablename__ = "friend_requests"
    __table_args__ = (
        CheckConstraint(
            one_of("status", [status.value for status in RequestStatus]), name="status"
        ),
        CheckConstraint("from_id <> to_id", name="not_self"),
        CheckConstraint("(status = 'pending') = (decided_at IS NULL)", name="decided"),
        # At most one open request from one player to another.
        Index(
            "uq_friend_requests_pending",
            "from_id",
            "to_id",
            unique=True,
            postgresql_where=text("status = 'pending'"),
        ),
        Index("ix_friend_requests_from_created", "from_id", "created_at"),
        Index(
            "ix_friend_requests_to_pending", "to_id", postgresql_where=text("status = 'pending'")
        ),
    )

    id: Mapped[UUIDv7Pk]
    from_id: Mapped[uuid.UUID] = mapped_column(_user_fk())
    to_id: Mapped[uuid.UUID] = mapped_column(_user_fk())
    status: Mapped[str] = mapped_column(server_default=RequestStatus.PENDING.value)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    decided_at: Mapped[datetime | None]


class Block(Base):
    """``blocker_id`` blocked ``blocked_id``; either direction hides the two from each other."""

    __tablename__ = "blocks"
    __table_args__ = (
        CheckConstraint("blocker_id <> blocked_id", name="not_self"),
        Index("ix_blocks_blocked", "blocked_id"),
    )

    blocker_id: Mapped[uuid.UUID] = mapped_column(_user_fk(), primary_key=True)
    blocked_id: Mapped[uuid.UUID] = mapped_column(_user_fk(), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class ActivityEvent(Base):
    """Something a player's friends see in their feed for 7 days. ``key`` is unique per user,
    so recording the same event twice is a no-op."""

    __tablename__ = "activity_events"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in ActivityKind]), name="kind"),
        UniqueConstraint("user_id", "key"),
        Index("ix_activity_events_user_created", "user_id", "created_at"),
        Index("ix_activity_events_created_at", "created_at"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(_user_fk())
    kind: Mapped[str]
    payload: Mapped[dict[str, Any]] = mapped_column(server_default=text("'{}'"))
    key: Mapped[str]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
