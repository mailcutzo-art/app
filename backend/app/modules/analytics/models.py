"""Product analytics events (docs/user-flows.md §15), kept for 180 days."""

import uuid
from datetime import date, datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import CheckConstraint, ForeignKey, Index, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of


class EventSource(StrEnum):
    CLIENT = "client"  # POST /v1/events
    SERVER = "server"  # recorded where the action happens (``track``)


class AnalyticsEvent(Base):
    """One event. Minors' events carry no ``user_id``, only ``session_key``: a per-session id
    that changes daily and can't be traced back to the account."""

    __tablename__ = "analytics_events"
    __table_args__ = (
        CheckConstraint(one_of("source", [source.value for source in EventSource]), name="source"),
        CheckConstraint("NOT (is_minor AND user_id IS NOT NULL)", name="minor_anonymous"),
        Index("ix_analytics_events_day_name", "ist_day", "name"),
        Index("ix_analytics_events_at", "at"),
    )

    id: Mapped[UUIDv7Pk]
    name: Mapped[str]
    props: Mapped[dict[str, Any]]
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    session_key: Mapped[str | None]
    is_minor: Mapped[bool]
    source: Mapped[str]
    at: Mapped[datetime]
    ist_day: Mapped[date]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
