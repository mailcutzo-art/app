"""Live games once they exist in Postgres: matches, their players, questions and answers, and
head-to-head records.

A match row is written before the game starts in Redis (``docs/realtime-engine.md``), so its id
is known everywhere from the start. Settlement fills in players, answers and results in one
transaction and sets ``settled_at``; it never runs twice for a match.
"""

import uuid
from datetime import datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, one_of


class MatchKind(StrEnum):
    QUICK_RATED = "quick_rated"
    QUICK_CASUAL = "quick_casual"
    BOT = "bot"
    FRIEND = "friend"
    GROUP = "group"
    TOURNAMENT = "tournament"


class MatchStatus(StrEnum):
    LIVE = "live"  # created; the game runs in Redis
    FINISHED = "finished"  # reserved for kinds that settle in several steps
    SETTLED = "settled"  # a finished game with its results committed
    ABORTED = "aborted"  # ended before question 1: no rating, coins or XP
    VOIDED = "voided"  # both dropped, infrastructure failure or integrity problem


class EndReason(StrEnum):
    NORMAL = "normal"
    FORFEIT = "forfeit"  # someone chose to leave
    DISCONNECTED = "disconnected"  # someone was away past their grace
    NO_SHOW = "no_show"
    ENDED_BY_HOST = "ended_by_host"
    ABORTED = "aborted"
    VOIDED = "voided"


class ParticipantResult(StrEnum):
    WIN = "win"
    LOSS = "loss"
    DRAW = "draw"
    ABORTED = "aborted"
    VOIDED = "voided"


RATED_KINDS = frozenset({MatchKind.QUICK_RATED, MatchKind.TOURNAMENT})
SPEEDS = ("fast", "slow", "even")
ANSWER_STATUSES = ("accepted", "late", "too_early", "timeout")


class Match(Base):
    __tablename__ = "matches"
    __table_args__ = (
        CheckConstraint(one_of("kind", [kind.value for kind in MatchKind]), name="kind"),
        CheckConstraint(one_of("status", [status.value for status in MatchStatus]), name="status"),
        CheckConstraint(
            one_of("end_reason", [reason.value for reason in EndReason]), name="reason"
        ),
        # The reconciler looks for matches that stayed live too long.
        Index("ix_matches_live", "created_at", postgresql_where=text("status = 'live'")),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)  # pre-generated UUIDv7
    kind: Mapped[str]
    subject_id: Mapped[int] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    # Where the questions came from: [{"chapter_id", "slug", "name", "count"}]; a null chapter
    # means the whole subject.
    sources: Mapped[list[dict[str, Any]]] = mapped_column(JSONB)
    # The chapters the questions came from.
    chapter_ids: Mapped[list[int]] = mapped_column(ARRAY(Integer))
    status: Mapped[str] = mapped_column(server_default=MatchStatus.LIVE.value)
    end_reason: Mapped[str | None]
    # Timings, the players' tickets and holds, and the longest the game can run.
    config: Mapped[dict[str, Any]]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    started_at: Mapped[datetime | None]
    finished_at: Mapped[datetime | None]
    settled_at: Mapped[datetime | None]


class MatchParticipant(Base):
    """One seat in a match. The Practice Bot has a seat too, with no user."""

    __tablename__ = "match_participants"
    __table_args__ = (
        CheckConstraint(
            one_of("result", [result.value for result in ParticipantResult]), name="result"
        ),
        CheckConstraint("is_bot = (user_id IS NULL)", name="bot"),
        UniqueConstraint("match_id", "user_id"),
        # History: a player's matches, newest first (match ids are time-ordered).
        Index("ix_match_participants_user", "user_id", "match_id"),
    )

    match_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("matches.id", ondelete="CASCADE"), primary_key=True
    )
    seat: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    is_bot: Mapped[bool]
    # The player card as it was when the game was played.
    card: Mapped[dict[str, Any]]
    result: Mapped[str]
    forfeited: Mapped[bool] = mapped_column(server_default=text("false"))
    score: Mapped[int] = mapped_column(server_default=text("0"))
    correct: Mapped[int] = mapped_column(server_default=text("0"))
    correct_time_ms: Mapped[int] = mapped_column(server_default=text("0"))
    place: Mapped[int | None] = mapped_column(SmallInteger)
    # The subject rating before and after (rated games only).
    rating_before: Mapped[float | None]
    rating_after: Mapped[float | None]
    rating_delta: Mapped[int | None]
    coins_delta: Mapped[int | None]
    # This player's ``match.settled`` payload, served again by GET /v1/matches/{id}.
    settlement: Mapped[dict[str, Any] | None]


class MatchQuestion(Base):
    """A question as asked in one match, with the option ids it was shown with."""

    __tablename__ = "match_questions"

    match_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("matches.id", ondelete="CASCADE"), primary_key=True
    )
    position: Mapped[int] = mapped_column(SmallInteger, primary_key=True)  # from 1
    question_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("questions.id"))
    # {"ids": [option id per displayed option], "order": [authored index per displayed
    # option], "correct": "<option id>"}. The only place outside Redis that maps ids to answers.
    option_map: Mapped[dict[str, Any]]


class MatchAnswer(Base):
    """One player's answer (or timeout) to one question, as settled."""

    __tablename__ = "match_answers"
    __table_args__ = (
        CheckConstraint(one_of("status", ANSWER_STATUSES), name="status"),
        CheckConstraint(one_of("speed", SPEEDS), name="speed"),
        CheckConstraint("selected_option BETWEEN 0 AND 3", name="selected_option"),
    )

    match_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("matches.id", ondelete="CASCADE"), primary_key=True
    )
    seat: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    position: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    option_id: Mapped[str | None]  # as shown in the match
    selected_option: Mapped[int | None] = mapped_column(SmallInteger)  # authored index
    status: Mapped[str]
    is_correct: Mapped[bool]
    raw_ms: Mapped[int | None]  # received_at - shown_at
    time_ms: Mapped[int | None]  # latency-fair effective time
    points: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    speed: Mapped[str | None]
    peer_time_ms: Mapped[int | None]
    answered_at: Mapped[datetime | None]


class HeadToHead(Base):
    """Results between two players (``lo`` < ``hi``), across every kind of human 1v1 game."""

    __tablename__ = "h2h"
    __table_args__ = (
        CheckConstraint("lo < hi", name="order"),
        Index("ix_h2h_hi", "hi"),
    )

    lo: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    hi: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    lo_wins: Mapped[int] = mapped_column(server_default=text("0"))
    hi_wins: Mapped[int] = mapped_column(server_default=text("0"))
    draws: Mapped[int] = mapped_column(server_default=text("0"))
    last_played_at: Mapped[datetime]
