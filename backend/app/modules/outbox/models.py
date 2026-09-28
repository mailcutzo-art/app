"""The transactional outbox: side effects written with the change that causes them."""

from datetime import datetime
from typing import Any

from sqlalchemy import Index, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk


class OutboxMessage(Base):
    """One side effect to run after commit (publish, push, leaderboard update, ...).

    ``key`` is unique, so enqueueing the same effect twice stores it once. A row is pending
    until ``delivered_at`` or ``dead_at`` is set; ``available_at`` is when it may next be tried.
    """

    __tablename__ = "outbox"
    __table_args__ = (
        # The dispatcher's scan: pending rows in due order.
        Index(
            "ix_outbox_pending",
            "available_at",
            postgresql_where=text("delivered_at IS NULL AND dead_at IS NULL"),
        ),
    )

    id: Mapped[UUIDv7Pk]
    topic: Mapped[str]
    payload: Mapped[dict[str, Any]]
    key: Mapped[str] = mapped_column(unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    available_at: Mapped[datetime] = mapped_column(server_default=func.now())
    attempts: Mapped[int] = mapped_column(server_default=text("0"))
    delivered_at: Mapped[datetime | None]
    # Set after the last allowed attempt failed: the row is kept for inspection, never retried.
    dead_at: Mapped[datetime | None]
    last_error: Mapped[str | None]
