"""Response bodies for the Battle tab, match history, results, reviews and opponents
(``docs/api-play.md``)."""

import uuid
from datetime import datetime
from typing import Any, Literal

from app.core.schemas import ApiModel


class AvatarOut(ApiModel):
    tone: str | None
    symbol: str | None


class CardOut(ApiModel):
    """A user card; the Practice Bot's carries ``is_bot``."""

    id: str
    handle: str | None
    display_name: str | None
    avatar: AvatarOut | None
    level: int | None
    is_bot: bool | None = None


class RatingOut(ApiModel):
    display: str  # "—" before any rated game, "1523?" while provisional, "1523"
    value: int | None
    provisional: bool


class BattleChapterOut(ApiModel):
    slug: str
    name: str
    battle_ready: bool
    question_count: int
    label: Literal["strong", "needs_work"] | None


class BattleSubjectOut(ApiModel):
    slug: str
    name: str
    tone: str
    rating: RatingOut
    chapters: list[BattleChapterOut]


class ActiveOut(ApiModel):
    kind: Literal["queue", "match", "room", "tournament"]
    id: str
    title: str
    action: dict[str, Any]


class SelectionOut(ApiModel):
    subject: str
    chapter: str | None
    mode: Literal["rated", "casual"]


class OnlineOut(ApiModel):
    searching: int
    p50_wait_s: int | None


class BattleSetupOut(ApiModel):
    subjects: list[BattleSubjectOut]
    coins: int | None
    casual_fee: int
    cooldown_until: datetime | None
    active: ActiveOut | None
    last: SelectionOut | None
    online: dict[str, OnlineOut]
    first_search: bool
    leaders: dict[str, dict[str, Any]] | None


class ScoreOut(ApiModel):
    me: int
    best_other: int | None


class TotalsOut(ApiModel):
    points: int
    correct: int


class MatchItemOut(ApiModel):
    """One row of the history."""

    id: uuid.UUID
    kind: str
    subject: str
    chapters: list[str]
    played_at: datetime
    result: Literal["win", "loss", "draw", "aborted", "voided"] | None
    reason: str | None
    score: ScoreOut
    opponents: list[CardOut]
    rating_delta: int | None
    coins_delta: int | None
    place: int | None


class MatchesOut(ApiModel):
    items: list[MatchItemOut]
    next_cursor: str | None


class MatchOut(MatchItemOut):
    status: Literal["live", "settling", "settled", "aborted", "voided"]
    totals: dict[str, TotalsOut]
    ranking: list[list[str]]
    settlement: dict[str, Any] | None


class ReviewOptionOut(ApiModel):
    id: str
    text: str


class ReviewAnswerOut(ApiModel):
    opt: str | None
    correct: bool
    pts: int
    time_ms: int | None
    speed: str | None


class ReviewQuestionOut(ApiModel):
    q: int
    ref: str
    stem: str
    options: list[ReviewOptionOut]
    correct: str
    explanation: str
    chapter: str | None
    topic: str | None
    players: dict[str, ReviewAnswerOut]
    bookmarked: bool


class ReviewOut(ApiModel):
    questions: list[ReviewQuestionOut]


class RecordOut(ApiModel):
    wins: int
    losses: int
    draws: int


class OpponentOut(ApiModel):
    user: CardOut
    h2h: RecordOut
    relationship: str
    games: int
    last_played_at: datetime


class OpponentsOut(ApiModel):
    items: list[OpponentOut]
