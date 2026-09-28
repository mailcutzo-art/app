"""Response bodies for leaderboards and player stats (docs/api-play.md)."""

from datetime import datetime

from app.core.schemas import ApiModel
from app.modules.matches.schemas import RatingOut
from app.modules.social.cards import UserCard


class RowOut(ApiModel):
    position: int
    user: UserCard
    value: int
    value_display: str
    change_1d: int | None  # places gained since yesterday's snapshot; null if not on it


class StandingOut(ApiModel):
    """The viewer on a hub card: a position, or rated games still needed."""

    position: int | None = None
    value: int | None = None
    change_1d: int | None = None
    games_to_rank: int | None = None


class BoardCardOut(ApiModel):
    board: str
    title: str
    ends_at: datetime | None  # weekly boards: when they reset
    leader: RowOut | None
    me: StandingOut


class HubOut(ApiModel):
    boards: list[BoardCardOut]
    last_week: list[RowOut]  # the top 3 of last week's weekly XP board


class NotRankedOut(ApiModel):
    games_to_rank: int


class BoardPageOut(ApiModel):
    board: str
    title: str
    period: str | None  # weekly boards: the ISO week, "2026-W40"
    items: list[RowOut]
    next_cursor: str | None
    me: RowOut | None
    around_me: list[RowOut]
    not_ranked: NotRankedOut | None
    players: int
    ends_at: datetime | None


class LevelOut(ApiModel):
    level: int
    into_level: int
    for_next: int


class ScopeRatingOut(ApiModel):
    scope: str
    name: str
    rating: RatingOut
    position: int | None


class RecordOut(ApiModel):
    wins: int
    draws: int
    losses: int


class StreakOut(ApiModel):
    current: int
    best: int


class RatingPointOut(ApiModel):
    at: datetime
    value: int


class StatsOut(ApiModel):
    level: LevelOut
    ratings: list[ScopeRatingOut]
    record: dict[str, RecordOut]
    accuracy: float | None
    questions_answered: int
    streak: StreakOut
    rating_history: list[RatingPointOut]
