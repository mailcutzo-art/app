"""Leaderboard badges. The boards themselves live in Redis and are rebuilt from Postgres."""

import uuid
from datetime import date, datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk


class LeaderboardBadge(Base):
    """A weekly #1: "Physics Champion · Week 39", one per board, exam and week."""

    __tablename__ = "leaderboard_badges"
    __table_args__ = (
        CheckConstraint("goal IN ('neet', 'jee')", name="goal"),
        UniqueConstraint("board", "goal", "week"),
        Index("ix_leaderboard_badges_user", "user_id", "week"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    board: Mapped[str]  # weekly:physics
    goal: Mapped[str]  # the exam view the player topped
    week: Mapped[date]  # the IST Monday that started the week
    title: Mapped[str]  # Physics Champion · Week 39
    value: Mapped[int]  # the winning points
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
