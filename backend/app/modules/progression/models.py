"""Progression: XP, daily missions, streaks and achievements.

XP is a running total per user built from idempotent ``xp_events``. Missions are three rows per
user and IST day, generated on first use from the ``mission_defs`` catalogue. Streaks keep one
row per user plus a row per IST day that counted (``active``) or was covered by a freeze
(``frozen``); the same day rows count finished battles, one of the ways to earn a streak day.
Achievements are a catalogue with one progress row per user and achievement.
"""

import uuid
from datetime import date, datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    ForeignKey,
    Index,
    SmallInteger,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of
from app.modules.progression.levels import GameKind


class XpSource(StrEnum):
    PRACTICE = "practice"
    MATCH = "match"
    MISSION = "mission"
    ACHIEVEMENT = "achievement"
    ADJUSTMENT = "adjustment"


class UserProgress(Base):
    __tablename__ = "user_progress"
    __table_args__ = (
        CheckConstraint("xp >= 0", name="xp"),
        CheckConstraint("practice_xp_today >= 0", name="practice_xp_today"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    xp: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    # Practice XP earned on ``practice_xp_day`` (IST), for the daily cap.
    practice_xp_day: Mapped[date | None]
    practice_xp_today: Mapped[int] = mapped_column(server_default=text("0"))
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())


class XpEvent(Base):
    """One award. ``source_key`` is unique per user, so replaying an award changes nothing."""

    __tablename__ = "xp_events"
    __table_args__ = (
        CheckConstraint(one_of("source", [source.value for source in XpSource]), name="source"),
        CheckConstraint(one_of("game_kind", [kind.value for kind in GameKind]), name="game_kind"),
        UniqueConstraint("user_id", "source_key"),
        Index("ix_xp_events_user_day", "user_id", "ist_day"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source: Mapped[str]
    source_key: Mapped[str]
    amount: Mapped[int]  # after the daily cap; 0 once the cap is reached
    ref_id: Mapped[uuid.UUID | None]  # the practice session, match or mission
    ist_day: Mapped[date]
    # Games only: the kind of game, for the per-kind daily caps.
    game_kind: Mapped[str | None]
    # The user's total right after this award, so a replay can report the same level change.
    total_after: Mapped[int | None] = mapped_column(BigInteger)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


# --- Missions ------------------------------------------------------------------------------


class MissionSlot(StrEnum):
    PRACTICE = "practice"
    PLAY = "play"
    REVIEW = "review"


class MissionKind(StrEnum):
    """What a mission counts; also the ``record_event`` kinds that move missions."""

    PRACTICE_ANSWER = "practice_answer"  # practice answers given (not skips or timeouts)
    REVIEW_ANSWER = "review_answer"  # answers in review sessions
    CHAPTER_ANSWER = "chapter_answer"  # answers in one chapter (or any, without a chapter)
    RATED_GAME = "rated_game"  # a finished rated battle or tournament game
    BATTLE_FINISHED = "battle_finished"  # any finished battle


class MissionDef(Base):
    """The catalogue (seeded by the migration). ``generate`` defs are picked for a new day;
    the others only come up as a swap."""

    __tablename__ = "mission_defs"
    __table_args__ = (
        CheckConstraint(one_of("slot", [slot.value for slot in MissionSlot]), name="slot"),
        CheckConstraint(one_of("kind", [kind.value for kind in MissionKind]), name="kind"),
        CheckConstraint("target > 0", name="target"),
        CheckConstraint("xp >= 0", name="xp"),
    )

    id: Mapped[str] = mapped_column(primary_key=True)
    slot: Mapped[str]
    kind: Mapped[str]
    target: Mapped[int]
    xp: Mapped[int]
    # ``{chapter}`` is filled in for chapter missions.
    title: Mapped[str]
    generate: Mapped[bool]
    sort: Mapped[int] = mapped_column(SmallInteger)


class DailyMission(Base):
    """Title, kind, target and XP are copied from the definition, so a day's missions never
    change under the player when the catalogue does."""

    __tablename__ = "daily_missions"
    __table_args__ = (
        CheckConstraint(one_of("slot", [slot.value for slot in MissionSlot]), name="slot"),
        CheckConstraint(one_of("kind", [kind.value for kind in MissionKind]), name="kind"),
        CheckConstraint("progress BETWEEN 0 AND target", name="progress"),
        UniqueConstraint("user_id", "ist_day", "slot"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    ist_day: Mapped[date]
    slot: Mapped[str]
    def_id: Mapped[str] = mapped_column(ForeignKey("mission_defs.id"))
    kind: Mapped[str]
    title: Mapped[str]
    target: Mapped[int]
    xp: Mapped[int]
    progress: Mapped[int] = mapped_column(server_default=text("0"))
    # Chapter missions: {"chapter_id", "chapter", "subject"}; empty otherwise.
    params: Mapped[dict[str, Any]] = mapped_column(server_default=text("'{}'"))
    done_at: Mapped[datetime | None]
    swapped: Mapped[bool] = mapped_column(server_default=text("false"))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class ProgressEventDedupe(Base):
    """Events already counted, per user: ``kind`` is the mission kind or ``ach:{metric}``."""

    __tablename__ = "mission_event_dedupe"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    kind: Mapped[str] = mapped_column(primary_key=True)
    event_id: Mapped[str] = mapped_column(primary_key=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now(), index=True)


# --- Streaks -------------------------------------------------------------------------------


class StreakState(StrEnum):
    ACTIVE = "active"
    FROZEN = "frozen"


class UserStreak(Base):
    """``checked_through`` is the last IST day whose outcome is final; ``last_day`` the last
    day that counted for the current streak (active or frozen)."""

    __tablename__ = "user_streaks"
    __table_args__ = (
        CheckConstraint("current >= 0", name="current"),
        CheckConstraint("best >= current", name="best"),
        CheckConstraint("freezes BETWEEN 0 AND 2", name="freezes"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    current: Mapped[int] = mapped_column(server_default=text("0"))
    best: Mapped[int] = mapped_column(server_default=text("0"))
    freezes: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    started_on: Mapped[date | None]  # the first day of the current streak
    last_day: Mapped[date | None]
    checked_through: Mapped[date | None]
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())


class StreakDay(Base):
    __tablename__ = "streak_days"
    __table_args__ = (
        CheckConstraint(one_of("state", [state.value for state in StreakState]), name="state"),
        CheckConstraint("battles_finished >= 0", name="battles_finished"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    day: Mapped[date] = mapped_column(primary_key=True)  # in India time
    battles_finished: Mapped[int] = mapped_column(server_default=text("0"))
    state: Mapped[str | None]  # set once the day counted for a streak


# --- Achievements --------------------------------------------------------------------------


class Metric(StrEnum):
    """What an achievement measures. Counters add up; ``LEVEL`` and ``STREAK`` keep the best."""

    BATTLES = "battles"
    WINS = "wins"
    PERFECT_BATTLES = "perfect_battles"
    ANSWERS = "answers"
    REVIEW_ANSWERS = "review_answers"
    STREAK = "streak"
    LEVEL = "level"
    TOURNAMENTS = "tournaments"
    PODIUMS = "podiums"
    TOURNAMENT_WINS = "tournament_wins"
    FRIENDS = "friends"
    MISSION_DAYS = "mission_days"


ABSOLUTE_METRICS = frozenset({Metric.STREAK, Metric.LEVEL})


class Achievement(Base):
    __tablename__ = "achievements"
    __table_args__ = (
        CheckConstraint(one_of("metric", [metric.value for metric in Metric]), name="metric"),
        CheckConstraint("target > 0", name="target"),
        CheckConstraint("coins BETWEEN 0 AND 200", name="coins"),
    )

    id: Mapped[str] = mapped_column(primary_key=True)
    metric: Mapped[str]
    target: Mapped[int]
    title: Mapped[str]
    description: Mapped[str]
    icon: Mapped[str]
    coins: Mapped[int]
    sort: Mapped[int] = mapped_column(SmallInteger)


class UserAchievement(Base):
    __tablename__ = "user_achievements"
    __table_args__ = (CheckConstraint("progress >= 0", name="progress"),)

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    achievement_id: Mapped[str] = mapped_column(ForeignKey("achievements.id"), primary_key=True)
    progress: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    earned_at: Mapped[datetime | None]
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())
