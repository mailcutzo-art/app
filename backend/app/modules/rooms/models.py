"""Rooms (Play with Friend, Group Battle) and invites, as Postgres keeps them.

The live lobby is in Redis (``app.modules.rooms.live``); these rows are the record: who created
which room with which code and settings, who was in it, who was kicked, how it ended, and every
invite. A code is unique among rooms that are still open (a partial unique index), so a code can
be reused once its room has closed.
"""

import uuid
from datetime import datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import CheckConstraint, ForeignKey, Index, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of


class RoomKind(StrEnum):
    FRIEND = "friend"
    GROUP = "group"


class CloseReason(StrEnum):
    HOST_ENDED = "host_ended"
    IDLE = "idle"
    HOST_LEFT = "host_left"
    EMPTY = "empty"


class InviteStatus(StrEnum):
    PENDING = "pending"
    ACCEPTED = "accepted"
    DECLINED = "declined"
    EXPIRED = "expired"
    CANCELLED = "cancelled"


class Room(Base):
    __tablename__ = "rooms"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in RoomKind]), name="kind"),
        CheckConstraint(
            one_of("close_reason", [reason.value for reason in CloseReason]), name="close_reason"
        ),
        # A code works for as long as its room exists.
        Index(
            "ux_rooms_open_code", "code", unique=True, postgresql_where=text("closed_at IS NULL")
        ),
        Index("ix_rooms_open", "created_at", postgresql_where=text("closed_at IS NULL")),
    )

    id: Mapped[UUIDv7Pk]
    code: Mapped[str]
    kind: Mapped[str]
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    # {"subject", "chapters" (null: all), "questions", "seconds", "difficulty", "late_join",
    # "leaderboard", "join"}, as last saved by the host.
    settings: Mapped[dict[str, Any]]
    games: Mapped[int] = mapped_column(server_default=text("0"))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    closed_at: Mapped[datetime | None]
    close_reason: Mapped[str | None]


class RoomMember(Base):
    """Who was in a room; ``left_at`` is set when they left (or were kicked)."""

    __tablename__ = "room_members"
    __table_args__ = (Index("ix_room_members_user", "user_id"),)

    room_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("rooms.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    joined_at: Mapped[datetime] = mapped_column(server_default=func.now())
    left_at: Mapped[datetime | None]


class RoomKick(Base):
    """A player the host kicked: they can't come back to this room."""

    __tablename__ = "room_kicks"

    room_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("rooms.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    kicked_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class RoomInvite(Base):
    """An in-app invite to a room: pending for 2 minutes, then accepted, declined, expired or
    cancelled (by the sender, or by a block between the two)."""

    __tablename__ = "room_invites"
    __table_args__ = (
        CheckConstraint(one_of("status", [status.value for status in InviteStatus]), name="status"),
        Index("ix_room_invites_to", "to_id", "status"),
        Index("ix_room_invites_from", "from_id", "status"),
        Index("ix_room_invites_room", "room_id"),
    )

    id: Mapped[UUIDv7Pk]
    room_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("rooms.id", ondelete="CASCADE"))
    from_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    to_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    status: Mapped[str] = mapped_column(server_default=InviteStatus.PENDING.value)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    expires_at: Mapped[datetime]
    responded_at: Mapped[datetime | None]
