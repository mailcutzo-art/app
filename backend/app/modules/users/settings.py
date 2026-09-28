"""Reading and changing a user's preferences (``user_settings``).

``read_settings`` never writes: a user who never changed anything has no row and gets the
defaults. ``locked_settings`` creates the row if needed and locks it, for changes.
"""

import uuid
from dataclasses import dataclass, field
from datetime import time
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.users.models import UserSettings

DEFAULT_QUIET_START = time(22, 30)
DEFAULT_QUIET_END = time(7, 0)


@dataclass(frozen=True, slots=True)
class Preferences:
    """A user's settings with the defaults filled in."""

    analytics_enabled: bool = True
    notification_kinds: dict[str, bool] = field(default_factory=dict)
    quiet_start: time | None = DEFAULT_QUIET_START
    quiet_end: time | None = DEFAULT_QUIET_END
    # Privacy choices as stored; ``None`` means the default (``app.modules.social.privacy``
    # fills it in, since the defaults depend on whether the player is a minor today).
    friend_requests: str | None = None
    challenges: str | None = None
    presence: str | None = None
    public_boards: bool | None = None

    def category_enabled(self, category: str) -> bool:
        return self.notification_kinds.get(category, True)


def _preferences(row: UserSettings | None) -> Preferences:
    if row is None:
        return Preferences()
    kinds: dict[str, Any] = row.notification_kinds or {}
    return Preferences(
        analytics_enabled=row.analytics_enabled,
        notification_kinds={key: value for key, value in kinds.items() if isinstance(value, bool)},
        quiet_start=row.quiet_start,
        quiet_end=row.quiet_end,
        friend_requests=row.friend_requests,
        challenges=row.challenges,
        presence=row.presence,
        public_boards=row.public_boards,
    )


async def read_settings(db: AsyncSession, user_id: uuid.UUID) -> Preferences:
    return _preferences(await db.get(UserSettings, user_id))


async def read_many(db: AsyncSession, user_ids: list[uuid.UUID]) -> dict[uuid.UUID, Preferences]:
    """Preferences of several users at once (defaults for those without a row)."""
    rows = {
        row.user_id: row
        for row in await db.scalars(select(UserSettings).where(UserSettings.user_id.in_(user_ids)))
    }
    return {user_id: _preferences(rows.get(user_id)) for user_id in user_ids}


async def locked_settings(db: AsyncSession, user_id: uuid.UUID) -> UserSettings:
    """The user's settings row, created with the defaults if missing, locked for update."""
    await db.execute(insert(UserSettings).values(user_id=user_id).on_conflict_do_nothing())
    return await db.get_one(UserSettings, user_id, with_for_update=True, populate_existing=True)


def preferences_of(row: UserSettings) -> Preferences:
    return _preferences(row)
