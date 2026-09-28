"""Messages from Settings → Help & feedback (problems, ideas, coin questions, ban appeals)."""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import CheckConstraint, ForeignKey, Index, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of

MAX_MESSAGE = 2000


class FeedbackKind(StrEnum):
    PROBLEM = "problem"
    IDEA = "idea"
    COINS = "coins"
    BAN_APPEAL = "ban_appeal"


class FeedbackStatus(StrEnum):
    OPEN = "open"
    CLOSED = "closed"


class Feedback(Base):
    __tablename__ = "feedback"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in FeedbackKind]), name="kind"),
        CheckConstraint(
            one_of("status", [status.value for status in FeedbackStatus]), name="status"
        ),
        CheckConstraint(f"char_length(message) BETWEEN 1 AND {MAX_MESSAGE}", name="message"),
        Index("ix_feedback_open", "created_at", postgresql_where=text("status = 'open'")),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    kind: Mapped[str]
    message: Mapped[str]
    # The request id of the last error the app showed, so support can find it in the logs.
    request_id: Mapped[str | None]
    app_build: Mapped[int | None]
    status: Mapped[str] = mapped_column(server_default=FeedbackStatus.OPEN.value)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
