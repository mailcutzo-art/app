"""XP: each user's total and the idempotent events that make it up."""

import uuid
from datetime import date, datetime
from enum import StrEnum

from sqlalchemy import BigInteger, CheckConstraint, ForeignKey, UniqueConstraint, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of


class XpSource(StrEnum):
    PRACTICE = "practice"
    MATCH = "match"
    MISSION = "mission"
    ACHIEVEMENT = "achievement"
    ADJUSTMENT = "adjustment"


class UserProgress(Base):
    __tablename__ = "user_progress"
    __table_args__ = (
        CheckConstraint("xp >= 0", name="xp"),
        CheckConstraint("practice_xp_today >= 0", name="practice_xp_today"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    xp: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    # Practice XP earned on ``practice_xp_day`` (IST), for the daily cap.
    practice_xp_day: Mapped[date | None]
    practice_xp_today: Mapped[int] = mapped_column(server_default=text("0"))
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())


class XpEvent(Base):
    """One award. ``source_key`` is unique per user, so replaying an award changes nothing."""

    __tablename__ = "xp_events"
    __table_args__ = (
        CheckConstraint(one_of("source", [source.value for source in XpSource]), name="source"),
        UniqueConstraint("user_id", "source_key"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source: Mapped[str]
    source_key: Mapped[str]
    amount: Mapped[int]  # after the daily cap; 0 once the cap is reached
    ref_id: Mapped[uuid.UUID | None]  # the practice session or match
    ist_day: Mapped[date]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
