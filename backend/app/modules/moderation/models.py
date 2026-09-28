"""Reports about players and the moderation actions taken on them."""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import CheckConstraint, ForeignKey, Index, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of

MAX_NOTE = 500


class ReportReason(StrEnum):
    CHEATING = "cheating"
    OFFENSIVE_NAME = "offensive_name"
    HARASSMENT = "harassment"
    OTHER = "other"


class ReportStatus(StrEnum):
    OPEN = "open"
    ACTIONED = "actioned"
    DISMISSED = "dismissed"


class ModerationKind(StrEnum):
    """The ladder, mildest first (docs/plan.md, "Security model")."""

    WARN = "warn"
    RESET_NAME = "reset_name"
    RESTRICT_SOCIAL = "restrict_social"
    SHADOW_POOL = "shadow_pool"
    TEMP_BAN = "temp_ban"
    PERM_BAN = "perm_ban"


class UserReport(Base):
    """A player reporting another; reviewed from the admin report queue."""

    __tablename__ = "user_reports"
    __table_args__ = (
        CheckConstraint(one_of("reason", [reason.value for reason in ReportReason]), name="reason"),
        CheckConstraint(one_of("status", [status.value for status in ReportStatus]), name="status"),
        CheckConstraint("reporter_id <> reported_id", name="not_self"),
        CheckConstraint(f"char_length(note) <= {MAX_NOTE}", name="note_length"),
        Index("ix_user_reports_open", "created_at", postgresql_where=text("status = 'open'")),
        Index("ix_user_reports_reported", "reported_id", "created_at"),
        Index("ix_user_reports_reporter", "reporter_id", "created_at"),
    )

    id: Mapped[UUIDv7Pk]
    reporter_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    reported_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    # The match it happened in, if any (no foreign key: matches may be pruned before review).
    match_id: Mapped[uuid.UUID | None]
    reason: Mapped[str]
    note: Mapped[str | None]
    status: Mapped[str] = mapped_column(server_default=ReportStatus.OPEN.value)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    resolved_at: Mapped[datetime | None]
    resolved_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )


class ModerationAction(Base):
    """One step on the ladder. Actions with ``until`` stop applying then; ``revoked_at`` ends
    one early (a successful appeal)."""

    __tablename__ = "moderation_actions"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in ModerationKind]), name="kind"),
        CheckConstraint(
            "reason IN ('cheating', 'abuse', 'offensive_name', 'other')", name="reason"
        ),
        CheckConstraint("kind <> 'temp_ban' OR until IS NOT NULL", name="temp_ban_until"),
        CheckConstraint("kind <> 'perm_ban' OR until IS NULL", name="perm_ban_until"),
        Index("ix_moderation_actions_user_created", "user_id", "created_at"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str]
    reason: Mapped[str]
    note: Mapped[str | None]
    until: Mapped[datetime | None]
    # The moderator (NULL: automatic, e.g. anti-cheat signals).
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    revoked_at: Mapped[datetime | None]
