"""Coach tips the user has acted on or dismissed (tips themselves are computed on request)."""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import CheckConstraint, ForeignKey, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, one_of


class TipHiddenReason(StrEnum):
    ACTED = "acted"  # hidden for 24 h
    DISMISSED = "dismissed"  # hidden for 7 days


class UserTip(Base):
    __tablename__ = "user_tips"
    __table_args__ = (
        CheckConstraint(
            one_of("reason", [reason.value for reason in TipHiddenReason]), name="reason"
        ),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    tip_key: Mapped[str] = mapped_column(primary_key=True)
    hidden_until: Mapped[datetime]
    reason: Mapped[str]
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())
