"""Glicko-2 ratings per scope (``overall`` or a subject slug) and their history."""

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, UniqueConstraint, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk

OVERALL = "overall"


class Rating(Base):
    """A player's current rating in one scope. Missing means the defaults (1500, 350, 0.06)."""

    __tablename__ = "ratings"
    __table_args__ = (
        CheckConstraint("rd > 0 AND volatility > 0", name="positive"),
        CheckConstraint("games >= 0", name="games"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    scope: Mapped[str] = mapped_column(primary_key=True)
    rating: Mapped[float] = mapped_column(server_default=text("1500"))
    rd: Mapped[float] = mapped_column(server_default=text("350"))
    volatility: Mapped[float] = mapped_column(server_default=text("0.06"))
    games: Mapped[int] = mapped_column(server_default=text("0"))
    last_played_at: Mapped[datetime | None]


class RatingHistory(Base):
    """One rating change per match, player and scope (a replayed settlement adds nothing)."""

    __tablename__ = "rating_history"
    __table_args__ = (
        UniqueConstraint("match_id", "user_id", "scope"),
        Index("ix_rating_history_user_scope", "user_id", "scope", "created_at"),
    )

    id: Mapped[UUIDv7Pk]
    match_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("matches.id", ondelete="CASCADE"))
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    scope: Mapped[str]
    rating_before: Mapped[float]
    rd_before: Mapped[float]
    rating_after: Mapped[float]
    rd_after: Mapped[float]
    volatility_after: Mapped[float]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
