"""Missions, streak and achievements responses (docs/api-play.md)."""

import datetime as dt
from typing import Any

from app.core.schemas import ApiModel


class ActionOut(ApiModel):
    route: str
    params: dict[str, Any]


class MissionOut(ApiModel):
    id: str
    slot: str
    title: str
    progress: int
    target: int
    xp: int
    done: bool
    swapped: bool
    action: ActionOut


class BonusOut(ApiModel):
    xp: int
    coins: int
    done: bool


class StreakSummaryOut(ApiModel):
    days: int
    today_done: bool
    freezes: int


class MissionsOut(ApiModel):
    """The same shape as Home's ``missions`` data."""

    day: dt.date
    items: list[MissionOut]
    bonus: BonusOut
    swap_available: bool
    streak: StreakSummaryOut


class CalendarDayOut(ApiModel):
    day: dt.date
    state: str | None  # "active", "frozen" or null


class StreakOut(ApiModel):
    days: int
    best: int
    today_done: bool
    freezes: int
    max_freezes: int
    freeze_price: int
    calendar: list[CalendarDayOut]
    freezes_used: list[dt.date]


class AchievementOut(ApiModel):
    id: str
    title: str
    description: str
    icon: str
    coins: int
    progress: int
    target: int
    earned: bool
    earned_at: dt.datetime | None


class AchievementsOut(ApiModel):
    earned: int
    total: int
    items: list[AchievementOut]
