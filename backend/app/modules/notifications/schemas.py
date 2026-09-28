"""Request and response bodies of the inbox, push-token and notification-settings endpoints."""

import re
import uuid
from datetime import datetime, time
from typing import Annotated, Any, Self

from pydantic import Field, field_validator, model_validator

from app.core.schemas import ApiModel, Lax, field_error
from app.modules.notifications.kinds import Category
from app.modules.notifications.models import PushPlatform

MAX_READ_IDS = 200
_CLOCK_TIME = re.compile(r"([01]\d|2[0-3]):[0-5]\d")


class NotificationOut(ApiModel):
    id: uuid.UUID
    kind: str
    title: str
    body: str
    icon: str | None
    action: dict[str, Any] | None
    created_at: datetime
    read: bool


class NotificationsOut(ApiModel):
    items: list[NotificationOut]
    next_cursor: str | None


class UnreadCountOut(ApiModel):
    count: int


class MarkReadIn(ApiModel):
    """``{"ids": [...]}`` or ``{"all": true}``."""

    ids: Annotated[list[Lax[uuid.UUID]], Field(min_length=1, max_length=MAX_READ_IDS)] | None = None
    all: bool | None = None

    @model_validator(mode="after")
    def _one_of(self) -> Self:
        if (self.ids is None) == (self.all is not True):
            raise field_error('Send either "ids" or "all": true.')
        return self


class PushTokenIn(ApiModel):
    token: Annotated[str, Field(min_length=16, max_length=4096)]
    platform: Lax[PushPlatform]

    @field_validator("token")
    @classmethod
    def _printable(cls, value: str) -> str:
        if not value.isascii() or not value.isprintable() or " " in value:
            raise field_error("This isn't a valid push token.")
        return value


class QuietHours(ApiModel):
    """IST wall-clock times ``"HH:MM"``; the window may cross midnight (22:30 to 07:00)."""

    start: str
    end: str

    @field_validator("start", "end")
    @classmethod
    def _clock_time(cls, value: str) -> str:
        if not _CLOCK_TIME.fullmatch(value):
            raise field_error("Use a time like 22:30.")
        return value

    @staticmethod
    def of(start: time | None, end: time | None) -> "QuietHours | None":
        if start is None or end is None:
            return None
        return QuietHours(start=start.strftime("%H:%M"), end=end.strftime("%H:%M"))

    def times(self) -> tuple[time, time]:
        return time.fromisoformat(self.start), time.fromisoformat(self.end)


class NotificationKinds(ApiModel):
    invites: bool = True
    tournaments: bool = True
    friends: bool = True
    missions: bool = True
    streaks: bool = True

    def as_dict(self) -> dict[str, bool]:
        return {category.value: getattr(self, category.value) for category in Category}


class NotificationSettings(ApiModel):
    """Push per category and the quiet hours. On ``PUT``, ``"quiet_hours": null`` turns quiet
    hours off, and leaving the field out keeps them as they are."""

    kinds: NotificationKinds
    quiet_hours: QuietHours | None = None
